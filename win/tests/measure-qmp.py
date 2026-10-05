#!/usr/bin/env python3
"""Measure control/input latency of the loopback diagnostic QEMU endpoint."""
import argparse
import json
import socket
import statistics
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--port", type=int, default=22702)
parser.add_argument("--samples", type=int, default=30)
args = parser.parse_args()
with socket.create_connection(("127.0.0.1", args.port), timeout=10) as sock:
    sock.settimeout(10)
    stream = sock.makefile("rwb")
    assert "QMP" in json.loads(stream.readline())
    request_id = 0

    def execute(command, arguments=None):
        global request_id
        request_id += 1
        start = time.monotonic()
        stream.write((json.dumps({"execute": command, "arguments": arguments or {}, "id": request_id}) + "\n").encode())
        stream.flush()
        while True:
            reply = json.loads(stream.readline())
            if reply.get("id") == request_id:
                if "error" in reply:
                    raise RuntimeError(reply["error"])
                return (time.monotonic() - start) * 1000

    execute("qmp_capabilities")
    latency = []
    for index in range(args.samples):
        latency.append(execute("query-status"))
        if index == 0:
            execute("send-key", {"keys": [{"type": "qcode", "data": "a"}], "hold-time": 50})
        time.sleep(0.2)
    print(json.dumps({"samples": len(latency), "median_ms": statistics.median(latency),
                      "max_ms": max(latency), "p95_ms": sorted(latency)[int((len(latency) - 1) * .95)]}, indent=2))
    execute("send-key", {"keys": [{"type": "qcode", "data": "backspace"}], "hold-time": 50})
