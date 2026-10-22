@echo off
rem Persistent file mode: QCOW2, explicit TCG and UEFI, no elevation.
rem ENCODING RULE: ASCII with CRLF line endings.
setlocal DisableDelayedExpansion
set "PF_FILE_FROM_BAT=1"
set "PF_FILE_NO_PAUSE="
for %%A in (%*) do if /i "%%~A"=="-NoPause" set "PF_FILE_NO_PAUSE=1"
set "PF_FILE_BOOT_LOG=%TEMP%\pf-file-bootstrap-%RANDOM%-%RANDOM%.log"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-from-usb.ps1" %*
set "PF_FILE_EXIT=%ERRORLEVEL%"
if not "%PF_FILE_EXIT%"=="0" (
    echo [ERROR] File launcher exited with code %PF_FILE_EXIT%.
    echo [ERROR] File launcher exited with code %PF_FILE_EXIT%. >> "%PF_FILE_BOOT_LOG%"
    echo Script: "%~dp0run-from-usb.ps1" >> "%PF_FILE_BOOT_LOG%"
    echo Bootstrap result: "%PF_FILE_BOOT_LOG%"
    if not defined PF_FILE_NO_PAUSE pause
)
exit /b %PF_FILE_EXIT%
