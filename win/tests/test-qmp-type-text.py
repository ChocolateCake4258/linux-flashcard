#!/usr/bin/env python3
"""Check keyboard packet generation without connecting to a VM."""
import contextlib
import io
import json
import pathlib
import runpy
import sys
import unittest
from unittest import mock

source = pathlib.Path(__file__).with_name("qmp-type-text.py")


class TypeTextTests(unittest.TestCase):
    def test_ascii_packets_and_selected_port(self):
        with mock.patch.object(sys, "argv", [str(source), "aZ9(+^/\n", "--port", "22722"]), \
                mock.patch("subprocess.run") as run, mock.patch("time.sleep"), \
                contextlib.redirect_stdout(io.StringIO()):
            runpy.run_path(str(source), run_name="__main__")
        expected = [["a"], ["shift", "z"], ["9"], ["shift", "9"],
                    ["shift", "equal"], ["shift", "6"], ["slash"], ["ret"]]
        self.assertEqual(run.call_count, len(expected))
        for call, keys in zip(run.call_args_list, expected):
            command = call.args[0]
            self.assertEqual(command[command.index("--port") + 1], "22722")
            packet = json.loads(command[command.index("--arguments") + 1])
            self.assertEqual([key["data"] for key in packet["keys"]], keys)
            self.assertEqual(packet["hold-time"], 50)
            self.assertTrue(call.kwargs["check"])

    def test_unsupported_text_fails_before_typing(self):
        with mock.patch.object(sys, "argv", [str(source), "a\u03c0"]), \
                mock.patch("subprocess.run") as run, contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as error:
                runpy.run_path(str(source), run_name="__main__")
        self.assertEqual(error.exception.code, 2)
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
