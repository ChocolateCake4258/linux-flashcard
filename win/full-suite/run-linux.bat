@echo off
setlocal DisableDelayedExpansion
call "%~dp0run-from-usb.bat" -DiskPath "%~dp0linux.img.vtoy" -DiskFormat raw -RtcBase localtime -QemuExe "%~dp0qemu\qemu-system-x86_64.exe" -RamMb 4096 -Cores 2 %*
exit /b %ERRORLEVEL%
