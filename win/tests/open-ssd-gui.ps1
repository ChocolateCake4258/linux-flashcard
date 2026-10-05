# Open only the existing SSD GUI trial, never a physical USB disk.
$ErrorActionPreference = 'Stop'
$freeMb = [Math]::Floor((Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).FreePhysicalMemory / 1024)
if ($freeMb -lt 6144) { throw 'Need 4096 MB for this SSD VM plus 2048 MB free for Windows. Close other VMs/apps first.' }
& (Join-Path $PSScriptRoot 'diagnostic-vm.ps1') -Action Boot `
    -WorkspaceDirectory 'E:\linux-flashcard-v2\diagnostics\ssd-apps-20261003' `
    -SourceImage 'E:\linux-flashcard-v2\diagnostics\usb-current-20261003.img' `
    -RamMb 4096 -Cores 2 -Display Default -Accel WHPX -CpuModel Westmere -Wait
