@echo off
rem setup.bat - thin wrapper around setup.ps1 (see its comments).
rem ENCODING RULE: keep this file pure ASCII with CRLF line endings.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %*
if errorlevel 1 (
    echo.
    echo [ERROR] See the message above.
    pause
)
