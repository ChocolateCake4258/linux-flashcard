#!/usr/bin/env python3
"""Type ASCII text into the focused diagnostic VM window using a US key layout."""
import argparse
import json
import pathlib
import subprocess
import sys
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("text")
parser.add_argument("--port", type=int, default=22702)
args = parser.parse_args()
plain = {" ": "spc", "-": "minus", "=": "equal", ".": "dot", ",": "comma",
         "/": "slash", ";": "semicolon", "'": "apostrophe", "[": "bracket_left",
         "]": "bracket_right", "\\": "backslash", "`": "grave_accent", "\n": "ret"}
shifted = dict(zip("!@#$%^&*()", "1234567890"))
shifted.update({"_": "minus", "+": "equal", ":": "semicolon", '"': "apostrophe",
                "<": "comma", ">": "dot", "?": "slash", "{": "bracket_left",
                "}": "bracket_right", "|": "backslash", "~": "grave_accent"})
requests = []
for character in args.text:
    keys = []
    if character in shifted or "A" <= character <= "Z":
        keys.append({"type": "qcode", "data": "shift"})
    if character.isascii() and character.isalnum():
        code = character.lower()
    elif character in plain or character in shifted:
        code = plain.get(character, shifted.get(character))
    else:
        parser.error(f"Unsupported character: {character!r}")
    keys.append({"type": "qcode", "data": code})
    requests.append({"keys": keys, "hold-time": 50})
helper = pathlib.Path(__file__).with_name("qmp-command.py")
for request in requests:
    subprocess.run([sys.executable, str(helper), "send-key", "--port", str(args.port),
                    "--arguments", json.dumps(request)], check=True, stdout=subprocess.DEVNULL)
    time.sleep(0.15)
print(f"Typed {len(requests)} characters into the selected diagnostic VM.")
