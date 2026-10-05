@echo off
rem build-all.bat - Method B: fully automatic build of the "two volumes, one system"
rem flash drive on a Windows PC. Stages 0-9 are documented in build-all.ps1.
rem
rem ENCODING RULE: this file must stay pure ASCII with CRLF line endings.
rem cmd.exe mis-parses UTF-8 / LF-only batch files (comments get executed).
rem All Russian text lives in the .ps1 scripts (UTF-8 with BOM).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-all.ps1" %*
if errorlevel 1 (
    echo.
    echo [ERROR] See the message above.
    pause
)
