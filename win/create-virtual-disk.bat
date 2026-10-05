@echo off
rem create-virtual-disk.bat - thin wrapper around create-virtual-disk.ps1
rem (see its comments).
rem ENCODING RULE: keep this file pure ASCII with CRLF line endings.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0create-virtual-disk.ps1" %*
if errorlevel 1 (
    echo.
    echo [ERROR] See the message above.
    pause
)
