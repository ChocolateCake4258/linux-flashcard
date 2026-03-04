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

echo === Starting QEMU with physical disk passthrough ===
echo.

:: Prompt for RAM size in GB, default 4 (converted to MB: 4096)
set /p ram_gb="Enter RAM size in GB (default 4): "
if "%ram_gb%"=="" set ram_gb=4
set /a ram_mb=%ram_gb% * 1024

:: Prompt for number of CPU cores, default 4
set /p cores="Enter number of CPU cores (default 4): "
if "%cores%"=="" set cores=4

:: Prompt for physical drive number (e.g., 2 for \\.\PhysicalDrive2)
set /p drive_num="Enter physical drive number (e.g., 2): "
if "%drive_num%"=="" (
    echo Error: Drive number cannot be empty.
    pause
    exit /b 1
)

:: Build the command
set "command=%QEMU_PATH% -machine type=pc,accel=whpx -m %ram_mb% -smp %cores% -vga virtio -net nic,model=virtio -net user -usb -device usb-tablet -drive file=\\.\PhysicalDrive%drive_num%,format=raw,if=virtio"

echo.
echo Executing command:
echo %command%
echo.

:: Launch QEMU
%command%

echo.
echo QEMU execution finished.
pause