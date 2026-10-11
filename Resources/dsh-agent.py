#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""DSH 云端推理 Agent（部署在用户自己的云服务器上）

职责：
  * 接收 iOS 客户端发来的会话，调用模型接口推理，把输出以「事件」形式缓存并流式返回；
  * 客户端断开（App 进入后台）时不中断推理，客户端回来按游标（after=N）续取，补齐全部内容；
  * 管理沙盒（工作目录）：自动创建 / 暂停 / 恢复 / 销毁；
  * 沙盒文件的上传、下载、列表、删除；
  * 带工具调用循环的智能体：服务端执行（web_fetch / workspace / mcp_*），
    或把调用发回手机端执行（ssh_exec / browser_* / screenshot / clipboard / reminder /
    github / gitee / skill 等），使云端推理与 App 本地推理具备同样的智能体能力。

仅使用 Python 标准库（无第三方依赖），个人单用户使用；除 /health 外所有接口都需要
启动时生成的 Bearer Token 鉴权（Token 只保存在 iOS 客户端钥匙串，不落盘到本机明文配置之外）。

用法：
    python3 dsh-agent.py --port 8931 --token <TOKEN> [--root ~/.dsh] [--host 0.0.0.0]

工具调用协议（v1.1，向后兼容：不传新字段时行为与旧版一致=单轮推理）：
  POST /sandboxes/<sid>/chat 除现有字段外，可另带（均可选）：
    "tools":         [ {OpenAI function 工具对象} ]     # 直接下发给模型的 tools 数组
    "mcpServers":    [ {"name","url","headers",
                        "tools":[{"modelName":"mcp_<别名>_<工具>","name":"<真实工具名>"}]} ]
    "maxToolRounds": 6      # 工具轮上限，默认 6，上限 12
    "toolTimeout":   180    # 等待手机端回传结果的秒数，默认 180，上限 600

  新增事件（沿用 {"i":n,"type":...} 结构，追加到 run.events）：
    {"i":n,"type":"tool_call",  "callId":"call_1","name":"ssh_exec",
     "arguments":"{\"command\":\"ls\"}","source":"client"}
    {"i":n,"type":"tool_result","callId":"call_1","name":"ssh_exec","output":"...",
     "source":"client","failed":false}
    source = "server"（Agent 自己执行）或 "client"（等手机端回传）。
    arguments 为模型给出的原始 JSON 字符串（原样透传，不做解析后重拼）。

  手机端回传工具结果：
    POST /sandboxes/<sid>/runs/<rid>/tool_result
    body: {"id":"call_1","output":"工具输出文本"}
    成功 → 200 {"ok":true}；找不到等待中的调用 → 404 {"error":"没有等待中的工具调用"}
"""

import argparse
import json
import os
import re
import shutil
import socketserver
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from html import unescape
from http.server import BaseHTTPRequestHandler

AGENT_VERSION = "1.1"
RUN_EVENT_LIMIT = 200_000          # 单个 run 的事件上限（防内存失控）
SANDBOX_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
RUN_ID_RE = re.compile(r"^r[A-Za-z0-9-]{6,64}$")
MAX_TOOL_ROUNDS = 12               # 工具轮上限（maxToolRounds 的封顶值）
MAX_TOOL_ROUNDS_DEFAULT = 6        # 工具轮默认值（与 App 本地推理一致）
ROUND_TOOL_LIMIT = 6               # 单轮工具调用次数上限
TOOL_OUTPUT_LIMIT = 16_000         # 单个工具输出字符上限
TOOL_TIMEOUT_MAX = 600             # 等待手机端结果的秒数上限
WEB_FETCH_TIMEOUT = 20             # 网页抓取超时（秒）
WEB_FETCH_LIMIT = 8_000            # 网页正文截断字符数
MCP_PROTOCOL_VERSION = "2025-03-26"
BROWSER_UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
              "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1")

# ---------------------------------------------------------------- 全局状态

LOCK = threading.Lock()
SANDBOXES = {}          # id -> Sandbox
RUNS = {}               # "sandboxId/runId" -> Run


class Sandbox:
    def __init__(self, sid, root):
        self.id = sid
        self.path = os.path.join(root, "sandboxes", sid)
        self.state = "active"
        self.created_at = time.time()
        self.runs = []

    @property
    def meta_path(self):
        return os.path.join(self.path, "sandbox.json")

    def file_count(self):
        total = 0
        for base, _dirs, files in os.walk(self.path):
            total += len(files)
        return max(0, total - 1)  # 去掉 sandbox.json

    def write_meta(self):
        try:
            with open(self.meta_path, "w", encoding="utf-8") as handle:
                json.dump({"id": self.id, "state": self.state, "createdAt": self.created_at}, handle)
        except OSError:
            pass

    def snapshot(self):
        return {
            "id": self.id,
            "state": self.state,
            "createdAt": self.created_at,
            "runs": len(self.runs),
            "files": self.file_count(),
        }


class Run:
    def __init__(self, run_id, sandbox_id):
        self.id = run_id
        self.sandbox_id = sandbox_id
        self.events = []          # {"i": n, "type": ..., "text": ...}
        self.state = "running"    # running / done / error / stopped
        self.error = None
        self.usage = None
        self.stop_flag = False
        self.created_at = time.time()
        self.condition = threading.Condition(LOCK)
        self.tool_lock = threading.Lock()
        self.pending_tools = {}   # callId -> {"event": Event, "output": None, "failed": False}

    def append(self, event_type, text=None, usage=None, error=None, extra=None):
        with self.condition:
            if len(self.events) >= RUN_EVENT_LIMIT:
                self.events = self.events[len(self.events) // 2:]
            event = {"i": len(self.events), "type": event_type}
            if text is not None:
                event["text"] = text
            if usage is not None:
                event["usage"] = usage
            if error is not None:
                event["error"] = error
            if extra:
                event.update(extra)
            self.events.append(event)
            self.condition.notify_all()

    def finish(self, state, error=None):
        with self.condition:
            self.state = state
            self.error = error
            self.condition.notify_all()

    # ---- 手机端工具结果的等待与回传

    def wait_tool_result(self, call_id, timeout):
        """等待手机端回传某个工具调用的结果；被停止时立刻中断。"""
        event = threading.Event()
        with self.tool_lock:
            self.pending_tools[call_id] = {"event": event, "output": None, "failed": False}
        deadline = time.time() + timeout
        while True:
            if self.stop_flag or event.is_set():
                break
            remaining = deadline - time.time()
            if remaining <= 0:
                break
            event.wait(min(remaining, 0.5))
        with self.tool_lock:
            slot = self.pending_tools.pop(call_id, None)
        if self.stop_flag:
            return "任务已停止，手机端结果未返回。", True
        if slot is not None and slot["output"] is not None:
            return slot["output"], bool(slot["failed"])
        return "手机端在 %d 秒内没有返回结果（App 可能已退出或网络不通）" % int(timeout), True

    def deliver_tool_result(self, call_id, output):
        """手机端回传工具结果；找不到等待中的调用返回 False。"""
        with self.tool_lock:
            slot = self.pending_tools.get(call_id)
            if slot is None:
                return False
            slot["output"] = output
            slot["event"].set()
        return True

    def wake_pending(self):
        """停止/销毁沙盒时唤醒所有等待中的工具调用，避免线程挂死。"""
        with self.tool_lock:
            for slot in self.pending_tools.values():
                slot["event"].set()


# ---------------------------------------------------------------- 工具


def sandbox_dir(root, sandbox_id):
    if not SANDBOX_NAME_RE.match(sandbox_id):
        return None
    return os.path.join(root, "sandboxes", sandbox_id)


def safe_path(base, relative):
    """把相对路径安全地拼到沙盒目录里，拒绝越界。"""
    relative = (relative or "").strip().lstrip("/")
    if not relative:
        return None
    target = os.path.normpath(os.path.join(base, relative))
    base_norm = os.path.normpath(base)
    if target != base_norm and not target.startswith(base_norm + os.sep):
        return None
    return target


def is_text_preview(path, limit=200_000):
    try:
        return os.path.getsize(path) <= limit
    except OSError:
        return False


# ---------------------------------------------------------------- 推理执行


def normalize_messages(raw_messages):
    """把客户端消息整理成 OpenAI 兼容的 messages（仅保留纯文本角色消息）。"""
    messages = []
    for message in raw_messages:
        if not isinstance(message, dict):
            continue
        role = message.get("role")
        content = message.get("content")
        if role not in ("system", "user", "assistant") or not isinstance(content, str) or not content:
            continue
        messages.append({"role": role, "content": content})
    return messages


def build_model_payload(request_body, messages=None, tools=None):
    """把客户端参数整理成 OpenAI 兼容的 /chat/completions 请求体。"""
    if messages is None:
        messages = normalize_messages(request_body.get("messages", []))

    model = str(request_body.get("model") or "deepseek-flash")
    payload = {
        "model": model,
        "messages": messages,
        "stream": True,
        "stream_options": {"include_usage": True},
    }
    if isinstance(request_body.get("temperature"), (int, float)):
        payload["temperature"] = float(request_body["temperature"])
    # 思考参数仅对 DeepSeek 系模型下发，避免中转服务因未知字段报错（与客户端本地推理一致）
    if request_body.get("thinking") and "deepseek" in model.lower():
        payload["thinking"] = {"type": "enabled"}
        effort = request_body.get("reasoningEffort")
        if effort in ("low", "high", "max"):
            payload["reasoning_effort"] = effort
    if tools:
        payload["tools"] = tools
    return payload


def stream_completion(run, url, api_key, payload):
    """读取一次流式响应：增量按现有方式发 reasoning/content 事件，并聚合 tool_calls。

    返回 (assistant_text, tool_calls)；返回 None 表示 run 被停止。
    tool_calls 形如 [{"id","name","arguments"}]，arguments 为原始 JSON 字符串。
    """
    request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Accept": "text/event-stream",
            "Authorization": "Bearer " + api_key,
        },
        method="POST",
    )
    text_parts = []
    tool_calls = {}
    with urllib.request.urlopen(request, timeout=600) as response:
        for raw_line in response:
            if run.stop_flag:
                return None
            line = raw_line.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            try:
                chunk = json.loads(data)
            except ValueError:
                continue
            if isinstance(chunk.get("usage"), dict) and chunk["usage"]:
                usage = chunk["usage"]
                run.usage = {
                    "promptTokens": int(usage.get("prompt_tokens") or 0),
                    "completionTokens": int(usage.get("completion_tokens") or 0),
                }
                run.append("usage", usage=run.usage)
            choices = chunk.get("choices") or []
            if not choices:
                continue
            delta = choices[0].get("delta") or {}
            content = delta.get("content")
            if content:
                text_parts.append(content)
                run.append("content", text=content)
            reasoning = delta.get("reasoning_content") or delta.get("reasoning")
            if reasoning:
                run.append("reasoning", text=reasoning)
            # 流式分片按 index 聚合 id / name / arguments
            for piece in delta.get("tool_calls") or []:
                if not isinstance(piece, dict):
                    continue
                index = piece.get("index")
                if not isinstance(index, int):
                    index = len(tool_calls)
                slot = tool_calls.setdefault(index, {"id": "", "name": "", "arguments": ""})
                if piece.get("id"):
                    slot["id"] = str(piece["id"])
                function = piece.get("function") or {}
                if function.get("name"):
                    slot["name"] = str(function["name"])
                if function.get("arguments"):
                    slot["arguments"] += str(function["arguments"])
    ordered = []
    for index in sorted(tool_calls):
        slot = tool_calls[index]
        if not slot["name"]:
            continue
        if not slot["id"]:
            slot["id"] = "call_%d" % index
        ordered.append(slot)
    return "".join(text_parts), ordered


# ---------------------------------------------------------------- 工具执行


def truncate_tool_output(text, limit=TOOL_OUTPUT_LIMIT):
    """把工具输出截断到上限字符，超出部分加说明。"""
    if text is None:
        text = ""
    text = str(text)
    if len(text) > limit:
        return text[:limit] + "…（输出过长，已截断）"
    return text


def parse_tool_arguments(raw):
    """把模型给的原始 arguments 字符串解析成 dict（失败返回空 dict）。"""
    if isinstance(raw, dict):
        return raw
    if not isinstance(raw, str) or not raw.strip():
        return {}
    try:
        value = json.loads(raw)
    except ValueError:
        return {}
    return value if isinstance(value, dict) else {}


def tool_source(name):
    """判断工具由谁执行：server = Agent 自己，client = 发回手机端。"""
    if name in ("web_fetch", "workspace") or name.startswith("mcp_"):
        return "server"
    return "client"


def html_to_text(html):
    """极简 HTML 转纯文本：去脚本样式与标签、反转义实体、压缩空白。"""
    title = ""
    match = re.search(r"(?is)<title[^>]*>(.*?)</title>", html)
    if match:
        title = unescape(match.group(1)).strip()
    text = re.sub(r"(?is)<(script|style|noscript|template|head)[^>]*>.*?</\1>", " ", html)
    text = re.sub(r"(?is)<!--.*?-->", " ", text)
    text = re.sub(r"(?i)<br\s*/?>", "\n", text)
    text = re.sub(r"(?i)</(p|div|li|tr|h[1-6]|section|article|pre)>", "\n", text)
    text = re.sub(r"(?s)<[^>]+>", " ", text)
    text = unescape(text)
    text = re.sub(r"[ \t\u00a0\r\f\v]+", " ", text)
    text = re.sub(r"\n\s*\n+", "\n", text)
    return title, text.strip()


def tool_web_fetch(arguments):
    """服务端抓取网页并转成纯文本，返回 (output, failed)。"""
    url = str(arguments.get("url") or "").strip()
    if not url:
        return "缺少 url 参数", True
    if not re.match(r"^https?://", url, re.I):
        return "只支持 http/https 链接", True
    request = urllib.request.Request(
        url,
        headers={"User-Agent": BROWSER_UA, "Accept": "text/html,application/xhtml+xml,*/*"},
    )
    try:
        with urllib.request.urlopen(request, timeout=WEB_FETCH_TIMEOUT) as response:
            raw = response.read(2_000_000)
            charset = response.headers.get_content_charset() or "utf-8"
    except urllib.error.HTTPError as error:
        return "抓取失败：HTTP %s %s" % (error.code, error.reason), True
    except Exception as error:  # noqa: BLE001 - 网络异常统一转成可读错误
        return "抓取失败：%s" % error, True
    title, text = html_to_text(raw.decode(charset, "replace"))
    if not text:
        text = "（页面没有可读正文）"
    elif len(text) > WEB_FETCH_LIMIT:
        text = text[:WEB_FETCH_LIMIT] + "…（正文过长，已截断）"
    return "标题：%s\n\n%s" % (title or url, text), False


def tool_workspace(sandbox, arguments):
    """在沙盒目录内操作文件（复用 safe_path 做越界防护，绝不越出沙盒）。"""
    if sandbox is None:
        return "沙盒不可用", True
    base = sandbox.path
    action = str(arguments.get("action") or "").strip()
    relative = str(arguments.get("path") or "").strip()

    if action == "list":
        target = base if not relative else safe_path(base, relative)
        if target is None:
            return "路径不合法（不能越出沙盒目录）", True
        if not os.path.isdir(target):
            return "目录不存在：%s" % (relative or "/"), True
        entries = []
        for name in sorted(os.listdir(target)):
            if target == base and name == "sandbox.json":
                continue
            full = os.path.join(target, name)
            if os.path.isdir(full):
                entries.append(name + "/")
            else:
                try:
                    entries.append("%s (%d 字节)" % (name, os.path.getsize(full)))
                except OSError:
                    entries.append(name)
        return "目录 %s：\n%s" % (relative or "/", "\n".join(entries) if entries else "（空目录）"), False

    if action == "read":
        target = safe_path(base, relative)
        if target is None:
            return "路径不合法（不能越出沙盒目录）", True
        if not os.path.isfile(target):
            return "文件不存在：%s" % relative, True
        if not is_text_preview(target):
            return "文件过大（上限 200 KB），无法作为文本读取", True
        try:
            with open(target, "rb") as handle:
                data = handle.read()
        except OSError as error:
            return "读取失败：%s" % error, True
        if b"\x00" in data:
            return "这是二进制文件（%d 字节），无法以文本读取" % len(data), True
        return data.decode("utf-8", "replace"), False

    if action == "write":
        target = safe_path(base, relative)
        if target is None:
            return "路径不合法（不能越出沙盒目录）", True
        content = arguments.get("content")
        if not isinstance(content, str):
            content = ""
        try:
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, "w", encoding="utf-8") as handle:
                handle.write(content)
        except OSError as error:
            return "写入失败：%s" % error, True
        return "已写入 %s（%d 字节）" % (relative, len(content.encode("utf-8"))), False

    if action == "mkdir":
        target = safe_path(base, relative)
        if target is None:
            return "路径不合法（不能越出沙盒目录）", True
        try:
            os.makedirs(target, exist_ok=True)
        except OSError as error:
            return "创建失败：%s" % error, True
        return "已创建目录：%s" % relative, False

    if action == "delete":
        target = safe_path(base, relative)
        if target is None:
            return "路径不合法（不能越出沙盒目录）", True
        if os.path.isdir(target):
            shutil.rmtree(target, ignore_errors=True)
        elif os.path.isfile(target):
            os.remove(target)
        else:
            return "文件不存在：%s" % relative, True
        return "已删除：%s" % relative, False

    if action == "search":
        query = str(arguments.get("query") or "").strip()
        if not query:
            return "缺少 query 参数", True
        scope = safe_path(base, relative) if relative else base
        if scope is None:
            return "路径不合法（不能越出沙盒目录）", True
        if os.path.isfile(scope):
            targets = [scope]
        elif os.path.isdir(scope):
            targets = []
            for scan_base, _dirs, files in os.walk(scope):
                for name in files:
                    targets.append(os.path.join(scan_base, name))
            targets.sort()
        else:
            return "路径不存在：%s" % (relative or "/"), True
        matches = []
        for full in targets:
            if full == os.path.join(base, "sandbox.json") or not is_text_preview(full, 2_000_000):
                continue
            try:
                with open(full, "rb") as handle:
                    data = handle.read()
            except OSError:
                continue
            if b"\x00" in data:
                continue
            rel = os.path.relpath(full, base).replace(os.sep, "/")
            for number, line in enumerate(data.decode("utf-8", "replace").splitlines(), 1):
                if query in line:
                    snippet = line.strip()
                    if len(snippet) > 120:
                        snippet = snippet[:120] + "…"
                    matches.append("%s:%d: %s" % (rel, number, snippet))
                    if len(matches) >= 30:
                        break
            if len(matches) >= 30:
                break
        if not matches:
            return "没有找到包含「%s」的内容" % query, False
        return "匹配「%s」（最多 30 条）：\n%s" % (query, "\n".join(matches)), False

    return "未知的 workspace 动作：%s（可用：list/read/write/mkdir/delete/search）" % (action or "（空）"), True


def parse_mcp_body(raw, content_type):
    """解析 MCP 响应体：可能是 JSON，也可能是 SSE（逐行 data: {...}）。"""
    text = raw.decode("utf-8", "replace").strip()
    if not text:
        return {}
    if "text/event-stream" in (content_type or "") or text.startswith("data:"):
        result = {}
        for line in text.splitlines():
            line = line.strip()
            if not line.startswith("data:"):
                continue
            payload = line[5:].strip()
            if not payload or payload == "[DONE]":
                continue
            try:
                result = json.loads(payload)
            except ValueError:
                continue
        return result
    try:
        return json.loads(text)
    except ValueError:
        return {}


def mcp_post(url, payload, custom_headers, session_id, expect_reply=True):
    """向 MCP Streamable HTTP 端点发一次 JSON-RPC 请求，返回 (解析后的对象, 响应头)。"""
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
        "MCP-Protocol-Version": MCP_PROTOCOL_VERSION,
    }
    if isinstance(custom_headers, dict):
        for key, value in custom_headers.items():
            if isinstance(key, str) and isinstance(value, str):
                headers[key] = value
    if session_id:
        headers["Mcp-Session-Id"] = session_id
    request = urllib.request.Request(
        url, data=json.dumps(payload).encode("utf-8"), headers=headers, method="POST",
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        response_headers = {}
        for key, value in response.headers.items():
            response_headers[key] = value
        raw = response.read(2_000_000) if expect_reply else b""
        content_type = response.headers.get("Content-Type") or ""
    return parse_mcp_body(raw, content_type), response_headers


def tool_mcp(mcp_servers, model_name, arguments):
    """按 modelName 定位 MCP 服务器与真实工具名，走 Streamable HTTP 调用。"""
    server = None
    real_name = None
    for candidate in mcp_servers or []:
        if not isinstance(candidate, dict):
            continue
        for item in candidate.get("tools") or []:
            if isinstance(item, dict) and item.get("modelName") == model_name:
                server = candidate
                real_name = item.get("name") or model_name[len("mcp_"):]
                break
        if server is not None:
            break
    if server is None:
        return "找不到 MCP 工具对应的服务器：%s" % model_name, True
    url = str(server.get("url") or "").strip()
    if not url:
        return "MCP 服务器缺少 url 配置", True
    headers = server.get("headers") or {}
    try:
        init_request = {
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {
                "protocolVersion": MCP_PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "dsh-cloud-agent", "version": AGENT_VERSION},
            },
        }
        _body, response_headers = mcp_post(url, init_request, headers, None)
        session_id = None
        for key, value in response_headers.items():
            if key.lower() == "mcp-session-id":
                session_id = value
                break
        try:
            mcp_post(url, {"jsonrpc": "2.0", "method": "notifications/initialized"},
                     headers, session_id, expect_reply=False)
        except Exception:  # noqa: BLE001 - 初始化通知失败可忽略
            pass
        call_request = {
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": {"name": real_name, "arguments": arguments},
        }
        body, _headers = mcp_post(url, call_request, headers, session_id)
    except urllib.error.HTTPError as error:
        return "MCP 调用失败：HTTP %s %s" % (error.code, error.reason), True
    except Exception as error:  # noqa: BLE001 - 网络异常统一转成可读错误
        return "MCP 调用失败：%s" % error, True
    if not isinstance(body, dict):
        return "MCP 返回内容无法解析", True
    if body.get("error"):
        error = body["error"]
        message = error.get("message") if isinstance(error, dict) else error
        return "MCP 返回错误：%s" % message, True
    result = body.get("result") or {}
    if not isinstance(result, dict):
        return "MCP 返回内容为空", False
    texts = []
    for item in result.get("content") or []:
        if isinstance(item, dict):
            if item.get("text") is not None:
                texts.append(str(item["text"]))
            elif item.get("type"):
                texts.append("[%s]" % item.get("type"))
    output = "\n".join(texts).strip() or "MCP 工具没有返回文本内容"
    return output, bool(result.get("isError"))


def execute_server_tool(sandbox, name, arguments, mcp_servers):
    """执行服务端工具，返回 (output, failed)。"""
    if name == "web_fetch":
        return tool_web_fetch(arguments)
    if name == "workspace":
        return tool_workspace(sandbox, arguments)
    if name.startswith("mcp_"):
        return tool_mcp(mcp_servers, name, arguments)
    return "不认识的工具：%s" % name, True


def run_inference(run, request_body, sandbox=None):
    """在后台线程里执行一次带工具循环的推理：把增量缓存为事件，客户端断线也不中断。"""
    base = str(request_body.get("baseURL") or "https://api.deepseek.com").rstrip("/")
    api_key = str(request_body.get("apiKey") or "")
    url = base + "/chat/completions"

    tools = request_body.get("tools")
    if not isinstance(tools, list):
        tools = None
    mcp_servers = request_body.get("mcpServers")
    if not isinstance(mcp_servers, list):
        mcp_servers = []

    try:
        max_rounds = int(request_body.get("maxToolRounds") or MAX_TOOL_ROUNDS_DEFAULT)
    except (TypeError, ValueError):
        max_rounds = MAX_TOOL_ROUNDS_DEFAULT
    max_rounds = max(1, min(MAX_TOOL_ROUNDS, max_rounds))

    try:
        tool_timeout = float(request_body.get("toolTimeout") or 180)
    except (TypeError, ValueError):
        tool_timeout = 180.0
    tool_timeout = max(1.0, min(float(TOOL_TIMEOUT_MAX), tool_timeout))

    messages = normalize_messages(request_body.get("messages", []))
    has_tools = bool(tools) or bool(mcp_servers)

    try:
        for round_index in range(max_rounds):
            if run.stop_flag:
                run.finish("stopped")
                return
            # 最后一轮不下发工具，并追加一条临时 user 消息要结论（不写入事件流）
            is_last = round_index == max_rounds - 1
            round_messages = list(messages)
            round_tools = tools
            if is_last and has_tools:
                round_tools = None
                round_messages.append({"role": "user", "content": "不要再调用工具，请直接用文字给出结论。"})
            payload = build_model_payload(request_body, messages=round_messages, tools=round_tools)
            result = stream_completion(run, url, api_key, payload)
            if result is None:
                run.finish("stopped")
                return
            assistant_text, tool_calls = result
            if not tool_calls:
                run.finish("done")
                return

            # 把 assistant 的 tool_calls 消息追加进 messages（OpenAI 格式）
            messages.append({
                "role": "assistant",
                "content": assistant_text or None,
                "tool_calls": [
                    {"id": call["id"], "type": "function",
                     "function": {"name": call["name"], "arguments": call["arguments"]}}
                    for call in tool_calls
                ],
            })

            executed = 0
            for call in tool_calls:
                call_id = call["id"]
                name = call["name"]
                arguments_raw = call["arguments"]
                source = tool_source(name)
                run.append("tool_call", extra={
                    "callId": call_id, "name": name, "arguments": arguments_raw, "source": source,
                })
                if executed >= ROUND_TOOL_LIMIT:
                    output, failed = "本轮工具调用次数已达上限", True
                else:
                    executed += 1
                    if source == "server":
                        output, failed = execute_server_tool(
                            sandbox, name, parse_tool_arguments(arguments_raw), mcp_servers)
                    else:
                        output, failed = run.wait_tool_result(call_id, tool_timeout)
                output = truncate_tool_output(output)
                run.append("tool_result", extra={
                    "callId": call_id, "name": name, "output": output,
                    "source": source, "failed": bool(failed),
                })
                messages.append({"role": "tool", "tool_call_id": call_id, "content": output})
                if run.stop_flag:
                    run.finish("stopped")
                    return
        if run.stop_flag:
            run.finish("stopped")
        else:
            run.finish("done")
    except urllib.error.HTTPError as error:
        detail = ""
        try:
            detail = error.read().decode("utf-8", "replace")[:500]
        except Exception:  # noqa: BLE001 - 读取错误体失败不影响主流程
            pass
        run.append("error", error="模型接口返回 %s：%s" % (error.code, detail or error.reason))
        run.finish("error", error="模型接口返回 %s" % error.code)
    except Exception as error:  # noqa: BLE001 - 网络异常统一转成事件
        run.append("error", error="推理失败：%s" % error)
        run.finish("error", error=str(error))


# ---------------------------------------------------------------- HTTP 处理


class Handler(BaseHTTPRequestHandler):
    server_version = "DSHAgent/" + AGENT_VERSION
    protocol_version = "HTTP/1.1"

    # ---------- 基础响应

    def log_message(self, fmt, *args):  # 静默：日志由 launchd/nohup 收集，不需要每请求一行
        pass

    def send_json(self, status, obj):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_bytes(self, status, body, content_type="application/octet-stream", filename=None):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        if filename:
            self.send_header("Content-Disposition", 'attachment; filename="%s"' % filename)
        self.end_headers()
        self.wfile.write(body)

    def send_error_json(self, status, message):
        self.send_json(status, {"ok": False, "error": message})

    def read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            return b""
        return self.rfile.read(length)

    def read_json(self):
        raw = self.read_body()
        if not raw:
            return {}
        try:
            return json.loads(raw.decode("utf-8"))
        except ValueError:
            return {}

    def authorized(self):
        header = self.headers.get("Authorization") or ""
        return header == "Bearer " + self.server.token

    # ---------- 路由

    def handle_one_request(self):
        try:
            BaseHTTPRequestHandler.handle_one_request(self)
        except (ConnectionResetError, BrokenPipeError):
            self.close_connection = True

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def do_PUT(self):
        self.route("PUT")

    def do_DELETE(self):
        self.route("DELETE")

    def route(self, method):
        path = self.path.split("?", 1)[0]
        query = {}
        if "?" in self.path:
            for pair in self.path.split("?", 1)[1].split("&"):
                if "=" in pair:
                    key, value = pair.split("=", 1)
                    query[urllib.parse.unquote(key)] = urllib.parse.unquote(value)

        if path == "/health" and method == "GET":
            with LOCK:
                body = {
                    "ok": True,
                    "version": AGENT_VERSION,
                    "root": self.server.root,
                    "sandboxes": len(SANDBOXES),
                    "time": time.time(),
                }
            self.send_json(200, body)
            return

        if not self.authorized():
            self.send_error_json(401, "未授权：Token 不正确")
            return

        parts = [urllib.parse.unquote(p) for p in path.strip("/").split("/") if p]
        try:
            if parts[:1] == ["sandboxes"]:
                self.handle_sandboxes(method, parts[1:], query)
                return
            self.send_error_json(404, "没有这个接口：%s" % path)
        except Exception as error:  # noqa: BLE001 - 兜底，避免线程因异常静默断开
            self.send_error_json(500, "服务内部错误：%s" % error)

    # ---------- 沙盒与文件

    def handle_sandboxes(self, method, parts, query):
        # /sandboxes
        if not parts:
            if method == "GET":
                with LOCK:
                    items = [sandbox.snapshot() for sandbox in sorted(SANDBOXES.values(), key=lambda s: s.id)]
                self.send_json(200, {"ok": True, "sandboxes": items})
                return
            if method == "POST":
                body = self.read_json()
                sid = str(body.get("id") or "").strip() or ("s" + uuid.uuid4().hex[:8])
                sandbox = ensure_sandbox(sid)
                if sandbox is None:
                    self.send_error_json(400, "沙盒名不合法（只能字母数字与 . _ -，最长 64 位）")
                    return
                self.send_json(200, {"ok": True, "sandbox": sandbox.snapshot()})
                return
            self.send_error_json(405, "不支持的方法")
            return

        sid = parts[0]
        sandbox = ensure_sandbox(sid)
        if sandbox is None:
            self.send_error_json(404, "沙盒不存在：%s" % sid)
            return

        # /sandboxes/<id>
        if len(parts) == 1:
            if method == "GET":
                self.send_json(200, {"ok": True, "sandbox": sandbox.snapshot()})
                return
            if method == "DELETE":
                with LOCK:
                    for run in list(sandbox.runs):
                        run.stop_flag = True
                        run.wake_pending()
                    for key in [k for k in RUNS if k.startswith(sid + "/")]:
                        RUNS.pop(key, None)
                    SANDBOXES.pop(sid, None)
                shutil.rmtree(sandbox.path, ignore_errors=True)
                self.send_json(200, {"ok": True})
                return
            self.send_error_json(405, "不支持的方法")
            return

        action = parts[1]

        # /sandboxes/<id>/pause|resume
        if action in ("pause", "resume") and len(parts) == 2 and method == "POST":
            if action == "pause":
                sandbox.state = "paused"
                for run in list(sandbox.runs):
                    run.stop_flag = True
                    run.wake_pending()
            else:
                sandbox.state = "active"
            sandbox.write_meta()
            self.send_json(200, {"ok": True, "sandbox": sandbox.snapshot()})
            return

        # /sandboxes/<id>/files[...]
        if action == "files":
            self.handle_files(method, sandbox, parts[2:])
            return

        # /sandboxes/<id>/chat
        if action == "chat" and len(parts) == 2 and method == "POST":
            if sandbox.state != "active":
                self.send_error_json(409, "沙盒已暂停：请先恢复再发送会话")
                return
            body = self.read_json()
            if not body.get("messages"):
                self.send_error_json(400, "缺少 messages")
                return
            run = Run("r" + uuid.uuid4().hex[:12], sid)
            with LOCK:
                RUNS[sid + "/" + run.id] = run
                sandbox.runs.append(run)
                sandbox.runs = sandbox.runs[-20:]
            threading.Thread(target=run_inference, args=(run, body, sandbox), daemon=True).start()
            self.send_json(200, {"ok": True, "runId": run.id, "sandbox": sid})
            return

        # /sandboxes/<id>/runs/<runId>[?after=N&timeout=20]
        if action == "runs" and len(parts) >= 3 and method == "GET":
            run = RUNS.get(sid + "/" + parts[2])
            if run is None:
                self.send_error_json(404, "任务不存在（可能服务重启过）：%s" % parts[2])
                return
            after = int(query.get("after") or 0)
            timeout = min(60.0, max(1.0, float(query.get("timeout") or 20)))
            self.wait_and_reply(run, after, timeout)
            return

        # /sandboxes/<id>/runs/<runId>/stop
        if action == "runs" and len(parts) == 4 and parts[3] == "stop" and method == "POST":
            run = RUNS.get(sid + "/" + parts[2])
            if run is None:
                self.send_error_json(404, "任务不存在")
                return
            run.stop_flag = True
            run.wake_pending()
            self.send_json(200, {"ok": True})
            return

        # /sandboxes/<id>/runs/<runId>/tool_result —— 手机端回传工具结果
        if action == "runs" and len(parts) == 4 and parts[3] == "tool_result" and method == "POST":
            run = RUNS.get(sid + "/" + parts[2])
            if run is None:
                self.send_error_json(404, "任务不存在")
                return
            body = self.read_json()
            call_id = str(body.get("id") or "").strip()
            if not call_id:
                self.send_json(400, {"error": "缺少 id"})
                return
            output = body.get("output")
            if output is None:
                output = ""
            if run.deliver_tool_result(call_id, str(output)):
                self.send_json(200, {"ok": True})
            else:
                self.send_json(404, {"error": "没有等待中的工具调用"})
            return

        # /sandboxes/<id>/runs
        if action == "runs" and len(parts) == 2 and method == "GET":
            with LOCK:
                items = [
                    {"id": run.id, "state": run.state, "events": len(run.events), "createdAt": run.created_at}
                    for run in sandbox.runs
                ]
            self.send_json(200, {"ok": True, "runs": items})
            return

        self.send_error_json(404, "没有这个接口")

    def handle_files(self, method, sandbox, parts):
        if not parts and method == "GET":
            items = []
            for base, _dirs, files in os.walk(sandbox.path):
                for name in sorted(files):
                    full = os.path.join(base, name)
                    relative = os.path.relpath(full, sandbox.path)
                    if relative == "sandbox.json":
                        continue
                    try:
                        stat = os.stat(full)
                    except OSError:
                        continue
                    items.append({
                        "name": relative.replace(os.sep, "/"),
                        "size": stat.st_size,
                        "modified": stat.st_mtime,
                    })
                    if len(items) >= 1000:
                        break
            items.sort(key=lambda item: item["name"])
            self.send_json(200, {"ok": True, "files": items})
            return

        relative = "/".join(parts)
        target = safe_path(sandbox.path, relative)
        if target is None:
            self.send_error_json(400, "路径不合法")
            return

        if method == "PUT":
            body = self.read_body()
            if len(body) > 64 * 1024 * 1024:
                self.send_error_json(413, "文件过大（上限 64 MB）")
                return
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, "wb") as handle:
                handle.write(body)
            self.send_json(200, {"ok": True, "name": relative, "size": len(body)})
            return

        if method == "GET":
            if not os.path.isfile(target):
                self.send_error_json(404, "文件不存在：%s" % relative)
                return
            with open(target, "rb") as handle:
                body = handle.read()
            self.send_bytes(200, body, filename=os.path.basename(target))
            return

        if method == "DELETE":
            if os.path.isdir(target):
                shutil.rmtree(target, ignore_errors=True)
            elif os.path.isfile(target):
                os.remove(target)
            else:
                self.send_error_json(404, "文件不存在：%s" % relative)
                return
            self.send_json(200, {"ok": True})
            return

        self.send_error_json(405, "不支持的方法")

    def wait_and_reply(self, run, after, timeout):
        deadline = time.time() + timeout
        with run.condition:
            while True:
                if len(run.events) > after:
                    break
                if run.state != "running":
                    break
                remaining = deadline - time.time()
                if remaining <= 0:
                    break
                run.condition.wait(min(remaining, 1.0))
            batch = run.events[after:]
            state = run.state
            error = run.error
            usage = run.usage
        self.send_json(200, {
            "ok": True,
            "events": batch,
            "state": state,
            "error": error,
            "usage": usage,
        })


class ThreadingServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    daemon_threads = True
    allow_reuse_address = True


# ---------------------------------------------------------------- 启动


def load_sandboxes(root):
    base = os.path.join(root, "sandboxes")
    os.makedirs(base, exist_ok=True)
    for name in sorted(os.listdir(base)):
        path = os.path.join(base, name)
        if not os.path.isdir(path) or not SANDBOX_NAME_RE.match(name):
            continue
        sandbox = Sandbox(name, root)
        try:
            with open(sandbox.meta_path, "r", encoding="utf-8") as handle:
                meta = json.load(handle)
            sandbox.state = meta.get("state", "active")
            sandbox.created_at = float(meta.get("createdAt") or sandbox.created_at)
        except (OSError, ValueError):
            pass
        # 服务重启后旧的暂停态保持有效；运行中的任务已丢失，恢复为 active
        if sandbox.state not in ("active", "paused"):
            sandbox.state = "active"
        SANDBOXES[name] = sandbox


def ensure_sandbox(sid):
    with LOCK:
        sandbox = SANDBOXES.get(sid)
        if sandbox is not None:
            return sandbox
        path = sandbox_dir(ARGS.root, sid)
        if path is None:
            return None
        sandbox = Sandbox(sid, ARGS.root)
        os.makedirs(sandbox.path, exist_ok=True)
        sandbox.write_meta()
        SANDBOXES[sid] = sandbox
        return sandbox


def main():
    parser = argparse.ArgumentParser(description="DSH 云端推理 Agent")
    parser.add_argument("--port", type=int, default=8931)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--token", required=True)
    parser.add_argument("--root", default=os.path.join(os.path.expanduser("~"), ".dsh"))
    global ARGS
    ARGS = parser.parse_args()

    os.makedirs(ARGS.root, exist_ok=True)
    load_sandboxes(ARGS.root)

    server = ThreadingServer((ARGS.host, ARGS.port), Handler)
    server.token = ARGS.token
    server.root = ARGS.root
    print("DSH agent listening on %s:%s (root=%s)" % (ARGS.host, ARGS.port, ARGS.root), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()