@echo off
rem start-system.bat - thin wrapper around start-system.ps1 (see its comments).
rem ENCODING RULE: keep this file pure ASCII with CRLF line endings.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-system.ps1" %*
if errorlevel 1 (
    echo.
    echo [ERROR] See the message above.
    pause
)
