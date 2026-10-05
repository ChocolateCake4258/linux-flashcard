@echo off
rem write-image.bat - thin wrapper around write-image.ps1 (see its comments).
rem ENCODING RULE: keep this file pure ASCII with CRLF line endings.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0write-image.ps1" %*
if errorlevel 1 (
    echo.
    echo [ERROR] See the message above.
    pause
)
