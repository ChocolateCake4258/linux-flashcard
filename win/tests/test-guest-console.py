#!/usr/bin/env python3
"""Exercise the actual upload command without opening a guest console."""
import ast
import base64
import os
import pathlib
import shlex
import stat
import subprocess
import tempfile
import unittest

source = pathlib.Path(__file__).with_name("guest-console.py")
assignments = [
    node for node in ast.walk(ast.parse(source.read_text()))
    if isinstance(node, ast.Assign)
    and any(isinstance(target, ast.Attribute) and target.attr == "command" for target in node.targets)
]
assert len(assignments) == 1, "Expected one upload command assignment"
expression = compile(ast.Expression(assignments[0].value), str(source), "eval")


class UploadTests(unittest.TestCase):
    def test_existing_directory_permissions_are_preserved(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR")) as temporary:
            directory = pathlib.Path(temporary) / "existing ' directory"
            directory.mkdir()
            for mode in (0o711, 0o1777):
                directory.chmod(mode)
                self.upload(directory)
                self.assertEqual(stat.S_IMODE(directory.stat().st_mode), mode)

    def test_missing_parent_is_created(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR")) as temporary:
            directory = pathlib.Path(temporary) / "new" / "nested"
            self.upload(directory)
            self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o755)

    def upload(self, parent):
        payload = b"binary\x00\xff\n'quoted'"
        target = parent / "uploaded ' file"
        command = eval(expression, {"shlex": shlex, "data": base64.b64encode(payload).decode(),
                                    "directory": shlex.quote(str(parent)), "destination": shlex.quote(str(target))})
        subprocess.run(["bash", "-c", command], check=True)
        self.assertEqual(target.read_bytes(), payload)


if __name__ == "__main__":
    unittest.main()
