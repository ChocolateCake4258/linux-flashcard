#!/usr/bin/env python3
"""Send one QMP request over a loopback-only SSH-forwarded diagnostic port."""
import argparse
import json
import socket

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("command")
parser.add_argument("--arguments", default="{}")
parser.add_argument("--port", type=int, default=22702)
args = parser.parse_args()
with socket.create_connection(("127.0.0.1", args.port), timeout=10) as sock:
    sock.settimeout(10)
    stream = sock.makefile("rwb")
    greeting = json.loads(stream.readline())
    if "QMP" not in greeting:
        raise SystemExit("Unexpected QMP greeting")
    for index, (command, arguments) in enumerate([
        ("qmp_capabilities", {}), (args.command, json.loads(args.arguments))
    ]):
        stream.write((json.dumps({"execute": command, "arguments": arguments, "id": index}) + "\n").encode())
        stream.flush()
        while True:
            line = stream.readline()
            if not line:
                raise SystemExit("QMP disconnected")
            reply = json.loads(line)
            if reply.get("id") == index:
                break
        if "error" in reply:
            raise SystemExit(json.dumps(reply["error"]))
    print(json.dumps(reply, indent=2))
