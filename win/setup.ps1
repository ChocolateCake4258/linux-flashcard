# setup.ps1 — интерактивная установка Kubuntu из кастомного ISO в QEMU.
# 1) Ищет custom-kubuntu.iso рядом с win\.. (или переданный путь)
# 2) Показывает параметры по умолчанию (можно переопределить параметрами)
# 3) Открывает окно QEMU; установку делать вручную в графическом интерфейсе.
# После установки: convert-disk.bat -> затем write-image.bat (запись на флешку).

param(
    [string]$IsoPath = '',
    [string]$DiskPath = '',
    [int]$RamGb = 0,          # 0 = авто
    [int]$Cores = 0,          # 0 = авто
    [switch]$NoUefi,
    [switch]$Gui
)
# Русский вывод в консоли: принудительно UTF-8. Иначе Windows PowerShell 5.1
# печатает кириллицу в текущей кодовой странице как «кракозябры».
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8; $OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\lib\pf-tools.psm1"

$ScriptDir = $PSScriptRoot
$RepoRoot  = Split-Path $ScriptDir -Parent

$qemu = Find-PfQemu -ScriptDir $ScriptDir
if (-not $qemu) { throw 'QEMU не найден. Скопируйте папку qemu рядом с win/. Скачать: https://qemu.weilnetz.de/w64/' }
if (-not $IsoPath) { $IsoPath = Join-Path $RepoRoot 'custom-kubuntu.iso' }
if (-not $DiskPath) { $DiskPath = Join-Path $RepoRoot 'virtual-disk.qcow2' }
if (-not (Test-Path $IsoPath))  { throw "ISO не найден: $IsoPath`nСначала соберите его: make iso (см. README)." }
if (-not (Test-Path $DiskPath)) {
    Write-Host "[!] Диск не найден: $DiskPath. Создаём 25G." -ForegroundColor Yellow
    $qemuImg = Find-PfQemuImg -QemuExe $qemu
    if (-not $qemuImg) { throw 'qemu-img.exe не найден.' }
    & $qemuImg create -f qcow2 $DiskPath 25G
}

if ($RamGb -eq 0)  { $RamGb  = Get-PfRecommendedRamGb }
if ($Cores -eq 0)  { $cores  = Get-PfCores; $Cores = [Math]::Max(1, [Math]::Floor($cores/2)) }

Write-PfHeader 'Установка Kubuntu в QEMU'
Write-Host "  ISO  : $IsoPath"
Write-Host "  Disk : $DiskPath"
Write-Host "  RAM  : ${RamGb} ГБ, CPU ядер: $Cores"
if (-not $NoUefi) { Write-Host '  UEFI : авто (при наличии OVMF)' }
Write-Host ''
Write-Host 'В открывшемся окне выполните установку Kubuntu вручную' -ForegroundColor Yellow
Write-Host '(язык, диск — весь виртуальный диск, пользователь student).' -ForegroundColor Yellow
Write-Host 'После перезагрузки системы окно закроется — запустите convert-disk.bat' -ForegroundColor Yellow
Write-Host ''
Read-Host 'Готово? Нажмите Enter для запуска QEMU (Ctrl+)'

$qemuArgs = Get-PfQemuBaseArgs -RamMb ($RamGb*1024) -Cores $Cores -Uefi:(-not $NoUefi)
$qemuArgs += @('-drive', "file=$DiskPath,media=disk,if=virtio")
$qemuArgs += @('-drive', "file=$IsoPath,media=cdrom,read-only=on")
$qemuArgs += @('-boot', 'order=d,once=d')

if ($Gui) {
    # Нормализация только для Start-Process: оператор & ниже сам раздаёт
    # элементы массива по argv, и лишние кавычки там стали бы частью пути.
    $startArgs = ConvertTo-PfArgumentList -Arguments $qemuArgs -What 'QEMU (ручная установка)'
    Start-Process $qemu -ArgumentList $startArgs
} else {
    & $qemu $qemuArgs
}

if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host '[i] Если установка была медленной/зависла — проверьте ускорение.' -ForegroundColor Yellow
    Write-Host '    WHPX требует включённую виртуализацию Windows; без неё QEMU переключится на TCG (медленно).' -ForegroundColor Yellow
}