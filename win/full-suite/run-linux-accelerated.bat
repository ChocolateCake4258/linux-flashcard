@echo off
setlocal DisableDelayedExpansion
call "%~dp0run-from-usb.bat" -DiskPath "%~dp0linux.img.vtoy" -DiskFormat raw -RtcBase localtime -Accel WHPX -QemuExe "%~dp0qemu\qemu-system-x86_64.exe" %*
exit /b %ERRORLEVEL%
