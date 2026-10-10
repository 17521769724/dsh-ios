#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""DSH 云端推理 Agent（部署在用户自己的云服务器上）

职责：
  * 接收 iOS 客户端发来的会话，调用模型接口推理，把输出以「事件」形式缓存并流式返回；
  * 客户端断开（App 进入后台）时不中断推理，客户端回来按游标（after=N）续取，补齐全部内容；
  * 管理沙盒（工作目录）：自动创建 / 暂停 / 恢复 / 销毁；
  * 沙盒文件的上传、下载、列表、删除。

仅使用 Python 标准库（无第三方依赖），个人单用户使用；除 /health 外所有接口都需要
启动时生成的 Bearer Token 鉴权（Token 只保存在 iOS 客户端钥匙串，不落盘到本机明文配置之外）。

用法：
    python3 dsh-agent.py --port 8931 --token <TOKEN> [--root ~/.dsh] [--host 0.0.0.0]
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
from http.server import BaseHTTPRequestHandler

AGENT_VERSION = "1.0"
RUN_EVENT_LIMIT = 200_000          # 单个 run 的事件上限（防内存失控）
SANDBOX_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
RUN_ID_RE = re.compile(r"^r[A-Za-z0-9-]{6,64}$")

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

    def append(self, event_type, text=None, usage=None, error=None):
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
            self.events.append(event)
            self.condition.notify_all()

    def finish(self, state, error=None):
        with self.condition:
            self.state = state
            self.error = error
            self.condition.notify_all()


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


def build_model_payload(request_body):
    """把客户端参数整理成 OpenAI 兼容的 /chat/completions 请求体。"""
    messages = []
    for message in request_body.get("messages", []):
        role = message.get("role")
        content = message.get("content")
        if role not in ("system", "user", "assistant") or not isinstance(content, str) or not content:
            continue
        messages.append({"role": role, "content": content})

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
    return payload


def run_inference(run, request_body):
    """在后台线程里执行一次推理：把增量缓存为事件，客户端断线也不中断。"""
    base = str(request_body.get("baseURL") or "https://api.deepseek.com").rstrip("/")
    api_key = str(request_body.get("apiKey") or "")
    url = base + "/chat/completions"
    payload = build_model_payload(request_body)

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
    try:
        with urllib.request.urlopen(request, timeout=600) as response:
            for raw_line in response:
                if run.stop_flag:
                    run.finish("stopped")
                    return
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
                    run.append("content", text=content)
                reasoning = delta.get("reasoning_content") or delta.get("reasoning")
                if reasoning:
                    run.append("reasoning", text=reasoning)
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
            threading.Thread(target=run_inference, args=(run, body), daemon=True).start()
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
            self.send_json(200, {"ok": True})
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