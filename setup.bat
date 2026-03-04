@echo off
setlocal

:: Get the directory where this script is located
set "SCRIPT_DIR=%~dp0"
:: Path to QEMU (assuming qemu-system-x86_64.exe is inside a qemu subfolder)
set "QEMU_PATH=%SCRIPT_DIR%qemu\qemu-system-x86_64.exe"

:: Check if the QEMU executable exists
if not exist "%QEMU_PATH%" (
    echo Error: QEMU executable not found at %QEMU_PATH%
    pause
    exit /b 1
)

echo === Starting QEMU with configurable parameters ===
echo.

:: Prompt for RAM size in GB, default 8
set /p ram_gb="Enter RAM size in GB (default 8): "
if "%ram_gb%"=="" set ram_gb=8

:: Prompt for number of CPU cores, default 6
set /p cores="Enter number of CPU cores (default 6): "
if "%cores%"=="" set cores=6

:: Build the command
set "command=%QEMU_PATH% -machine type=pc,accel=whpx -cpu qemu64 -smp %cores% -m %ram_gb%G -hda virtual-disk.qcow2 -cdrom custom-kubuntu.iso -boot d"

echo.
echo Executing command:
echo %command%
echo.

:: Launch QEMU
%command%

echo.
echo QEMU execution finished.
pause