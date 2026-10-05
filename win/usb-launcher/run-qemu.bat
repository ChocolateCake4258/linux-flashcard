@echo off
rem run-qemu.bat - start the flash drive system (volume P2) inside QEMU.
rem The flash has two volumes: P1 = QEMU + launcher, P2 = the only system.
rem QEMU opens the whole physical flash drive, so administrator rights are
rem required (UAC is requested automatically).
rem
rem ENCODING RULE: this file must stay pure ASCII with CRLF line endings.
rem Do not keep this USB batch file or its working directory open while locking.
set "PF_LAUNCHER=%~dp0run-qemu.ps1"
cd /d "%SystemRoot%"
start "USB QEMU launcher" /D "%SystemRoot%" powershell -NoProfile -ExecutionPolicy Bypass -File "%PF_LAUNCHER%" %*
exit /b
