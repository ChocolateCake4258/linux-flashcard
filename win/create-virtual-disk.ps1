# create-virtual-disk.ps1 — создание виртуального диска (qcow2) под установку.

param(
    [int]$SizeGb = 25,
    [string]$DiskPath = ''   # по умолчанию: win\..\virtual-disk.qcow2
)
# Русский вывод в консоли: принудительно UTF-8. Иначе Windows PowerShell 5.1
# печатает кириллицу в текущей кодовой странице как «кракозябры».
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8; $OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\lib\pf-tools.psm1"

$ScriptDir = $PSScriptRoot
if (-not $DiskPath) { $DiskPath = Join-Path (Split-Path $ScriptDir -Parent) 'virtual-disk.qcow2' }

$qemuImg = Find-PfQemuImg -QemuExe (Find-PfQemu -ScriptDir $ScriptDir)
if (-not $qemuImg) { throw 'qemu-img.exe не найден. Скопируйте папку qemu рядом с папкой win/.' }
if (Test-Path $DiskPath) {
    Write-Host "[!] Диск уже существует: $DiskPath" -ForegroundColor Yellow
    Write-Host "    Используйте convert-disk после установки. Но если он повреждён — удалите файл вручную."
    if ($null -eq $SizeGb) { }
    exit 0
}

# проверка места на целевом диске
$drv = (Get-Item $DiskPath).PSDrive
$free = (Get-PSDrive $drv.Name).Free / 1GB
Write-Host "[i] Свободно на диске: $([Math]::Round($free,1)) ГБ, нужен диск ${SizeGb} ГБ."
if ($free -lt $SizeGb) { throw "Недостаточно места: нужно ${SizeGb} ГБ." }

Write-Host "[3/7] Создание диска: $DiskPath (${SizeGb}G)..."
& $qemuImg create -f qcow2 $DiskPath "${SizeGb}G"
if ($LASTEXITCODE -ne 0) { throw 'Не удалось создать виртуальный диск.' }
Write-Host '[OK] Виртуальный диск создан. Далее: setup.bat (установка из ISO).' -ForegroundColor Green