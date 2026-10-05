#!/usr/bin/env python3
"""Run a command through a loopback-only diagnostic guest serial console."""
import argparse
import base64
import pathlib
import re
import shlex
import socket
import sys
import time
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("command", nargs="?", default="true")
parser.add_argument("--upload")
parser.add_argument("--destination")
parser.add_argument("--port", type=int, default=22701)
parser.add_argument("--timeout", type=float, default=120)
args = parser.parse_args()
if args.upload:
    if not args.destination or not args.destination.startswith("/"):
        parser.error("Upload requires an absolute guest destination")
    data = base64.b64encode(pathlib.Path(args.upload).read_bytes()).decode()
    directory = shlex.quote(str(pathlib.PurePosixPath(args.destination).parent))
    destination = shlex.quote(args.destination)
    args.command = f"(test -d {directory} || install -d -m 755 {directory}) && printf %s {shlex.quote(data)} | base64 -d > {destination}"
marker = "__PF_STATUS_" + uuid.uuid4().hex + "_"
pattern = re.compile(re.escape(marker.encode()) + rb"([0-9]+)__")
with socket.create_connection(("127.0.0.1", args.port), timeout=10) as sock:
    sock.settimeout(1)
    sock.sendall(b"\r")
    ready = bytearray()
    ready_deadline = time.monotonic() + 90
    while not re.search(rb"root@[^\r\n]*#", ready):
        if time.monotonic() >= ready_deadline:
            sys.exit("Diagnostic root console is not ready; no command was sent.")
        try:
            data = sock.recv(65536)
        except socket.timeout:
            sock.sendall(b"\r")
            continue
        if not data:
            sys.exit("Diagnostic serial console disconnected before login.")
        ready.extend(data)
    sock.sendall(b"stty -echo\r")
    time.sleep(0.3)
    sock.sendall(("(" + args.command + "); rc=$?; printf '\\n" + marker + "%s__\\n' \"$rc\"\r").encode())
    output = bytearray()
    deadline = time.monotonic() + args.timeout
    while time.monotonic() < deadline:
        try:
            chunk = sock.recv(65536)
        except socket.timeout:
            continue
        if not chunk:
            break
        output.extend(chunk)
        match = pattern.search(output)
        if match:
            text = output[:match.start()].decode("utf-8", errors="replace")
            text = re.sub(r"\x1b\].*?(?:\x07|\x1b\\)", "", text, flags=re.S)
            text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", text)
            text = text.replace("\r", "")
            sys.stdout.write(text)
            sys.exit(int(match[1]))
    sys.stdout.write(output.decode("utf-8", errors="replace"))
    sys.exit("Guest command did not complete within the serial timeout.")
