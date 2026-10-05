@echo off
rem convert-disk.bat - thin wrapper around convert-disk.ps1 (see its comments).
rem ENCODING RULE: keep this file pure ASCII with CRLF line endings.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0convert-disk.ps1" %*
if errorlevel 1 (
    echo.
    echo [ERROR] See the message above.
    pause
)
