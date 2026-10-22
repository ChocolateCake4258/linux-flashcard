@echo off
rem Debian/XFCE: select USB, build/resume, write, verify.
rem ENCODING: ASCII/CRLF; Russian text belongs in the PowerShell script.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-all.ps1" %*
exit /b %errorlevel%
