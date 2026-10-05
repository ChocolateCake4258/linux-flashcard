@echo off
rem copy-and-run.bat - fallback mode for PCs where running programs from the
rem flash drive is blocked (AppLocker / Software Restriction Policies).
rem Copies portable QEMU from the flash drive to %LOCALAPPDATA%\qemu and runs
rem it from there. Policies usually allow execution from the user profile.
rem The image (qcow2/img) still stays on the flash drive, so persistence works.
rem
rem ENCODING RULE: this file must stay pure ASCII with CRLF line endings.
setlocal
set "SCRIPT_DIR=%~dp0"
set "LCL=%LOCALAPPDATA%\qemu"

rem --- image must be present next to win\ ---
if exist "%SCRIPT_DIR%..\virtual-disk.qcow2" goto :qemu_check
if exist "%SCRIPT_DIR%..\virtual-disk.img"   goto :qemu_check
echo [ERROR] No virtual-disk.qcow2/img found next to win\.
echo         Create it at home: setup.bat + convert-disk.bat.
pause
exit /b 1

:qemu_check
if exist "%LCL%\qemu-system-x86_64.exe" goto :run

rem --- copy QEMU into the user profile (first run only) ---
if not exist "%SCRIPT_DIR%..\qemu\qemu-system-x86_64.exe" (
    echo [ERROR] QEMU folder not found: %SCRIPT_DIR%..\qemu
    echo         Copy it there at home and retry.
    pause
    exit /b 1
)
echo [*] Copying QEMU from the flash drive to %LCL% (first run)...
robocopy "%SCRIPT_DIR%..\qemu" "%LCL%" /E /NFL /NDL /NJH /NJS /NP >nul
if errorlevel 8 (
    echo [ERROR] Failed to copy QEMU.
    pause
    exit /b 1
)

:run
echo [OK] QEMU: %LCL%\qemu-system-x86_64.exe  (image stays on the flash drive)
echo [*] Starting the virtual machine...
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%run-from-usb.ps1"
exit /b %errorlevel%
