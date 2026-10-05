# run-from-usb.ps1 — ГЛАВНЫЙ РЕЖИМ ДЛЯ УЧЕБНЫХ ПК.
# Запуск Kubuntu с флешки в QEMU ИЗ ФАЙЛА:
#   - НЕ требует прав администратора;
#   - НЕ требует включённой виртуализации Windows (WHXP/Hyper-V) —
#     при её отсутствии QEMU автоматически перейдёт на TCG (медленнее, но работает);
#   - НЕ требует доступа к меню загрузки BIOS/UEFI (Secure Boot не мешает).
# Изменения системы сохраняются в файле-образе (персистентность на флешке).

param(
    [string]$DiskPath = '',   # по умолчанию: virtual-disk.qcow2 или virtual-disk.img рядом с win/
    [switch]$Snapshot,        # не сохранять изменения после остановки (для тестов)
    [int]$RamMb = 0,          # 0 = авто
    [int]$Cores = 0           # 0 = авто
)
# Русский вывод в консоли: принудительно UTF-8. Иначе Windows PowerShell 5.1
# печатает кириллицу в текущей кодовой странице как «кракозябры».
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8; $OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\lib\pf-tools.psm1"

$RepoRoot = Split-Path $PSScriptRoot -Parent
if (-not $DiskPath) {
    foreach ($name in @('virtual-disk.qcow2', 'virtual-disk.img')) {
        $cand = Join-Path $RepoRoot $name
        if (Test-Path $cand) { $DiskPath = $cand; break }
    }
}
if (-not $DiskPath) { throw "Образ не найден рядом с win/. Укажите: -run-from-usb.bat -DiskPath C:\путь\virtual-disk.qcow2" }
if (-not (Test-Path $DiskPath)) { throw "Образ не найден: $DiskPath" }

$qemu = Find-PfQemu -ScriptDir $PSScriptRoot
if (-not $qemu) {
    Write-Host '[!] QEMU не найден ни на флешке, ни в системе.' -ForegroundColor Yellow
    Write-Host '    Варианты:' -ForegroundColor Yellow
    Write-Host '     1) положить папку qemu рядом с win/ (дома, до учебного ПК);' -ForegroundColor Yellow
    Write-Host '     2) использовать copy-and-run.bat (скопирует с флешки в AppData).' -ForegroundColor Yellow
    Read-Host 'Enter'
    exit 1
}

if ($RamMb -eq 0) { $RamGb = Get-PfRecommendedRamGb; $RamMb = $RamGb * 1024 }
if ($Cores -eq 0) { $c = Get-PfCores; $Cores = [Math]::Max(1, [Math]::Floor($c/2)) }

Write-PfHeader 'Запуск Kubuntu с флешки (режим учебного ПК)'
Write-Host "  QEMU  : $qemu"
Write-Host "  Образ : $DiskPath"
Write-Host "  RAM   : ${RamMb} МБ, ядер: $Cores"
if ($Snapshot) { Write-Host '  Режим : SNAPSHOT (изменения не сохранятся после выхода).' -ForegroundColor Yellow }
Write-Host ''
Write-Host 'Инструкция:' -ForegroundColor Cyan
Write-Host '  - При медленной работе (нет аппаратной виртуализации) QEMU использует эмуляцию TCG.' -ForegroundColor Cyan
Write-Host '  - Пароль пользователя student можно сменить внутри системы: passwd' -ForegroundColor Cyan
Write-Host '  - Закрыть ВМ: завершить сеанс в KDE (выключить систему).' -ForegroundColor Cyan
Write-Host ''
Read-Host 'Enter — запуск...'

$qemuArgs = Get-PfQemuBaseArgs -RamMb $RamMb -Cores $Cores -Uefi
$fmt = [System.IO.Path]::GetExtension($DiskPath).ToLower()
switch ($fmt) {
    '.qcow2' { $drive = "file=$DiskPath,format=qcow2,media=disk,if=virtio" }
    '.img'   { $drive = "file=$DiskPath,format=raw,media=disk,if=virtio" }
    default  { $drive = "file=$DiskPath,media=disk,if=virtio" }   # автоопределение
}
$qemuArgs += @('-drive', $drive)
if ($Snapshot) { $qemuArgs += @('-snapshot') }

& $qemu $qemuArgs
Write-Host ''
Write-Host 'QEMU остановлен. Данные сохранены в образ.' -ForegroundColor Green
Read-Host 'Enter'