#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""DSH 云端推理 Agent（部署在用户自己的云服务器上）

职责：
  * 接收 iOS 客户端发来的会话，调用模型接口推理，把输出以「事件」形式缓存并流式返回；
  * 客户端断开（App 进入后台）时不中断推理，客户端回来按游标（after=N）续取，补齐全部内容；
  * 管理沙盒（工作目录）：自动创建 / 暂停 / 恢复 / 销毁；
  * 沙盒文件的上传、下载、列表、删除；
  * 带工具调用循环的智能体：服务端执行（web_fetch / web_search / workspace / python_exec /
    calculator / current_time / http_request / mcp_*），或把调用发回手机端执行
    （ssh_exec / browser_* / screenshot / clipboard / reminder / github / gitee / skill 等），
    使云端推理与 App 本地推理具备同样的智能体能力。

仅使用 Python 标准库（无第三方依赖），个人单用户使用；除 /health 外所有接口都需要
启动时生成的 Bearer Token 鉴权（Token 只保存在 iOS 客户端钥匙串，不落盘到本机明文配置之外）。

用法：
    python3 dsh-agent.py --port 8931 --token <TOKEN> [--root ~/.dsh] [--host 0.0.0.0] [--verbose]

接口清单（除 /health 外都要 Bearer Token）：
    GET    /health                                  健康检查（无需鉴权）
    GET    /sandboxes                               沙盒列表
    POST   /sandboxes                               创建沙盒
    GET    /sandboxes/<sid>                         沙盒详情
    DELETE /sandboxes/<sid>                         销毁沙盒
    POST   /sandboxes/<sid>/pause | /resume         暂停 / 恢复
    GET    /sandboxes/<sid>/files[...]              文件列表 / 下载
    PUT    /sandboxes/<sid>/files/<path>            上传文件
    DELETE /sandboxes/<sid>/files/<path>            删除文件
    POST   /sandboxes/<sid>/chat                    发起推理，返回 runId
    GET    /sandboxes/<sid>/runs/<rid>?after=N      按游标长轮询取事件
    GET    /sandboxes/<sid>/runs                    任务列表
    POST   /sandboxes/<sid>/runs/<rid>/stop         停止任务
    POST   /sandboxes/<sid>/runs/<rid>/tool_result  手机端回传工具结果

事件类型（沿用 {"i":n,"type":...} 结构，追加到 run.events）：
    content / reasoning / usage / tool_call / tool_result / error
    tool_call / tool_result 结构：
      {"i":n,"type":"tool_call",  "callId":"call_1","name":"ssh_exec",
       "arguments":"{\"command\":\"ls\"}","source":"client"}
      {"i":n,"type":"tool_result","callId":"call_1","name":"ssh_exec","output":"...",
       "source":"client","failed":false}
    source = "server"（Agent 自己执行）或 "client"（等手机端回传）；
    arguments 为模型给出的原始 JSON 字符串（原样透传，不做解析后重拼）。

工具调用协议（v1.2，向后兼容 v1.1 / v1.0）：
  POST /sandboxes/<sid>/chat 除现有字段外，可另带（均可选）：
    "tools":         [ {OpenAI function 工具对象} ]     # 直接下发给模型的 tools 数组
    "mcpServers":    [ {"name","url","headers",
                        "tools":[{"modelName":"mcp_<别名>_<工具>","name":"<真实工具名>"}]} ]
    "maxToolRounds": 6      # 工具轮上限，默认 6，上限 12
    "toolTimeout":   180    # 等待手机端回传结果的秒数，默认 180，上限 600
  不传这些字段时行为与 v1.0 完全一致（单轮推理）。
  v1.2 相比 v1.1：新增服务端工具 web_search / python_exec / calculator / current_time /
  http_request；工具层改为注册表；单个工具 handler 抛异常不再拖垮整个 run。

  手机端回传工具结果：
    POST /sandboxes/<sid>/runs/<rid>/tool_result
    body: {"id":"call_1","output":"工具输出文本"}
    成功 → 200 {"ok":true}；找不到等待中的调用 → 404 {"error":"没有等待中的工具调用"}

安全边界：
  * 除 /health 外一切接口都要 Bearer Token；
  * workspace / python_exec 的文件操作限制在各自沙盒目录内（safe_path 防越界）；
  * python_exec 用参数传递脚本路径执行，绝不把代码拼进 shell 命令；
  * calculator 只做受限的算术求值（白名单 AST 节点），不执行任意代码；
  * 日志不打印 apiKey，也不打印完整 messages；
  * 模型 Key 随请求下发、不落盘；服务重启会丢失进行中的任务。
"""

import argparse
import ast
import json
import math
import operator
import os
import re
import shutil
import socketserver
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone
from html import unescape
from http.server import BaseHTTPRequestHandler

try:  # Python 3.9+ 才有 zoneinfo / tzdata；缺失时 current_time 回退 UTC
    from zoneinfo import ZoneInfo
except ImportError:  # noqa: BLE001 - 低版本解释器或缺少 tzdata
    ZoneInfo = None

# ---------------------------------------------------------------- 常量与上限
# 所有超时、截断长度、轮次上限、目录名集中在此处，便于统一调整。

AGENT_VERSION = "1.2"

# —— 运行与沙盒 ——
RUN_EVENT_LIMIT = 200_000          # 单个 run 的事件上限（防内存失控）
SANDBOX_SUBDIR = "sandboxes"       # 沙盒根目录名（位于 --root 之下）
SANDBOX_META_FILE = "sandbox.json"  # 沙盒元数据文件名
SANDBOX_RUN_HISTORY = 20           # 每个沙盒保留最近多少个 run
SANDBOX_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
RUN_ID_RE = re.compile(r"^r[A-Za-z0-9-]{6,64}$")

# —— 工具循环 ——
MAX_TOOL_ROUNDS = 12               # 工具轮上限（maxToolRounds 的封顶值）
MAX_TOOL_ROUNDS_DEFAULT = 6        # 工具轮默认值（与 App 本地推理一致）
ROUND_TOOL_LIMIT = 6               # 单轮工具调用次数上限
TOOL_OUTPUT_LIMIT = 16_000         # 单个工具输出字符上限
TOOL_TIMEOUT_MAX = 600             # 等待手机端结果的秒数上限
TOOL_TIMEOUT_DEFAULT = 180         # 等待手机端结果的秒数默认值

# —— 模型接口 ——
MODEL_STREAM_TIMEOUT = 600         # 单次流式模型请求的超时（秒）
MODEL_BASE_URL_DEFAULT = "https://api.deepseek.com"
MODEL_NAME_DEFAULT = "deepseek-flash"

# —— 网页抓取 ——
WEB_FETCH_TIMEOUT = 20             # 网页抓取超时（秒）
WEB_FETCH_LIMIT = 8_000            # 网页正文截断字符数
HTTP_READ_LIMIT = 2_000_000        # 单次网络响应读取字节上限
TEXT_PREVIEW_LIMIT = 200_000       # 可作为文本预览的文件大小上限（字节）

# —— 联网搜索 ——
WEB_SEARCH_TIMEOUT = 10            # 每次搜索请求超时（秒）
WEB_SEARCH_LIMIT = 4_000           # 搜索结果合计截断字符数
WEB_SEARCH_COUNT_DEFAULT = 5       # 默认返回条数
WEB_SEARCH_COUNT_MAX = 10          # 返回条数上限
WEB_SEARCH_MIN_INTERVAL = 1.0      # 相邻两次搜索的最小间隔（秒，进程内限流）

# —— Python 执行 ——
PYTHON_EXEC_TIMEOUT_DEFAULT = 20   # python_exec 默认超时（秒）
PYTHON_EXEC_TIMEOUT_MAX = 60       # python_exec 超时上限（秒）
PYTHON_EXEC_LIMIT = 8_000          # python_exec 输出截断字符数

# —— 计算器 ——
CALC_MAX_LENGTH = 500              # 表达式最长字符数
CALC_MAX_EXPONENT = 1000           # 幂运算指数上限（防超大整数拖垮内存）

# —— HTTP 请求工具 ——
HTTP_REQUEST_TIMEOUT = 20          # http_request 默认超时（秒）
HTTP_REQUEST_TIMEOUT_MAX = 60      # http_request 超时上限（秒）
HTTP_REQUEST_LIMIT = 8_000         # http_request 响应截断字符数

# —— MCP ——
MCP_PROTOCOL_VERSION = "2025-03-26"
MCP_TIMEOUT = 30                   # MCP 单次请求超时（秒）

# —— 文件上传与事件长轮询 ——
FILE_UPLOAD_LIMIT = 64 * 1024 * 1024   # 上传文件大小上限（字节）
RUN_POLL_DEFAULT = 20.0            # 事件长轮询默认等待秒数
RUN_POLL_MAX = 60.0                # 事件长轮询最大等待秒数

BROWSER_UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
              "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1")

# ---------------------------------------------------------------- 日志

LOG_LEVELS = {"debug": 10, "info": 20, "warn": 30, "error": 40}
LOG_LEVEL = LOG_LEVELS["info"]     # 当前日志级别；--verbose 时降到 debug


def log(level, message):
    """极简日志：默认打印 info 及以上，--verbose 时打印 debug，统一输出到 stderr。

    约定：绝不打印 apiKey，也不打印完整 messages（避免密钥与隐私泄露）。
    """
    if LOG_LEVELS.get(level, LOG_LEVELS["info"]) < LOG_LEVEL:
        return
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    print("[%s] %s %s" % (stamp, level.upper(), message), file=sys.stderr, flush=True)


# ---------------------------------------------------------------- 全局状态

LOCK = threading.Lock()
SANDBOXES = {}          # id -> Sandbox
RUNS = {}               # "sandboxId/runId" -> Run
SEARCH_LOCK = threading.Lock()     # 联网搜索限流锁
SEARCH_LAST_AT = 0.0               # 上次联网搜索的时间戳（进程内限流用）


class Sandbox:
    def __init__(self, sid, root):
        self.id = sid
        self.path = os.path.join(root, SANDBOX_SUBDIR, sid)
        self.state = "active"
        self.created_at = time.time()
        self.runs = []

    @property
    def meta_path(self):
        return os.path.join(self.path, SANDBOX_META_FILE)

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
    return os.path.join(root, SANDBOX_SUBDIR, sandbox_id)


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


def is_text_preview(path, limit=TEXT_PREVIEW_LIMIT):
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

    model = str(request_body.get("model") or MODEL_NAME_DEFAULT)
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
    with urllib.request.urlopen(request, timeout=MODEL_STREAM_TIMEOUT) as response:
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


def tool_web_fetch(name, arguments, context):
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
            raw = response.read(HTTP_READ_LIMIT)
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


def tool_workspace(name, arguments, context):
    """在沙盒目录内操作文件（复用 safe_path 做越界防护，绝不越出沙盒）。"""
    sandbox = context.sandbox
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
            if target == base and name == SANDBOX_META_FILE:
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
            if full == os.path.join(base, SANDBOX_META_FILE) or not is_text_preview(full, 2_000_000):
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
    with urllib.request.urlopen(request, timeout=MCP_TIMEOUT) as response:
        response_headers = {}
        for key, value in response.headers.items():
            response_headers[key] = value
        raw = response.read(HTTP_READ_LIMIT) if expect_reply else b""
        content_type = response.headers.get("Content-Type") or ""
    return parse_mcp_body(raw, content_type), response_headers


def tool_mcp(name, arguments, context):
    """按 modelName 定位 MCP 服务器与真实工具名，走 Streamable HTTP 调用。"""
    mcp_servers = context.mcp_servers
    model_name = name
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


# ---------------------------------------------------------------- 联网搜索


def _strip_tags(fragment):
    """去标签、反转义实体、压缩空白，用于搜索结果标题/摘要。"""
    text = re.sub(r"(?s)<[^>]+>", "", fragment or "")
    text = unescape(text)
    return re.sub(r"\s+", " ", text).strip()


def _search_throttle():
    """进程内限流：相邻两次搜索至少间隔 WEB_SEARCH_MIN_INTERVAL 秒，避免被反爬。"""
    global SEARCH_LAST_AT
    with SEARCH_LOCK:
        wait = WEB_SEARCH_MIN_INTERVAL - (time.time() - SEARCH_LAST_AT)
        if wait > 0:
            time.sleep(wait)
        SEARCH_LAST_AT = time.time()


def fetch_text(url, timeout):
    """抓取 URL 文本，返回 (文本, 错误说明)；失败时文本为 None。"""
    request = urllib.request.Request(
        url,
        headers={"User-Agent": BROWSER_UA, "Accept": "text/html,application/xhtml+xml,*/*"},
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            charset = response.headers.get_content_charset() or "utf-8"
            return response.read(HTTP_READ_LIMIT).decode(charset, "replace"), None
    except urllib.error.HTTPError as error:
        return None, "HTTP %s %s" % (error.code, error.reason)
    except Exception as error:  # noqa: BLE001 - 网络异常统一转成可读错误
        return None, str(error)


def parse_bing_results(html, count):
    """从 Bing 搜索结果页解析 (标题, 链接, 摘要)；解析不到就返回空列表。"""
    results = []
    # 以每个结果块的开头切分，比非贪婪匹配 </li> 更能容忍结构变化
    for block in re.split(r'(?is)<li class="b_algo"', html)[1:]:
        link = re.search(r'(?is)<h2[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>', block)
        if not link:
            continue
        url = unescape(link.group(1)).strip()
        title = _strip_tags(link.group(2))
        snippet = ""
        para = re.search(r"(?is)<p[^>]*>(.*?)</p>", block)
        if para:
            snippet = _strip_tags(para.group(1))
        if title and url.lower().startswith("http"):
            results.append((title, url, snippet))
        if len(results) >= count:
            break
    return results


def _clean_ddg_url(url):
    """还原 DuckDuckGo 的跳转链接（//duckduckgo.com/l/?uddg=...）。"""
    url = url.strip()
    if "uddg=" in url:
        params = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
        if params.get("uddg"):
            return params["uddg"][0]
    if url.startswith("//"):
        return "https:" + url
    return url


def parse_ddg_results(html, count):
    """从 DuckDuckGo html 版解析结果（链接会经 uddg 跳转，需还原）。"""
    results = []
    anchors = list(re.finditer(
        r'(?is)<a[^>]+class="[^"]*result__a[^"]*"[^>]+href="([^"]+)"[^>]*>(.*?)</a>', html))
    for index, match in enumerate(anchors):
        end = anchors[index + 1].start() if index + 1 < len(anchors) else len(html)
        segment = html[match.end():end]
        url = _clean_ddg_url(unescape(match.group(1)))
        title = _strip_tags(match.group(2))
        snippet = ""
        snippet_match = re.search(
            r'(?is)<a[^>]+class="[^"]*result__snippet[^"]*"[^>]*>(.*?)</a>', segment)
        if snippet_match:
            snippet = _strip_tags(snippet_match.group(1))
        if title and url.lower().startswith("http"):
            results.append((title, url, snippet))
        if len(results) >= count:
            break
    return results


def parse_wikipedia_results(data, count):
    """把 Wikipedia search API 的 JSON 解析成 (标题, 链接, 摘要)。"""
    results = []
    if not isinstance(data, dict):
        return results
    query = data.get("query")
    items = query.get("search") if isinstance(query, dict) else None
    for item in items or []:
        if not isinstance(item, dict):
            continue
        title = str(item.get("title") or "").strip()
        if not title:
            continue
        snippet = _strip_tags(str(item.get("snippet") or ""))
        url = "https://zh.wikipedia.org/wiki/" + urllib.parse.quote(title.replace(" ", "_"))
        results.append((title, url, snippet))
        if len(results) >= count:
            break
    return results


def format_search_results(results, origin):
    """把结果整理成编号列表并截断。"""
    lines = []
    for index, item in enumerate(results, 1):
        title, url, snippet = item
        lines.append("%d. %s\n   %s\n   %s" % (index, title, url, snippet or "（无摘要）"))
    body = "（来自 %s）\n%s" % (origin, "\n".join(lines))
    return truncate_tool_output(body, WEB_SEARCH_LIMIT)


def tool_web_search(name, arguments, context):
    """关键词联网搜索：Bing → DuckDuckGo lite → Wikipedia，全部失败给出可读说明。"""
    query = str(arguments.get("query") or "").strip()
    if not query:
        return "缺少 query 参数", True
    try:
        count = int(arguments.get("count") or WEB_SEARCH_COUNT_DEFAULT)
    except (TypeError, ValueError):
        return "count 参数必须是数字", True
    count = max(1, min(WEB_SEARCH_COUNT_MAX, count))

    _search_throttle()
    encoded = urllib.parse.quote_plus(query)
    reasons = []

    # 1) Bing（国内可访问）
    html, error = fetch_text(
        "https://cn.bing.com/search?q=%s&count=%d" % (encoded, count), WEB_SEARCH_TIMEOUT)
    if html:
        results = parse_bing_results(html, count)
        if results:
            return format_search_results(results, "Bing"), False
        reasons.append("Bing 未解析到结果")
    else:
        reasons.append("Bing 请求失败：%s" % error)

    # 2) DuckDuckGo lite（回退）
    html, error = fetch_text(
        "https://html.duckduckgo.com/html/?q=%s" % encoded, WEB_SEARCH_TIMEOUT)
    if html:
        results = parse_ddg_results(html, count)
        if results:
            return format_search_results(results, "DuckDuckGo"), False
        reasons.append("DuckDuckGo 未解析到结果")
    else:
        reasons.append("DuckDuckGo 请求失败：%s" % error)

    # 3) Wikipedia API（最后回退）
    html, error = fetch_text(
        "https://zh.wikipedia.org/w/api.php?action=query&list=search&format=json&srsearch=%s"
        % encoded, WEB_SEARCH_TIMEOUT)
    if html:
        try:
            data = json.loads(html)
        except ValueError:
            data = None
        results = parse_wikipedia_results(data, count)
        if results:
            return format_search_results(results, "Wikipedia"), False
        reasons.append("Wikipedia 未解析到结果")
    else:
        reasons.append("Wikipedia 请求失败：%s" % error)

    return "联网搜索失败（可能是服务器无法访问外网或被限流）：%s" % "；".join(reasons), True


# ---------------------------------------------------------------- Python 执行


def tool_python_exec(name, arguments, context):
    """在沙盒目录内用同一解释器执行一小段 Python，捕获 stdout+stderr。

    代码先写入沙盒下的临时文件，再用 [sys.executable, 脚本路径] 参数调用（绝不拼 shell），
    执行完删除临时文件。
    """
    sandbox = context.sandbox
    if sandbox is None:
        return "沙盒不可用，无法执行 Python", True
    code = arguments.get("code")
    if not isinstance(code, str) or not code.strip():
        return "缺少 code 参数（需要非空的 Python 代码字符串）", True
    try:
        timeout = int(arguments.get("timeout") or PYTHON_EXEC_TIMEOUT_DEFAULT)
    except (TypeError, ValueError):
        return "timeout 参数必须是数字", True
    timeout = max(1, min(PYTHON_EXEC_TIMEOUT_MAX, timeout))

    workdir = sandbox.path
    os.makedirs(workdir, exist_ok=True)
    script_path = os.path.join(workdir, ".dsh_exec_%s.py" % uuid.uuid4().hex[:8])
    try:
        with open(script_path, "w", encoding="utf-8") as handle:
            handle.write(code)
        completed = subprocess.run(
            [sys.executable, script_path],
            cwd=workdir,
            capture_output=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return "执行超时（超过 %d 秒，已终止）" % timeout, True
    except OSError as error:
        return "执行失败：%s" % error, True
    finally:
        try:
            os.remove(script_path)
        except OSError:
            pass

    output = (completed.stdout or b"") + (completed.stderr or b"")
    text = output.decode("utf-8", "replace")
    if completed.returncode != 0:
        text = "退出码 %d\n%s" % (completed.returncode, text)
    text = text.strip()
    if not text:
        text = "（执行成功，没有输出）"
    return truncate_tool_output(text, PYTHON_EXEC_LIMIT), completed.returncode != 0


# ---------------------------------------------------------------- 计算器


# 只允许的运算符与函数白名单（映射到 operator / 内置 / math）
CALC_BIN_OPS = {
    ast.Add: operator.add,
    ast.Sub: operator.sub,
    ast.Mult: operator.mul,
    ast.Div: operator.truediv,
    ast.Mod: operator.mod,
    ast.Pow: operator.pow,
    ast.FloorDiv: operator.floordiv,
}
CALC_FUNCS = {
    "abs": abs, "round": round, "min": min, "max": max, "sum": sum,
    "len": len, "sqrt": math.sqrt, "pow": pow,
}


def _guard_exponent(exponent):
    """限制幂运算指数，避免 10**10**9 这类超大整数拖垮内存与 CPU。"""
    if isinstance(exponent, (int, float)) and abs(exponent) > CALC_MAX_EXPONENT:
        raise ValueError("幂运算指数过大（上限 %d）" % CALC_MAX_EXPONENT)


def _calc_eval(node):
    """递归求值：只接受常量 / 四则与幂运算 / 一元正负 / 白名单函数调用。"""
    if isinstance(node, ast.Expression):
        return _calc_eval(node.body)
    if isinstance(node, ast.Constant):
        if isinstance(node.value, bool) or not isinstance(node.value, (int, float)):
            raise ValueError("只允许数字常量")
        return node.value
    if isinstance(node, ast.BinOp):
        func = CALC_BIN_OPS.get(type(node.op))
        if func is None:
            raise ValueError("不支持的运算符")
        left = _calc_eval(node.left)
        right = _calc_eval(node.right)
        if isinstance(node.op, ast.Pow):
            _guard_exponent(right)
        return func(left, right)
    if isinstance(node, ast.UnaryOp):
        if isinstance(node.op, ast.UAdd):
            return +_calc_eval(node.operand)
        if isinstance(node.op, ast.USub):
            return -_calc_eval(node.operand)
        raise ValueError("不支持的一元运算")
    if isinstance(node, ast.Call):
        if not isinstance(node.func, ast.Name) or node.func.id not in CALC_FUNCS:
            raise ValueError("不允许调用该函数")
        if node.keywords:
            raise ValueError("函数不支持关键字参数")
        args = [_calc_eval(arg) for arg in node.args]
        if node.func.id == "pow" and len(args) > 1:
            _guard_exponent(args[1])
        return CALC_FUNCS[node.func.id](*args)
    raise ValueError("表达式包含不允许的内容")


def tool_calculator(name, arguments, context):
    """安全算术求值：用受限 AST 白名单，不执行任意代码。"""
    expression = arguments.get("expression")
    if not isinstance(expression, str) or not expression.strip():
        return "缺少 expression 参数（需要非空的算术表达式字符串）", True
    expression = expression.strip()
    if len(expression) > CALC_MAX_LENGTH:
        return "表达式过长（上限 %d 字符）" % CALC_MAX_LENGTH, True
    try:
        tree = ast.parse(expression, mode="eval")
        result = _calc_eval(tree)
    except (ValueError, SyntaxError, TypeError, ZeroDivisionError, OverflowError) as error:
        return "计算失败：%s" % error, True
    if isinstance(result, float) and result.is_integer():
        return "%s = %s" % (expression, int(result)), False
    return "%s = %s" % (expression, result), False


# ---------------------------------------------------------------- 当前时间


def _parse_moment(value):
    """把 timestamp 参数（秒数 / ISO 字符串）解析成带时区的 datetime；无法解析返回 None。"""
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        try:
            return datetime.fromtimestamp(float(value), tz=timezone.utc)
        except (OverflowError, OSError, ValueError):
            return None
    if isinstance(value, str) and value.strip():
        text = value.strip()
        if text.endswith("Z"):
            text = text[:-1] + "+00:00"
        try:
            parsed = datetime.fromisoformat(text)
        except ValueError:
            return None
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed
    return None


def tool_current_time(name, arguments, context):
    """当前时间与时区换算：返回 ISO 时间、星期、时区名与 UTC 偏移。"""
    zone_name = str(arguments.get("timezone") or "").strip() or "UTC"
    fallback_note = ""
    tz = timezone.utc
    if ZoneInfo is not None:
        try:
            tz = ZoneInfo(zone_name)
        except Exception:  # noqa: BLE001 - 时区名非法或缺少 tzdata
            tz = timezone.utc
            fallback_note = "（时区「%s」不可用，已回退 UTC）" % zone_name
    else:
        fallback_note = "（当前 Python 环境不支持 zoneinfo，已回退 UTC）"

    raw_timestamp = arguments.get("timestamp")
    moment = _parse_moment(raw_timestamp)
    invalid_note = ""
    if raw_timestamp is not None and moment is None:
        invalid_note = "（timestamp 无法解析，已按当前时刻处理）"
    if moment is None:
        moment = datetime.now(timezone.utc)

    local = moment.astimezone(tz)
    offset = local.utcoffset() or timedelta(0)
    total_minutes = int(offset.total_seconds() // 60)
    sign = "+" if total_minutes >= 0 else "-"
    offset_text = "UTC%s%02d:%02d" % (sign, abs(total_minutes) // 60, abs(total_minutes) % 60)
    weekday = "一二三四五六日"[local.weekday()]
    lines = [
        "时间：%s" % local.isoformat(),
        "星期：星期%s" % weekday,
        "时区：%s" % (zone_name if not fallback_note else "UTC"),
        "UTC 偏移：%s" % offset_text,
    ]
    note = fallback_note + invalid_note
    if note:
        lines.append(note)
    return "\n".join(lines), False


# ---------------------------------------------------------------- HTTP 请求


def tool_http_request(name, arguments, context):
    """调用任意 HTTP(S) 接口：给模型调开放 API 用。"""
    url = str(arguments.get("url") or "").strip()
    if not url:
        return "缺少 url 参数", True
    if not re.match(r"^https?://", url, re.I):
        return "只支持 http/https 链接", True

    method = str(arguments.get("method") or "GET").strip().upper() or "GET"
    if not re.match(r"^[A-Z]+$", method):
        return "method 不合法：%s" % method, True

    header_map = {}
    headers = arguments.get("headers")
    if isinstance(headers, dict):
        for key, value in headers.items():
            if isinstance(key, str) and isinstance(value, str):
                header_map[key] = value
    header_map.setdefault("User-Agent", BROWSER_UA)

    data = None
    body = arguments.get("body")
    if body is not None:
        if isinstance(body, (dict, list)):
            data = json.dumps(body, ensure_ascii=False).encode("utf-8")
            header_map.setdefault("Content-Type", "application/json")
        else:
            data = str(body).encode("utf-8")

    if method == "GET" and data is not None:
        # GET：把 body 当 query 字符串拼到 URL 后面
        separator = "&" if "?" in url else "?"
        url = url + separator + data.decode("utf-8")
        data = None

    try:
        timeout = int(arguments.get("timeout") or HTTP_REQUEST_TIMEOUT)
    except (TypeError, ValueError):
        return "timeout 参数必须是数字", True
    timeout = max(1, min(HTTP_REQUEST_TIMEOUT_MAX, timeout))

    request = urllib.request.Request(url, data=data, headers=header_map, method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            status = response.status
            charset = response.headers.get_content_charset() or "utf-8"
            content_type = response.headers.get("Content-Type") or ""
            raw = response.read(HTTP_READ_LIMIT)
    except urllib.error.HTTPError as error:
        status = error.code
        charset = "utf-8"
        content_type = (error.headers.get("Content-Type") if error.headers else "") or ""
        try:
            raw = error.read()
        except Exception:  # noqa: BLE001 - 读取错误响应体失败不影响返回状态码
            raw = b""
    except Exception as error:  # noqa: BLE001 - 超时/连接失败/非法 URL 等统一转成可读错误
        return "请求失败：%s" % error, True

    text = raw.decode(charset, "replace")
    if "json" in content_type.lower():
        try:
            text = json.dumps(json.loads(text), ensure_ascii=False, indent=2)
        except ValueError:
            pass
    output = "HTTP %s\n%s" % (status, text)
    return truncate_tool_output(output, HTTP_REQUEST_LIMIT), bool(status >= 400)


# ---------------------------------------------------------------- 工具注册表


class ToolContext:
    """一次工具执行所需的上下文（沙盒与 MCP 服务器配置）。"""

    def __init__(self, sandbox=None, mcp_servers=None):
        self.sandbox = sandbox
        self.mcp_servers = mcp_servers or []


class ToolSpec:
    """一个工具的注册信息：名字 / 执行面 / 处理函数 / 参数默认值。

    handler 统一签名 handler(name, arguments, context) -> (output, failed)；
    source = "server"（Agent 自己执行）或 "client"（发回手机端）。
    """

    def __init__(self, name, source, handler, defaults=None):
        self.name = name
        self.source = source
        self.handler = handler
        self.defaults = dict(defaults or {})


MCP_TOOL_PREFIX = "mcp_"

# 工具注册表：新增服务端工具只需在此加一行，不再写 if/elif 长链
TOOL_SPECS = {
    "web_fetch": ToolSpec("web_fetch", "server", tool_web_fetch),
    "workspace": ToolSpec("workspace", "server", tool_workspace),
    "web_search": ToolSpec("web_search", "server", tool_web_search,
                           defaults={"count": WEB_SEARCH_COUNT_DEFAULT}),
    "python_exec": ToolSpec("python_exec", "server", tool_python_exec,
                            defaults={"timeout": PYTHON_EXEC_TIMEOUT_DEFAULT}),
    "calculator": ToolSpec("calculator", "server", tool_calculator),
    "current_time": ToolSpec("current_time", "server", tool_current_time),
    "http_request": ToolSpec("http_request", "server", tool_http_request,
                             defaults={"method": "GET", "timeout": HTTP_REQUEST_TIMEOUT}),
}

# mcp_ 前缀是动态工具：名字不固定，用一条通用规格承接
MCP_SPEC = ToolSpec(MCP_TOOL_PREFIX, "server", tool_mcp)


def tool_source(name):
    """判断工具由谁执行：server = Agent 自己，client = 发回手机端。"""
    spec = TOOL_SPECS.get(name)
    if spec is not None:
        return spec.source
    if name.startswith(MCP_TOOL_PREFIX):
        return "server"
    return "client"


def execute_tool(name, arguments, context):
    """查表执行服务端工具，返回 (output, failed)。

    * 注册表中命中 → 补齐默认参数后调用 handler；
    * mcp_ 前缀 → 交给通用 MCP 规格；
    * 其余未注册工具 → 兜底为「手机端执行」（保持 v1.x 行为）；
    * handler 抛出的任何异常都转成 failed 结果，绝不让整个 run 崩掉。
    """
    spec = TOOL_SPECS.get(name)
    if spec is None:
        if name.startswith(MCP_TOOL_PREFIX):
            spec = MCP_SPEC
        else:
            return "不认识的工具：%s" % name, True
    merged = dict(spec.defaults)
    if isinstance(arguments, dict):
        merged.update(arguments)
    try:
        return spec.handler(name, merged, context)
    except Exception as error:  # noqa: BLE001 - 单个工具异常统一转成失败结果
        log("error", "工具 %s 执行异常：%s" % (name, error))
        return "工具执行出错：%s" % error, True


def run_inference(run, request_body, sandbox=None):
    """在后台线程里执行一次带工具循环的推理：把增量缓存为事件，客户端断线也不中断。"""
    base = str(request_body.get("baseURL") or MODEL_BASE_URL_DEFAULT).rstrip("/")
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
        tool_timeout = float(request_body.get("toolTimeout") or TOOL_TIMEOUT_DEFAULT)
    except (TypeError, ValueError):
        tool_timeout = float(TOOL_TIMEOUT_DEFAULT)
    tool_timeout = max(1.0, min(float(TOOL_TIMEOUT_MAX), tool_timeout))

    messages = normalize_messages(request_body.get("messages", []))
    has_tools = bool(tools) or bool(mcp_servers)
    context = ToolContext(sandbox, mcp_servers)
    log("info", "run=%s sandbox=%s 推理开始（tools=%s, mcp=%d, 轮次上限=%d）"
        % (run.id, run.sandbox_id, "有" if tools else "无", len(mcp_servers), max_rounds))

    try:
        for round_index in range(max_rounds):
            if run.stop_flag:
                log("info", "run=%s 已被停止" % run.id)
                run.finish("stopped")
                return
            # 最后一轮不下发工具，并追加一条临时 user 消息要结论（不写入事件流）
            is_last = round_index == max_rounds - 1
            round_messages = list(messages)
            round_tools = tools
            if is_last and has_tools:
                round_tools = None
                round_messages.append({"role": "user", "content": "不要再调用工具，请直接用文字给出结论。"})
            log("debug", "run=%s 第 %d/%d 轮请求模型（工具%s）"
                % (run.id, round_index + 1, max_rounds, "开" if round_tools else "关"))
            payload = build_model_payload(request_body, messages=round_messages, tools=round_tools)
            result = stream_completion(run, url, api_key, payload)
            if result is None:
                run.finish("stopped")
                return
            assistant_text, tool_calls = result
            if not tool_calls:
                run.finish("done")
                log("info", "run=%s 推理结束（state=done）" % run.id)
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
                log("info", "run=%s 调用工具 %s（source=%s, callId=%s）" % (run.id, name, source, call_id))
                run.append("tool_call", extra={
                    "callId": call_id, "name": name, "arguments": arguments_raw, "source": source,
                })
                if executed >= ROUND_TOOL_LIMIT:
                    output, failed = "本轮工具调用次数已达上限", True
                else:
                    executed += 1
                    try:
                        if source == "server":
                            output, failed = execute_tool(
                                name, parse_tool_arguments(arguments_raw), context)
                        else:
                            output, failed = run.wait_tool_result(call_id, tool_timeout)
                    except Exception as error:  # noqa: BLE001 - 单个工具异常不能拖垮整个 run
                        log("error", "run=%s 工具 %s 执行异常：%s" % (run.id, name, error))
                        output, failed = "工具执行出错：%s" % error, True
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
        log("info", "run=%s 推理结束（state=%s）" % (run.id, run.state))
    except urllib.error.HTTPError as error:
        detail = ""
        try:
            detail = error.read().decode("utf-8", "replace")[:500]
        except Exception:  # noqa: BLE001 - 读取错误体失败不影响主流程
            pass
        log("error", "run=%s 模型接口返回 %s" % (run.id, error.code))
        run.append("error", error="模型接口返回 %s：%s" % (error.code, detail or error.reason))
        run.finish("error", error="模型接口返回 %s" % error.code)
    except Exception as error:  # noqa: BLE001 - 网络异常统一转成事件
        log("error", "run=%s 推理失败：%s" % (run.id, error))
        run.append("error", error="推理失败：%s" % error)
        run.finish("error", error=str(error))


# ---------------------------------------------------------------- HTTP 处理


def json_response(handler, status, obj):
    """统一的 JSON 响应（各接口都走这里，避免重复拼响应头）。"""
    body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def error_json(handler, status, message):
    """统一的错误响应：{"ok": false, "error": ...}。"""
    json_response(handler, status, {"ok": False, "error": message})


def read_raw_body(handler):
    """读取原始请求体（无 Content-Length 时返回空字节）。"""
    length = int(handler.headers.get("Content-Length") or 0)
    if length <= 0:
        return b""
    return handler.rfile.read(length)


def read_json_body(handler):
    """读取并解析 JSON 请求体；为空或解析失败时返回空 dict。"""
    raw = read_raw_body(handler)
    if not raw:
        return {}
    try:
        return json.loads(raw.decode("utf-8"))
    except ValueError:
        return {}


class Handler(BaseHTTPRequestHandler):
    server_version = "DSHAgent/" + AGENT_VERSION
    protocol_version = "HTTP/1.1"

    # ---------- 基础响应

    def log_message(self, fmt, *args):  # 静默：日志由 launchd/nohup 收集，不需要每请求一行
        pass

    def send_bytes(self, status, body, content_type="application/octet-stream", filename=None):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        if filename:
            self.send_header("Content-Disposition", 'attachment; filename="%s"' % filename)
        self.end_headers()
        self.wfile.write(body)

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
            json_response(self, 200, body)
            return

        if not self.authorized():
            error_json(self, 401, "未授权：Token 不正确")
            return

        parts = [urllib.parse.unquote(p) for p in path.strip("/").split("/") if p]
        try:
            if parts[:1] == ["sandboxes"]:
                self.handle_sandboxes(method, parts[1:], query)
                return
            error_json(self, 404, "没有这个接口：%s" % path)
        except Exception as error:  # noqa: BLE001 - 兜底，避免线程因异常静默断开
            error_json(self, 500, "服务内部错误：%s" % error)

    # ---------- 沙盒与文件

    def handle_sandboxes(self, method, parts, query):
        # /sandboxes
        if not parts:
            if method == "GET":
                with LOCK:
                    items = [sandbox.snapshot() for sandbox in sorted(SANDBOXES.values(), key=lambda s: s.id)]
                json_response(self, 200, {"ok": True, "sandboxes": items})
                return
            if method == "POST":
                body = read_json_body(self)
                sid = str(body.get("id") or "").strip() or ("s" + uuid.uuid4().hex[:8])
                sandbox = ensure_sandbox(sid)
                if sandbox is None:
                    error_json(self, 400, "沙盒名不合法（只能字母数字与 . _ -，最长 64 位）")
                    return
                json_response(self, 200, {"ok": True, "sandbox": sandbox.snapshot()})
                return
            error_json(self, 405, "不支持的方法")
            return

        sid = parts[0]
        sandbox = ensure_sandbox(sid)
        if sandbox is None:
            error_json(self, 404, "沙盒不存在：%s" % sid)
            return

        # /sandboxes/<id>
        if len(parts) == 1:
            if method == "GET":
                json_response(self, 200, {"ok": True, "sandbox": sandbox.snapshot()})
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
                json_response(self, 200, {"ok": True})
                return
            error_json(self, 405, "不支持的方法")
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
            json_response(self, 200, {"ok": True, "sandbox": sandbox.snapshot()})
            return

        # /sandboxes/<id>/files[...]
        if action == "files":
            self.handle_files(method, sandbox, parts[2:])
            return

        # /sandboxes/<id>/chat
        if action == "chat" and len(parts) == 2 and method == "POST":
            if sandbox.state != "active":
                error_json(self, 409, "沙盒已暂停：请先恢复再发送会话")
                return
            body = read_json_body(self)
            if not body.get("messages"):
                error_json(self, 400, "缺少 messages")
                return
            run = Run("r" + uuid.uuid4().hex[:12], sid)
            with LOCK:
                RUNS[sid + "/" + run.id] = run
                sandbox.runs.append(run)
                sandbox.runs = sandbox.runs[-SANDBOX_RUN_HISTORY:]
            threading.Thread(target=run_inference, args=(run, body, sandbox), daemon=True).start()
            json_response(self, 200, {"ok": True, "runId": run.id, "sandbox": sid})
            return

        # /sandboxes/<id>/runs/<runId>[?after=N&timeout=20]
        if action == "runs" and len(parts) >= 3 and method == "GET":
            run = RUNS.get(sid + "/" + parts[2])
            if run is None:
                error_json(self, 404, "任务不存在（可能服务重启过）：%s" % parts[2])
                return
            after = int(query.get("after") or 0)
            timeout = min(RUN_POLL_MAX, max(1.0, float(query.get("timeout") or RUN_POLL_DEFAULT)))
            self.wait_and_reply(run, after, timeout)
            return

        # /sandboxes/<id>/runs/<runId>/stop
        if action == "runs" and len(parts) == 4 and parts[3] == "stop" and method == "POST":
            run = RUNS.get(sid + "/" + parts[2])
            if run is None:
                error_json(self, 404, "任务不存在")
                return
            run.stop_flag = True
            run.wake_pending()
            json_response(self, 200, {"ok": True})
            return

        # /sandboxes/<id>/runs/<runId>/tool_result —— 手机端回传工具结果
        if action == "runs" and len(parts) == 4 and parts[3] == "tool_result" and method == "POST":
            run = RUNS.get(sid + "/" + parts[2])
            if run is None:
                error_json(self, 404, "任务不存在")
                return
            body = read_json_body(self)
            call_id = str(body.get("id") or "").strip()
            if not call_id:
                json_response(self, 400, {"error": "缺少 id"})
                return
            output = body.get("output")
            if output is None:
                output = ""
            if run.deliver_tool_result(call_id, str(output)):
                json_response(self, 200, {"ok": True})
            else:
                json_response(self, 404, {"error": "没有等待中的工具调用"})
            return

        # /sandboxes/<id>/runs
        if action == "runs" and len(parts) == 2 and method == "GET":
            with LOCK:
                items = [
                    {"id": run.id, "state": run.state, "events": len(run.events), "createdAt": run.created_at}
                    for run in sandbox.runs
                ]
            json_response(self, 200, {"ok": True, "runs": items})
            return

        error_json(self, 404, "没有这个接口")

    def handle_files(self, method, sandbox, parts):
        if not parts and method == "GET":
            items = []
            for base, _dirs, files in os.walk(sandbox.path):
                for name in sorted(files):
                    full = os.path.join(base, name)
                    relative = os.path.relpath(full, sandbox.path)
                    if relative == SANDBOX_META_FILE:
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
            json_response(self, 200, {"ok": True, "files": items})
            return

        relative = "/".join(parts)
        target = safe_path(sandbox.path, relative)
        if target is None:
            error_json(self, 400, "路径不合法")
            return

        if method == "PUT":
            body = read_raw_body(self)
            if len(body) > FILE_UPLOAD_LIMIT:
                error_json(self, 413, "文件过大（上限 64 MB）")
                return
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, "wb") as handle:
                handle.write(body)
            json_response(self, 200, {"ok": True, "name": relative, "size": len(body)})
            return

        if method == "GET":
            if not os.path.isfile(target):
                error_json(self, 404, "文件不存在：%s" % relative)
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
                error_json(self, 404, "文件不存在：%s" % relative)
                return
            json_response(self, 200, {"ok": True})
            return

        error_json(self, 405, "不支持的方法")

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
        json_response(self, 200, {
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
    base = os.path.join(root, SANDBOX_SUBDIR)
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
    parser.add_argument("--verbose", action="store_true", help="打印 debug 级日志到 stderr")
    global ARGS, LOG_LEVEL
    ARGS = parser.parse_args()
    if ARGS.verbose:
        LOG_LEVEL = LOG_LEVELS["debug"]

    os.makedirs(ARGS.root, exist_ok=True)
    load_sandboxes(ARGS.root)

    server = ThreadingServer((ARGS.host, ARGS.port), Handler)
    server.token = ARGS.token
    server.root = ARGS.root
    print("DSH agent listening on %s:%s (root=%s)" % (ARGS.host, ARGS.port, ARGS.root), flush=True)
    log("info", "启动 DSH Agent v%s：host=%s port=%s root=%s 沙盒数=%d verbose=%s"
        % (AGENT_VERSION, ARGS.host, ARGS.port, ARGS.root, len(SANDBOXES), ARGS.verbose))
    server.serve_forever()


if __name__ == "__main__":
    main()