#!/usr/bin/env python3
"""Execute a disposable kernel through the loopback-only diagnostic Jupyter server."""
import datetime
from contextlib import closing
import json
import time
import urllib.request
import uuid

from websocket import create_connection

base = "http://127.0.0.1:8898"
token = "pf-diagnostic-only"


def request(path, method="GET", data=None):
    body = None if data is None else json.dumps(data).encode()
    req = urllib.request.Request(base + path, data=body, method=method,
                                 headers={"Authorization": "token " + token,
                                          "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=15) as response:
        payload = response.read()
        return json.loads(payload) if payload else None


kernel = request("/api/kernels", "POST", {"name": "python3"})
try:
    message_id = uuid.uuid4().hex
    with closing(create_connection(f"ws://127.0.0.1:8898/api/kernels/{kernel['id']}/channels?token={token}", timeout=10)) as socket:
        socket.send(json.dumps({
            "header": {"msg_id": message_id, "username": "diagnostic", "session": uuid.uuid4().hex,
                       "msg_type": "execute_request", "version": "5.3",
                       "date": datetime.datetime.now(datetime.timezone.utc).isoformat()},
            "parent_header": {}, "metadata": {}, "channel": "shell",
            "content": {"code": "print(6 * 7)", "silent": False, "store_history": False,
                        "user_expressions": {}, "allow_stdin": False, "stop_on_error": True},
        }))
        output = ""
        replied = idle = False
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline and not (replied and idle):
            message = json.loads(socket.recv())
            if message.get("parent_header", {}).get("msg_id") != message_id:
                continue
            kind = message["header"]["msg_type"]
            content = message["content"]
            if kind == "stream":
                output += content["text"]
            elif kind == "execute_reply":
                if content["status"] != "ok":
                    raise RuntimeError("Kernel execution failed: " + str(content))
                replied = True
            elif kind == "status" and content["execution_state"] == "idle":
                idle = True
        if not (replied and idle and output.strip() == "42"):
            raise RuntimeError(f"Incomplete execution: replied={replied}, idle={idle}, output={output!r}")
        print("PASS: Jupyter REST/WebSocket kernel executed Python and returned 42.")
finally:
    request("/api/kernels/" + kernel["id"], "DELETE")
