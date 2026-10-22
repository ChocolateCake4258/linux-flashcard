from pathlib import Path

message = "Python: 42\nПривет, LinuxFlashcard!\n"
print(message, end="")
Path("result.txt").write_text(message, encoding="utf-8")
