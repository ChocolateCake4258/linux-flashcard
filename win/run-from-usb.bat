@echo off
rem run-from-usb.bat - thin wrapper around run-from-usb.ps1 (see its comments).
rem File mode: boots the system from a qcow2/raw image file (no admin rights).
rem ENCODING RULE: keep this file pure ASCII with CRLF line endings.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-from-usb.ps1" %*
if errorlevel 1 (
    echo.
    echo [ERROR] See the message above.
    pause
)
