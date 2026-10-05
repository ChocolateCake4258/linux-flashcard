# start-system.ps1 — запуск системы с ФИЗИЧЕСКОЙ флешки (прямой доступ к диску).
# Требует прав администратора и синтаксиса физического номера диска.
# Это "режим 3" — используйте run-from-usb.bat, если прав нет.

param(
    [int]$RamMb = 0,
    [int]$Cores = 0,
    [int]$DriveNumber = -1   # \\.\PhysicalDriveN
)
# Русский вывод в консоли: принудительно UTF-8. Иначе Windows PowerShell 5.1
# печатает кириллицу в текущей кодовой странице как «кракозябры».
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8; $OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\lib\pf-tools.psm1"

$qemu = Find-PfQemu -ScriptDir $PSScriptRoot
if (-not $qemu) { throw 'QEMU не найден. Скопируйте папку qemu рядом с win/.' }

if (-not (Test-PfIsAdmin)) {
    throw 'Доступ к физическому диску требует прав администратора. Рекомендую run-from-usb.bat (без прав).'
}

if ($DriveNumber -lt 0) {
    Write-Host 'Список физических дисков:'
    Get-CimInstance Win32_DiskDrive | ForEach-Object {
        Write-Host ("  Disk {0}: {1}  {2} ГБ" -f $_.Index, $_.Model, [Math]::Round($_.Size/1GB,1))
    }
    $DriveNumber = Read-Host 'Введите номер флешки (2 -> \\.\PhysicalDrive2)'
    $DriveNumber = [int]$DriveNumber
}
$drive = "\\.\PhysicalDrive$DriveNumber"
Write-Host "Запуск с $drive ..." -ForegroundColor Cyan

if ($RamMb -eq 0) { $RamMb = (Get-PfRecommendedRamGb) * 1024 }
if ($Cores -eq 0) { $c = Get-PfCores; $Cores = [Math]::Max(1, [Math]::Floor($c/2)) }

$qemuArgs = Get-PfQemuBaseArgs -RamMb $RamMb -Cores $Cores -Uefi
$qemuArgs += @('-drive', "file=$drive,format=raw,if=virtio")
& $qemu $qemuArgs
Write-Host 'QEMU остановлен.'
Read-Host 'Enter'