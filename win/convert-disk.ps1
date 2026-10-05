# convert-disk.ps1 — конвертация установленного qcow2 в RAW-образ для записи на флешку.
# Делается ДОМА (требует места на диске); результат ~= размер виртуального диска.

param(
    [string]$QcowPath = '',
    [string]$RawPath = '',
    [int]$FlashGb = 32       # ожидаемый объём целевой флешки — для предупреждения
)
# Русский вывод в консоли: принудительно UTF-8. Иначе Windows PowerShell 5.1
# печатает кириллицу в текущей кодовой странице как «кракозябры».
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8; $OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\lib\pf-tools.psm1"

$RepoRoot = Split-Path $PSScriptRoot -Parent
if (-not $QcowPath) { $QcowPath = Join-Path $RepoRoot 'virtual-disk.qcow2' }
if (-not $RawPath)  { $RawPath  = Join-Path $RepoRoot 'virtual-disk.img' }

$qemuImg = Find-PfQemuImg -QemuExe (Find-PfQemu -ScriptDir $PSScriptRoot)
if (-not $qemuImg) { throw 'qemu-img.exe не найден. Скопируйте папку qemu рядом с win/.' }
if (-not (Test-Path $QcowPath)) { throw "Не найден виртуальный диск: $QcowPath`nСначала выполните setup.bat (установка)." }

$rawSize = (Get-Item $QcowPath).Length  # для sparse/raw это верхняя граница
Write-PfHeader 'Конвертация qcow2 -> RAW'
Write-Host "  $QcowPath  ->  $RawPath"
Write-Host "  Итоговый размер raw будет соответствовать размеру диска ВМ." -ForegroundColor Yellow
if ($FlashGb -gt 0) {
    Write-Host "  Целевая флешка: ${FlashGb} ГБ." -ForegroundColor Yellow
    Write-Host '  Помните: RAW занимает ВЕСЬ раздел — на 32 ГБ флешку помещайте диск <= 28 ГБ.' -ForegroundColor Yellow
}

if (Test-Path $RawPath) {
    Write-Host "[!] $RawPath уже существует. Перезаписать? (это долго)" -ForegroundColor Yellow
    $ans = Read-Host 'y/N'
    if ($ans -notin @('y','Y')) { exit 0 }
    Remove-Item $RawPath
}

$free = (Get-Item (Split-Path $RawPath -Parent)).PSDrive.Free / 1GB
if ($free -lt 30) { Write-Host "[!] Мало свободного места — конвертация может провалиться." -ForegroundColor Yellow }

& $qemuImg convert -p -f qcow2 -O raw $QcowPath $RawPath
if ($LASTEXITCODE -ne 0) { throw 'Конвертация не удалась.' }

# контрольная сумма
Get-FileHash $RawPath -Algorithm SHA256 | ForEach-Object {
    Set-Content (Join-Path $RepoRoot 'virtual-disk.img.sha256') $_.Hash
}
Write-Host ''
Write-Host '[OK] RAW-образ готов: ' -ForegroundColor Green -NoNewline
Write-Host $RawPath -ForegroundColor Green
Write-Host 'Далее: write-image.bat (запись на флешку, нужны права администратора).' -ForegroundColor Cyan