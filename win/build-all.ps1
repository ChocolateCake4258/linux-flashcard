# build-all.ps1 — способ B: полностью автоматическая сборка флешки «два тома,
# одна система» на Windows-ПК одной командой.
#
#   win\build-all.bat          # весь конвейер (стадии 0-9)
#   win\build-all.bat -FromStage 5        # продолжить с установки
#   win\build-all.bat -Force -FromStage 5 # переустановить с нуля диска
#   win\build-all.bat -ShowWindow         # показывать окно QEMU при установке
#   win\build-all.bat -QemuExe C:\PF-QEMU\qemu-system-x86_64.exe   # QEMU лежит не в проекте
#
# Стадии:
#   0 preflight   — место/интернет/PowerShell, план
#   1 qemu        — portable QEMU (тихая установка при отсутствии)
#   2 iso         — live-server ISO (докачка curl -C -, проверка SHA256)
#   3 vdisk       — virtual-disk.qcow2 (28G)
#   4 seed        — seed.iso из win\autoinstall.yaml
#   5 autoinstall — неинтерактивная установка Kubuntu в QEMU (отключится сам)
#   6 smoke       — короткая пробная загрузка установленного образа
#   7 convert     — qcow2 -> raw (виртуальный диск для записи на USB)
#   8 write       — запись raw на флешку (УЧАСТНИК UAC при необходимости)
#   9 payload     — копия QEMU, кнопки и доки на том P1 (FLASHCARD)
#
# Логи сборки (в корне проекта):
#   build.log        — весь вывод этого запуска (Start-Transcript)
#   install.log      — что происходит внутри ВМ во время автоустановки
#   install-qemu.log — stdout/stderr самого QEMU (какой ускоритель, ошибки)
#   smoke-boot.log   — пробная загрузка установленной системы
#
# Итог: флешка с GPT; на ней ОДНА система (ext4 «/») и том P1 (FAT32) с QEMU.
# После сборки остаются артефакты virtual-disk.qcow2 / virtual-disk.img для
# клонирования флешки на другой USB без повторной установки.

param(
    [ValidateRange(0, 9)]
    [int]$FromStage = 0,
    [switch]$Force,          # пересоздавать артефакты стадий (диск/ISO/raw)
    [switch]$ShowWindow,     # показывать окно QEMU во время установки
    [switch]$NoSmoke,        # пропустить стадию 6 (пробную загрузку)
    [switch]$Eject,          # после стадии 9 безопасно отключить том P1
    [string]$IsoSha = '',    # явная SHA256 ISO (иначе брать из SHA256SUMS)
    [string]$QemuUrl = '',   # явный URL установщика QEMU (иначе ищем актуальный сами)
    [string]$QemuExe = '',  # явный путь к qemu-system-x86_64.exe (важно, если папка qemu\ стёрта)
    [string]$FlashLabel = 'FLASHCARD',
    [int]$InstallTimeoutMin = 120,  # предел ожидания автоустановки, мин
    [int]$QmpPort = 0        # порт QMP для отслеживания ВМ (0 = выбрать свободный)
)
# Русский вывод в консоли: принудительно UTF-8. Иначе Windows PowerShell 5.1
# печатает кириллицу в текущей кодовой странице как «кракозябры».
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8; $OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\lib\pf-tools.psm1"

$ScriptDir = $PSScriptRoot
$RepoRoot  = Split-Path $ScriptDir -Parent

# ------------------------- константы (зеркало autoinstall.yaml) -------------
$QemuDir           = Join-Path $RepoRoot 'qemu'
$IsoName           = 'ubuntu-26.04-live-server-amd64.iso'
$IsoUrl            = "https://releases.ubuntu.com/26.04/$IsoName"
$ShaUrl            = 'https://releases.ubuntu.com/26.04/SHA256SUMS'
$DiskSizeGb        = 28      # размер виртуального диска ВМ (и raw)
$EspGb             = 2       # размер тома P1 (должен совпадать с autoinstall.yaml)
$VdiskPath         = Join-Path $RepoRoot 'virtual-disk.qcow2'
$RawPath           = Join-Path $RepoRoot 'virtual-disk.img'
$IsoPath           = Join-Path $RepoRoot $IsoName
$SeedDir           = Join-Path $RepoRoot 'seed-src'
$SeedIso           = Join-Path $RepoRoot 'seed.iso'
$QemuInstaller     = Join-Path $RepoRoot 'qemu-installer.exe'
$InstallDoneMarker = Join-Path $RepoRoot '.autoinstall-done'
$UsbLauncher       = Join-Path $ScriptDir 'usb-launcher'
$AutoinstallYaml   = Join-Path $ScriptDir 'autoinstall.yaml'
$PwshPath          = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$BootCacheDir      = Join-Path $RepoRoot '.cache\boot'
$BuildLog          = Join-Path $RepoRoot 'build.log'
$InstallLog        = Join-Path $RepoRoot 'install.log'
$QemuStdLog        = Join-Path $RepoRoot 'install-qemu.log'
$QemuErrLog        = Join-Path $RepoRoot 'install-qemu.err.log'
$WriteImageLog     = Join-Path $RepoRoot 'write-image.log'
# Версия модуля, с которой этот build-all.ps1 рассчитан. Проверяется при КАЖДОМ
# запуске, а не только в стадии 0: иначе при -FromStage 5/8 устаревший модуль
# на диске остался бы незамеченным (именно так выпала запись на стадии 8).
$ExpectedModuleVersion = '2026-10-01.16'

# ---------------------------------------------------------------------------
function Step {
    param([int]$N, [string]$Title)
    Write-PfHeader "Стадия $N/$StepCount :: $Title"
}
function Have {
    param([string]$Path)
    return (Test-Path $Path)
}
function Ask-Disk {
    param($Disks)
    for ($i = 0; $i -lt $Disks.Count; $i++) {
        $d = $Disks[$i]
        Write-Host ("  [{0}] Disk {1}: {2}  {3:N1} ГБ" -f $i, $d.Index, $d.Model, ($d.Size / 1GB))
    }
    $sel = Read-Host 'Введите номер [0..]'
    $sel = [int]$sel
    if ($sel -lt 0 -or $sel -ge $Disks.Count) { throw 'Неверный выбор' }
    return $Disks[$sel]
}
# Аккуратно закрыть build.log (файл может не допечатать последнюю строку).
# Объявлено ДО trap: иначе при ранней ошибке вызов Stop-Log внутри trap не
# найдёт функцию, и настоящая причина сбоя потеряется.
function Stop-Log {
    if ($script:TranscriptOn) {
        try { Stop-Transcript | Out-Null } catch { }
        $script:TranscriptOn = $false
    }
}

# Любая необработанная ошибка: показать, где упало, и закрыть build.log.
# Внутри только встроенные командлеты и полная защита try/catch — trap не имеет
# права упасть сам, иначе он затрёт исходное сообщение об ошибке.
trap {
    $msg  = 'неизвестная ошибка'
    $info = ''
    try { if ($_.Exception -and $_.Exception.Message) { $msg = $_.Exception.Message } } catch { }
    try {
        if ($_.InvocationInfo) {
            $ln = ''
            if ($_.InvocationInfo.Line) { $ln = $_.InvocationInfo.Line.Trim() }
            $info = "строка $($_.InvocationInfo.ScriptLineNumber): $ln"
        }
    } catch { }
    # Сначала печатаем (чтобы ошибка попала в build.log), потом закрываем log.
    try {
        Write-Host ''
        Write-Host "[ОШИБКА] $msg" -ForegroundColor Red
        if ($info) { Write-Host "  $info" -ForegroundColor DarkRed }
        Write-Host "  Подробности запуска: $BuildLog" -ForegroundColor DarkGray
    } catch { }
    try { if (Get-TranscriptInformation -ErrorAction SilentlyContinue) { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } } catch { }
    $script:TranscriptOn = $false
    exit 1
}

$StepCount = 9

# Полный лог этого запуска: иначе при закрытии окна cmd всё исчезает.
$TranscriptOn = $false
try {
    Start-Transcript -Path $BuildLog -Force | Out-Null
    $TranscriptOn = $true
} catch {
    Write-Host "  [i] Не смог включить build.log: $($_.Exception.Message)" -ForegroundColor Yellow
}

# Версия модуля видна при любом запуске, включая -FromStage 5/8.
$mv = try { Get-PfToolsVersion } catch { 'НЕТ ФУНКЦИИ Get-PfToolsVersion' }
if ($mv -eq $ExpectedModuleVersion) {
    Write-Host "  Модуль       : $mv" -ForegroundColor DarkGray
} else {
    Write-Host "  Модуль       : $mv  (ожидался $ExpectedModuleVersion)" -ForegroundColor Red
    Write-Host '      win\ устарел. Скопируйте папку заново и повторите:' -ForegroundColor Yellow
    Write-Host '        robocopy /MIR win <куда>\win' -ForegroundColor Yellow
    Write-Host '      Прервать сборку (Y), продолжить как есть (N)?' -ForegroundColor Yellow
    $ans = (Read-Host 'Y/N').Trim()
    if ($ans -notmatch '^[Nn]' -and $ans -ne '') { throw "Модуль устарел ($mv вместо $ExpectedModuleVersion). Скопируйте win\ заново." }
    Write-Host '  [!] Продолжаю с устаревшим модулем — сбои в стадиях 1/8 вероятны.' -ForegroundColor Yellow
}

# ===================== 0. ПРЕДПРОВЕРКА =====================================
if ($FromStage -le 0) {
    Step 0 'Предварительная проверка'
    Write-Host "  Диск ВМ      : $DiskSizeGb ГБ + том P1 ($EspGb ГБ, esp+данные)"
    Write-Host "  Репозиторий  : $RepoRoot"
    if ($PSVersionTable.PSVersion.Major -lt 5) { throw 'Нужен PowerShell 5.1+' }
    if ($TranscriptOn) { Write-Host "  Лог сборки   : $BuildLog" -ForegroundColor DarkGray }

    $free = (Get-Item $RepoRoot).PSDrive.Free / 1GB
    Write-Host "  Свободно на разделе: $([Math]::Round($free,1)) ГБ (рекомендуется 35+)" -ForegroundColor Yellow
    if ($free -lt 35) { throw 'Недостаточно места (нужно ~35 ГБ: ISO + qcow2 + raw).' }

    try {
        $ping = Test-Connection releases.ubuntu.com -Count 1 -Quiet -ErrorAction Stop
        if (-not $ping) { Write-Host '  [i] Сеть не отвечает — продолжу, но загрузка, вероятно, не удастся.' -ForegroundColor Yellow }
    } catch { Write-Host '  [i] Не могу проверить доступность сети (продолжаю).' -ForegroundColor Yellow }

    $qemu = Find-PfQemu -ScriptDir $ScriptDir -Exe $QemuExe
    if ($qemu)  { Write-Host "  QEMU  : найден ($qemu)" -ForegroundColor Green }
    else        { Write-Host '  QEMU  : не найден — будет загружен на стадии 1' -ForegroundColor Yellow }
    if (Test-PfIsAdmin) {
        Write-Host '  Права  : администратор (UAC спрашиваться не будет)' -ForegroundColor Green
    } else {
        Write-Host '  Права  : обычные — на стадиях 1 и 8 Windows спросит подтверждение (UAC)' -ForegroundColor Yellow
        Write-Host '          в окне UAC нажмите «Да»; окно «Windows защитит ваш компьютер» -> «Подробнее» -> «Выполнить в любом случае»' -ForegroundColor DarkGray
    }
    if (Have $IsoPath) { Write-Host "  ISO   : $IsoName (уже есть)" -ForegroundColor Green }
    else               { Write-Host "  ISO   : $IsoName — будет загружен (≈2.6 ГБ), проверка SHA256" -ForegroundColor Yellow }
    Write-Host ''
}

# ===================== 1. QEMU ==============================================
if ($FromStage -le 1) {
    Step 1 'Обеспечение portable QEMU'
    $qemu = Find-PfQemu -ScriptDir $ScriptDir -Exe $QemuExe
    if ($qemu) {
        Write-Host "  [OK] QEMU готов: $qemu" -ForegroundColor Green
    } else {
        Write-Host '  QEMU не найден: проверяю установщик в корне проекта...'
        Write-Host '  [!] Если QEMU уже установлен — верните папку qemu\ в корень проекта' -ForegroundColor Yellow
        Write-Host '      (или укажите путь: build-all.bat -QemuExe C:\...\qemu-system-x86_64.exe).' -ForegroundColor Yellow

        # Откуда установщик: задан вручную или последняя сборка в каталоге weilnetz.
        $qemuUrl = $QemuUrl
        if ($qemuUrl) {
            Write-Host "  Адрес установщика задан вручную: $qemuUrl"
        } else {
            try {
                $info = Get-PfQemuInstallerUrl
                $qemuUrl = $info.Url
                Write-Host "  Актуальная сборка QEMU: $($info.FileName)" -ForegroundColor Green
            } catch {
                Write-Host "  [i] Каталог weilnetz недоступен: $(($_.Exception.Message -split [char]10)[0])" -ForegroundColor Yellow
            }
        }

        # Опубликованная сумма (пусто, если сервер её не отдаёт).
        $sha512 = ''
        if ($qemuUrl) {
            $sha512 = Get-PfRemoteSha512 -Url ($qemuUrl -replace '\.exe$', '.sha512')
            if ($sha512) {
                Write-Host "  SHA-512 с сервера: $($sha512.Substring(0,16))..." -ForegroundColor DarkGray
            } else {
                Write-Host '  [i] SHA-512 с сервера недоступна — сверять будет нечем.' -ForegroundColor Yellow
            }
        }

        # Что делать с уже скачанным файлом: доверяем, только если сходится сумма
        # (иначе — по размеру: установщик QEMU весит примерно 190-200 МБ).
        $needDownload = $true
        if (Have $QemuInstaller) {
            $size = (Get-Item $QemuInstaller).Length
            $mb   = [Math]::Round($size / 1MB, 1)
            if ($sha512) {
                $h = (Get-FileHash $QemuInstaller -Algorithm SHA512).Hash
                if ($h -eq $sha512) {
                    Write-Host "  [OK] Уже скачанный установщик сходится с SHA-512 ($mb МБ) — загрузка не нужна." -ForegroundColor Green
                    $needDownload = $false
                } else {
                    Remove-Item $QemuInstaller -Force
                    Write-Host "  [!] Установщик ($mb МБ) не совпадает с суммой сервера — удаляю, скачаю заново." -ForegroundColor Yellow
                }
            } elseif ($size -lt 150MB) {
                Remove-Item $QemuInstaller -Force
                Write-Host "  [!] Файл похож на оборванную загрузку ($mb МБ) — удаляю." -ForegroundColor Yellow
            } else {
                Write-Host "  [OK] Установщик уже скачан ($mb МБ). Сумма с сервера недоступна, сверил по размеру." -ForegroundColor Green
                $needDownload = $false
            }
        }
        if ($needDownload) {
            if (-not $qemuUrl) {
                throw ("Не удалось определить адрес установщика QEMU (сеть или прокси недоступны)" +
                       "`nВариант 1 (быстро): верните в корень проекта папку qemu\ с QEMU" +
                       "`n  или запустите с путём: build-all.bat -QemuExe C:\...\qemu-system-x86_64.exe" +
                       "`nВариант 2: скачайте qemu-w64-setup-*.exe с https://qemu.weilnetz.de/w64/," +
                       "`n  переименуйте в qemu-installer.exe и положите рядом с папкой win\")
            }
            Resume-PfDownload -Url $qemuUrl -OutFile $QemuInstaller -ExpectedSha512 $sha512
        }
        if (-not (Have $QemuInstaller)) {
            throw ("Установщик QEMU не найден: $QemuInstaller" +
                   "`nВариант 1 (быстро): верните в корень проекта папку qemu\ с QEMU" +
                   "`n  или запустите с путём: build-all.bat -QemuExe C:\...\qemu-system-x86_64.exe" +
                   "`nВариант 2: скачайте qemu-w64-setup-*.exe с https://qemu.weilnetz.de/w64/," +
                   "`n  переименуйте в qemu-installer.exe и положите рядом с папкой win\")
        }
        if ($QemuDir -match '\s') {
            Write-Host ("  [!] В пути к проекту есть пробелы: $QemuDir") -ForegroundColor Yellow
            Write-Host '      NSIS не допускает кавычки в /D=, тихая установка сюда не сработает.' -ForegroundColor Yellow
            Write-Host '      Варианты:' -ForegroundColor Yellow
            Write-Host '        а) перенесите проект в путь без пробелов и повторите;'
            Write-Host "        б) поставьте QEMU вручную: $QemuInstaller" -ForegroundColor Yellow
            Write-Host "           затем запустите build-all.bat -FromStage 1." -ForegroundColor Yellow
            Read-Host '  Enter'
            Stop-Log; exit 1
        }

        # Установщик подписан просроченным сертификатом: Windows сначала показывает
        # SmartScreen, затем UAC. Отказ или закрытие окна -> Start-Process падает.
        Write-Host '  Тихая установка (NSIS /S /D=)...'
        $installArgs = ConvertTo-PfArgumentList -Arguments @('/S', "/D=$QemuDir") -What 'установщика QEMU'
        if (Test-PfIsAdmin) {
            Write-Host '  Права администратора уже есть.'
            # Именно МАССИВ, а не склеенная строка: Start-Process в PS 5.1 оборачивает
            # строку с пробелами в кавычки и ломает аргументы (см. стадию 5).
            $proc = Start-Process -FilePath $QemuInstaller -ArgumentList $installArgs `
                -Wait -PassThru -ErrorAction Stop
            $null = $proc.Handle   # кэшируем handle, иначе ExitCode бывает пустым
            $code = $proc.ExitCode
            if ($null -eq $code) { $code = 0 }
        } else {
            Write-Host '  Требуются права администратора: запрошу UAC...' -ForegroundColor Yellow
            try {
                $code = Invoke-PfElevated -FilePath $QemuInstaller -ArgumentList $installArgs -WorkDir $RepoRoot
            } catch {
                Write-Host '  UAC отклонён или недоступен — установка отменена.' -ForegroundColor Red
                Write-Host '  Что сделать:' -ForegroundColor Yellow
                Write-Host '    1) если появилось окно «Windows защитит ваш компьютер» —' -ForegroundColor Yellow
                Write-Host '       нажмите «Подробнее», затем «Выполнить в любом случае»;'
                Write-Host '    2) в окне UAC нажмите «Да» (не «Нет» и не закрывайте);'
                Write-Host "    3) либо запустите win\build-all.bat от имени администратора;"
                Write-Host "    4) либо поставьте QEMU вручную: $QemuInstaller" -ForegroundColor Yellow
                Write-Host '       и продолжите: build-all.bat -FromStage 1'
                Write-Host "  Установщик уже скачан и останется на месте: $QemuInstaller" -ForegroundColor DarkGray
                Read-Host '  Enter'
                Stop-Log; exit 1
            }
        }
        if ($code -ne 0) {
            Write-Host "  Установщик QEMU завершился с кодом $code." -ForegroundColor Red
            Write-Host "  Установщик сохранён: $QemuInstaller" -ForegroundColor DarkGray
            Write-Host '  Удалите его и повторите (файл скачается заново), либо запустите вручную.' -ForegroundColor Yellow
            Read-Host '  Enter'
            Stop-Log; exit 1
        }

        if (Have $QemuInstaller) { Remove-Item $QemuInstaller -Force }
        $qemu = Find-PfQemu -ScriptDir $ScriptDir -Exe $QemuExe
        if (-not $qemu) {
            throw ('Установка QEMU не удалась. Проверьте интернет и антивирус.' +
                   "`nЕсли установщик был повреждён — удалите qemu-installer.exe и повторите" +
                   "`n(он скачается заново), либо запустите вручную qemu-w64-setup-*.exe.")
        }
        Write-Host "  [ГОТОВО] QEMU установлен: $qemu" -ForegroundColor Green
    }
}

# ===================== 2. ISO ===============================================
if ($FromStage -le 2) {
    Step 2 "Загрузка $IsoName"
    if ((Have $IsoPath) -and (-not $Force)) {
        Write-Host '  ISO уже есть (для проверки используйте -Force ).' -ForegroundColor Green
    } else {
        if (-not $IsoSha) {
            # берём ожидаемую сумму из SHA256SUMS (переживаем стабильные зеркала)
            $shaFile = Join-Path $RepoRoot 'SHA256SUMS'
            try {
                $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
                if ($curl) {
                    & $curl.Source -L --retry 2 --fail --silent --show-error -o $shaFile $ShaUrl
                    if ($LASTEXITCODE -eq 0) {
                        $line = (Get-Content $shaFile | Where-Object { $_ -match $IsoName }) | Select-Object -First 1
                        if ($line) { $IsoSha = ($line -split '\s+')[0] }
                    }
                }
            } catch { } # SHA optional: если не удалось — загружаем без проверки
        }
        Resume-PfDownload -Url $IsoUrl -OutFile $IsoPath -ExpectedSha $IsoSha
    }
}

# ===================== 3. ВИРТУАЛЬНЫЙ ДИСК ==================================
if ($FromStage -le 3) {
    Step 3 'Создание виртуального диска (qcow2)'
    $qemuImg = Find-PfQemuImg -QemuExe (Find-PfQemu -ScriptDir $ScriptDir -Exe $QemuExe)
    if (-not $qemuImg) { throw 'qemu-img.exe не найден.' }
    if ((Have $VdiskPath) -and (-not $Force)) {
        Write-Host "  Уже есть: $VdiskPath (для пересоздания -Force)." -ForegroundColor Green
    } else {
        if (Have $VdiskPath) { Remove-Item $VdiskPath -Force }
        & $qemuImg create -f qcow2 $VdiskPath "${DiskSizeGb}G"
        if ($LASTEXITCODE -ne 0) { throw 'Не удалось создать виртуальный диск.' }
        Write-Host "  [OK] Диск ${DiskSizeGb}G создан." -ForegroundColor Green
    }
}

# ===================== 4. SEED ISO ==========================================
if ($FromStage -le 4) {
    Step 4 'Сборка seed.iso (autoinstall)'
    if (-not (Have $AutoinstallYaml)) { throw "Не найден $AutoinstallYaml" }
    if (Have $SeedDir)  { Remove-Item $SeedDir -Recurse -Force }
    New-Item $SeedDir -ItemType Directory | Out-Null
    Copy-Item $AutoinstallYaml (Join-Path $SeedDir 'user-data')
    Make-PfSeedIso -SeedDir $SeedDir -OutIso $SeedIso -Label 'CIDATA'
    Write-Host "  [OK] $SeedIso" -ForegroundColor Green
}

# ===================== 5. АВТОУСТАНОВКА =====================================
if ($FromStage -le 5) {
    Step 5 'Установка Kubuntu в QEMU (autoinstall)'
    if ((Have $InstallDoneMarker) -and (-not $Force)) {
        Write-Host '  Установка уже завершена ранее (маркер установлен). Для новой -Force.' -ForegroundColor Green
    } else {
        if (-not (Have $IsoPath))   { throw "Нет ISO: $IsoPath" }
        if (-not (Have $VdiskPath)) { throw "Нет диска: $VdiskPath" }
        if (-not (Have $SeedIso))   { throw "Нет seed: $SeedIso" }
        if ($InstallTimeoutMin -lt 5) { throw '-InstallTimeoutMin должен быть не меньше 5.' }

        $qemu = Find-PfQemu -ScriptDir $ScriptDir -Exe $QemuExe
        if (-not $qemu) { throw 'QEMU не найден. Выполните стадию 1: build-all.bat -FromStage 1' }
        $ramGb  = Get-PfRecommendedRamGb
        $cores0 = Get-PfCores
        $cores  = [Math]::Max(1, [Math]::Floor($cores0 / 2))
        Write-Host "  RAM: ${ramGb} ГБ, ядер: $cores, UEFI (OVMF) автоматически." -ForegroundColor Cyan
        Write-Host "  Предел ожидания: $InstallTimeoutMin мин (-InstallTimeoutMin)." -ForegroundColor Cyan

        # --- ядро и initrd из ISO: без них autoinstall не включится ---------
        Write-Host '  Извлекаю vmlinuz/initrd из ISO (нужны для параметров ядра)...' -ForegroundColor Cyan
        # Защита от устаревшей копии модуля: старый Get-PfIsoBootFiles отдавал
        # лишний объект, $boot.Kernel становился массивом, и Start-Process падал
        # с "Cannot convert System.Object[]". Берём последний объект с нужными
        # полями; если их несколько — предупреждаем, но продолжаем.
        $bootAll = @(Get-PfIsoBootFiles -IsoPath $IsoPath -CacheDir $BootCacheDir)
        # $_ -and обязателен: на $null обращение к .Properties роняет Where-Object
        # с "Cannot index into a null array", а $null в выдаче вполне возможен.
        $boot = $bootAll |
            Where-Object { $_ -and $_.PSObject -and
                           $_.PSObject.Properties['Kernel'] -and $_.PSObject.Properties['Initrd'] } |
            Select-Object -Last 1
        if (-not $boot) {
            $dump = @()
            foreach ($o in $bootAll) {
                $props = (($o.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', ')
                $dump += "  [$($o.GetType().Name)] $props"
            }
            throw ("Get-PfIsoBootFiles не вернул объект с путями ядра/initrd." +
                   "`nПолучено объектов: $($bootAll.Count)" +
                   "`nВерсия модуля: $(Get-PfToolsVersion)" +
                   "`nСодержимое:`n" + ($dump -join "`n"))
        }
        if ($bootAll.Count -gt 1) {
            Write-Host "  [!] Get-PfIsoBootFiles вернул $($bootAll.Count) объектов — беру последний." -ForegroundColor Yellow
            Write-Host '      Обычно это устаревшая копия win\lib\pf-tools.psm1. Скопируйте папку win\ заново.' -ForegroundColor Yellow
        }
        if (($boot.Kernel -isnot [string]) -or ($boot.Initrd -isnot [string]) -or
            (-not $boot.Kernel) -or (-not $boot.Initrd)) {
            throw "Пути ядра/initrd некорректны: Kernel=<$($boot.Kernel)> Initrd=<$($boot.Initrd)>"
        }
        if ($boot.Cached) { Write-Host '  [OK] Ядро/initrd взяты из кэша (повторно не копируем).' -ForegroundColor Green }
        else { Write-Host '  [OK] Ядро/initrd извлечены.' -ForegroundColor Green }

        foreach ($f in @($InstallLog, $QemuStdLog, $QemuErrLog)) {
            if (Have $f) { Remove-Item $f -Force }
        }

        # Порядок console= важен: последний becomes /dev/console. В окне — терминал
        # на экране, в headless — всё в лог.
        $console = if ($ShowWindow) { 'console=ttyS0,115200n8 console=tty0' }
                   else            { 'console=tty0 console=ttyS0,115200n8' }
        $append = "autoinstall ds=nocloud fsck.mode=skip ipv6.disable=1 $console"

        $qmp = if ($QmpPort -gt 0) { $QmpPort } else { Get-PfFreeTcpPort -Start 4500 }

        $qemuArgs = Get-PfQemuBaseArgs -ScriptDir $ScriptDir -QemuExe $QemuExe -RamMb ($ramGb * 1024) -Cores $cores -Uefi
        $qemuArgs += @('-qmp', "tcp:127.0.0.1:$qmp,server=on,wait=off")
        $qemuArgs += @('-kernel', $boot.Kernel)
        $qemuArgs += @('-initrd', $boot.Initrd)
        $qemuArgs += @('-append', $append)
        $qemuArgs += @('-drive', "file=$VdiskPath,media=disk,if=virtio")
        $qemuArgs += @('-drive', "file=$IsoPath,media=cdrom,read-only=on")
        $qemuArgs += @('-drive', "file=$SeedIso,media=cdrom,read-only=on")
        $qemuArgs += @('-no-reboot')
        $qemuArgs += @('-chardev', "file,id=pfser,path=$InstallLog")
        $qemuArgs += @('-serial', 'chardev:pfser')
        if (-not $ShowWindow) { $qemuArgs += @('-display', 'none') }

        Write-Host '  Логи: install.log (внутри ВМ), install-qemu.log (сам QEMU).' -ForegroundColor DarkGray
        if ($ShowWindow) { Write-Host '  Окно QEMU будет показано.' -ForegroundColor Yellow }
        else { Write-Host '  Headless: прогресс печатается здесь из install.log.' -ForegroundColor Yellow }

        # Приводим список к плоскому [string[]] и сами берём в кавычки элементы
        # с пробелами: см. ConvertTo-PfArgumentList в модуле (три проверенные
        # ошибки: вложенный массив, пробел по краям пути, распадение -append).
        $qemuArgs = ConvertTo-PfArgumentList -Arguments $qemuArgs -What 'QEMU (стадия 5)'

        $cmdline = Join-PfArguments $qemuArgs
        Write-Host "  Команда QEMU:`n  $cmdline" -ForegroundColor DarkGray
        $proc = Start-Process -FilePath $qemu -ArgumentList $qemuArgs -WindowStyle Hidden -PassThru `
                -RedirectStandardOutput $QemuStdLog -RedirectStandardError $QemuErrLog
        $null = $proc.Handle   # нужен, чтобы после выхода читался ExitCode

        $cursor  = New-PfLogCursor -Path $InstallLog
        $sw      = [Diagnostics.Stopwatch]::StartNew()
        $lastBeat = 0.0
        $lastWr   = -1
        $quiet    = 0
        $warned   = $false
        $noted    = $false
        $silenceWarned = $false
        $sawCidata = $false
        $timedOut  = $false
        $lastLine  = ''

        while (-not $proc.HasExited) {
            Start-Sleep -Seconds 5

            $lines = @(Read-PfNewLogLines -Cursor $cursor -MaxLines 120)
            $new = 0
            foreach ($raw in $lines) {
                $t = Format-PfLogLine -Text $raw
                if (-not $t) { continue }
                $new++
                $lastLine = $t
                $stamp = (Get-Date -Format 'HH:mm:ss')
                if ($t -match 'PF:') {
                    # наши собственные метки из autoinstall.yaml — главный источник
                    Write-Host "    [$stamp] $t" -ForegroundColor Cyan
                } elseif ($t -match 'stages:\s*([0-9.]+)') {
                    Write-Host ("    [{0}] этап установщика ~{1}%" -f $stamp, [Math]::Round([double]$Matches[1] * 100)) -ForegroundColor DarkCyan
                } elseif ($t -match 'Confirm|use the entire disk') {
                    # Это НЕ признак зависания: строка «Confirm destructive action:
                    # use the entire disk» есть в каждом нормальном логе
                    # autoinstall — subiquity логирует подтверждение и идёт дальше.
                    # Настоящее ожидание ввода ловит детектор тишины ниже
                    # ($quiet -ge 3 плюс отсутствие записи на диск).
                    Write-Host "    [$stamp] $t (это штатная строка автоустановки)" -ForegroundColor DarkGray
                } else {
                    Write-Host "    [$stamp] $t" -ForegroundColor DarkGray
                }
                # Метки [PF: ] ставит только autoinstall.yaml, а он читается
                # исключительно с seed.iso. Значит, любая такая метка доказывает,
                # что seed был подключён — искать в строках install.log отдельный
                # «LABEL=CIDATA» бессмысленно, его там нет.
                if (($t -match 'LABEL=CIDATA') -or ($t -match 'PF:')) { $sawCidata = $true }
            }

            $io = Get-PfQemuIo -Port $qmp -MatchFile $VdiskPath
            $ioOk = ($io -and $io.Matched)

            $mins = $sw.Elapsed.TotalMinutes
            if (($mins - $lastBeat) -ge 1) {
                $lastBeat = $mins
                $qgb = [Math]::Round((Get-Item $VdiskPath).Length / 1GB, 1)
                $wrDelta = -1
                $ioTxt = ''
                if ($ioOk) {
                    if ($lastWr -ge 0) { $wrDelta = [Math]::Round(($io.WriteTotal - $lastWr) / 1MB, 1) }
                    $lastWr = $io.WriteTotal
                    if ($wrDelta -ge 0) { $ioTxt = ", записано +${wrDelta} МБ/мин" }
                    if ($io.Status -and ($io.Status -ne 'running')) { $ioTxt += ", ВМ: $($io.Status)" }
                }
                Write-Host ("  ... {0} мин, образ {1} ГБ{2}" -f [Math]::Floor($mins), $qgb, $ioTxt) -ForegroundColor DarkCyan

                if ($new -eq 0) { $quiet++ } else { $quiet = 0; $warned = $false; $noted = $false }

                # ВМ не выдала НИ ОДНОЙ строки: почти наверняка не загрузилось
                # ядро (частая беда - сборка OVMF без поддержки -kernel).
                if (($cursor.Pos -eq 0) -and ($quiet -ge 3) -and (-not $silenceWarned)) {
                    $silenceWarned = $true
                    Write-Host '  [!] ВМ не вывела ни одной строки за 3 минуты — ядро, похоже, не стартовало.' -ForegroundColor Red
                    Write-Host "      Сообщения QEMU: $QemuErrLog" -ForegroundColor Yellow
                    Write-Host '      Если там есть отказ -accel или ошибка загрузки ядра:' -ForegroundColor Yellow
                    Write-Host '        - добавьте -ShowWindow, чтобы увидеть экран;' -ForegroundColor Yellow
                    Write-Host '        - или перенесите проект в папку без пробелов (иначе QEMU не примет путь к initrd).' -ForegroundColor Yellow
                }

                if ($quiet -ge 3) {
                    if (($wrDelta -gt 0) -and (-not $noted)) {
                        $noted = $true
                        Write-Host '      Идёт, но строк в логе нет — обычно распаковка системы или копирование на диск.' -ForegroundColor DarkGray
                    } elseif (($wrDelta -eq 0) -and (-not $warned)) {
                        $warned = $true
                        Write-Host '  [!] 3 минуты нет ни строки в логе, ни записи на диск.' -ForegroundColor Yellow
                        Write-Host '      Возможен сетевой вопрос или ожидание ввода. Последняя строка:' -ForegroundColor Yellow
                        Write-Host "      $lastLine" -ForegroundColor DarkYellow
                        Write-Host "      Подробности: $InstallLog" -ForegroundColor DarkGray
                    }
                }
            }

            if ($sw.Elapsed.TotalMinutes -ge $InstallTimeoutMin) {
                $timedOut = $true
                break
            }
        }

        if ($timedOut -or (-not $proc.HasExited)) {
            Write-Host "  [!] Превышено время ожидания ($InstallTimeoutMin мин). Останавливаю QEMU..." -ForegroundColor Red
            try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { }
            Start-Sleep -Seconds 2
        } else {
            # дождаться, пока QEMU допишет перенаправленные потоки в файлы
            try { $proc.WaitForExit() } catch { }
        }

        $minsAll = [Math]::Round($sw.Elapsed.TotalMinutes, 1)
        # Ускоритель определяем по фактическим сообщениям QEMU, а не по времени:
        # на медленном хосте даже WHPX даёт 80+ минут, и наоборот.
        $accel = 'неизвестно'
        if (Have $QemuErrLog) {
            $err = (Format-PfLogLine -Text ((Get-Content $QemuErrLog -Raw -ErrorAction SilentlyContinue)) -MaxLen 400)
            if ($err) {
                Write-Host "  Сообщения QEMU: $err" -ForegroundColor DarkGray
                if ($err -match 'whpx') {
                    $accel = 'WHPX (аппаратная виртуализация)'
                    Write-Host "  Ускоритель: $accel" -ForegroundColor Green
                } elseif ($err -match 'tcg') {
                    $accel = 'TCG (медленная эмуляция, установка в разы дольше)'
                    Write-Host "  Ускоритель: $accel" -ForegroundColor Yellow
                }
            }
        }

        if ($timedOut) {
            Write-Host '  Возможные причины (см. install.log):' -ForegroundColor Yellow
            Write-Host '    - нет сети в установщике: сетевой интерфейс не найден (см. строки PF: в логе);' -ForegroundColor Yellow
            Write-Host '    - диск не распознан: ищем PF: диск в install.log;' -ForegroundColor Yellow
            Write-Host "    - просто долго: повторите с -InstallTimeoutMin $(([int]($InstallTimeoutMin * 1.5)))" -ForegroundColor Yellow
            Write-Host "  Хвост install.log:" -ForegroundColor Yellow
            $tailCursor = [pscustomobject]@{ Path = $InstallLog; Pos = [Math]::Max(0, (Get-Item $InstallLog -ErrorAction SilentlyContinue).Length - 6000) }
            foreach ($l in @(Read-PfNewLogLines -Cursor $tailCursor -MaxLines 40)) {
                $t = Format-PfLogLine -Text $l
                if ($t) { Write-Host "    $t" -ForegroundColor DarkGray }
            }
            throw 'Автоустановка не уложилась в отведённое время.'
        }

        if ($proc.ExitCode -ne 0) {
            throw "QEMU завершился с ошибкой (код $($proc.ExitCode)). Подробности: $QemuErrLog"
        }

        $gb = [Math]::Round((Get-Item $VdiskPath).Length / 1GB, 1)
        if ($gb -lt 3) {
            throw ("Подозрительно маленький образ после установки ($gb ГБ) — установка не завершилась." +
                   "`nСмотрите $InstallLog и $QemuErrLog")
        }
        New-Item $InstallDoneMarker -ItemType File -Force | Out-Null
        Write-Host "  [OK] Установка завершена за $minsAll мин, занято $gb ГБ в qcow2." -ForegroundColor Green
        # Никаких выводов про ускоритель «по времени»: 80 минут при WHPX — норма.
        if (-not $sawCidata) {
            Write-Host '  [!] В логе нет ни одной метки [PF: ] — autoinstall мог не прочитать seed.iso.' -ForegroundColor Yellow
            Write-Host "      Стоит проверить, что seed.iso создан и подключён. Подробности: $InstallLog" -ForegroundColor Yellow
        }
    }
}

# ===================== 6. SMOKE-ТЕСТ ========================================
if (($FromStage -le 6) -and (-not $NoSmoke)) {
    Step 6 'Пробная загрузка установленного образа'
    if (-not (Have $VdiskPath)) { throw "Нет образа: $VdiskPath" }
    $qemu = Find-PfQemu -ScriptDir $ScriptDir -Exe $QemuExe
    $ramGb = Get-PfRecommendedRamGb
    $cores = [Math]::Max(1, [Math]::Floor((Get-PfCores) / 2))

    $log = Join-Path $RepoRoot 'smoke-boot.log'
    if (Have $log) { Remove-Item $log -Force }

    $qemuArgs = Get-PfQemuBaseArgs -ScriptDir $ScriptDir -QemuExe $QemuExe -RamMb ($ramGb * 1024) -Cores $cores -Uefi
    $qemuArgs += @('-drive', "file=$VdiskPath,format=qcow2,media=disk,if=virtio")
    $qemuArgs += @('-snapshot')
    $qemuArgs += @('-chardev', "file,id=pfsser,path=$log")
    $qemuArgs += @('-serial', 'chardev:pfsser')
    $qemuArgs += @('-display', 'none')

    Write-Host '  Запуск на 180 сек; ищем вход в графический интерфейс (KDE/SDDM)...' -ForegroundColor Cyan
    $qemuArgs = ConvertTo-PfArgumentList -Arguments $qemuArgs -What 'QEMU (стадия 6)'
    Write-Host "  Команда QEMU:`n  $(Join-PfArguments $qemuArgs)" -ForegroundColor DarkGray
    $p = Start-Process -FilePath $qemu -ArgumentList $qemuArgs -WindowStyle Hidden -PassThru
    $null = $p.Handle
    $markers = @('Reached target Graphical Interface', 'sddm', 'login:', 'GDM')
    $found = $false
    $cursorSmoke = New-PfLogCursor -Path $log
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $lastBeatSmoke = 0.0
    while ($sw.Elapsed.TotalSeconds -lt 180) {
        Start-Sleep -Seconds 5
        if (Have $log) {
            $txt = Get-Content $log -Raw -ErrorAction SilentlyContinue
            if ($txt -and ($markers | Where-Object { $txt -match [regex]::Escape($_) })) { $found = $true; break }
        }
        $newSmoke = @(Read-PfNewLogLines -Cursor $cursorSmoke -MaxLines 8)
        foreach ($l in $newSmoke) {
            $t = Format-PfLogLine -Text $l
            if ($t) { Write-Host "    [$(Get-Date -Format 'HH:mm:ss')] $t" -ForegroundColor DarkGray }
        }
        if (($sw.Elapsed.TotalSeconds - $lastBeatSmoke) -ge 30) {
            $lastBeatSmoke = $sw.Elapsed.TotalSeconds
            $sizeKb = 0
            if (Have $log) { $sizeKb = [int]((Get-Item $log).Length / 1KB) }
            Write-Host ("  ... {0} сек, строк в логе: {1} КБ" -f [Math]::Floor($sw.Elapsed.TotalSeconds), $sizeKb) -ForegroundColor DarkCyan
        }
        if ($p.HasExited) { break }
    }
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    if ($found) {
        Write-Host '  [OK] Система доходит до графического входа.' -ForegroundColor Green
    } else {
        Write-Host '  [i] За 180 сек графический вход не подтверждён.' -ForegroundColor Yellow
        Write-Host '      Это не всегда ошибка (слабый хост/TCG). Лог: smoke-boot.log' -ForegroundColor Yellow
    }
}

# ===================== 7. КОНВЕРТАЦИЯ В RAW =================================
if ($FromStage -le 7) {
    Step 7 'Конвертация qcow2 -> raw'
    if ((Have $RawPath) -and (-not $Force)) {
        Write-Host "  Уже есть: $RawPath (для пересоздания -Force)." -ForegroundColor Green
    } else {
        Convert-PfQcow2ToRaw -QemuImg (Find-PfQemuImg -QemuExe (Find-PfQemu -ScriptDir $ScriptDir -Exe $QemuExe)) `
            -QcowPath $VdiskPath -RawPath $RawPath
        Get-FileHash $RawPath -Algorithm SHA256 | ForEach-Object {
            Set-Content (Join-Path $RepoRoot 'virtual-disk.img.sha256') $_.Hash
        }
        Write-Host "  [OK] RAW-образ готов (артефакт для клонирования)." -ForegroundColor Green
    }
}

# ===================== 8. ЗАПИСЬ НА ФЛЕШКУ ==================================
$targetIdentity = $null
if ($FromStage -le 8) {
    Step 8 'Запись raw-образа на USB-флешку'
    if (-not (Have $RawPath)) { throw "Нет raw-образа: $RawPath" }
    $rawSize = (Get-Item $RawPath).Length

    $disks = @(Get-PfFlashUsb | Where-Object { $_.Size -ge $rawSize } | Sort-Object Size)
    if (-not $disks) {
        Write-Host '  Не найдено USB-флешки, подходящей по размеру.' -ForegroundColor Red
        Write-Host "  Нужен носитель >= $([Math]::Round($rawSize/1GB,1)) ГБ (под 32 ГБ — норм)." -ForegroundColor Yellow
        Read-Host '  Подключите флешку и нажмите Enter'
        $disks = @(Get-PfFlashUsb | Where-Object { $_.Size -ge $rawSize } | Sort-Object Size)
        if (-not $disks) { throw 'Флешка так и не появилась.' }
    }
    if ($disks.Count -eq 1) { $target = $disks[0] }
    else {
        Write-Host '  Несколько подходящих носителей — выберите:'
        $target = Ask-Disk $disks
    }
    $targetDisk = Get-Disk -Number $target.Index -ErrorAction Stop
    if ($targetDisk.IsBoot -or $targetDisk.IsSystem) { throw 'Refusing to write to a boot/system disk.' }
    if ([string]::IsNullOrWhiteSpace([string]$targetDisk.Path)) { throw 'Target disk has no device path identity.' }
    $targetIdentity = [pscustomobject]@{
        Path = [string]$targetDisk.Path
        SerialNumber = ([string]$targetDisk.SerialNumber).Trim()
        Size = [long]$targetDisk.Size
        BusType = [string]$targetDisk.BusType
    }
    $writerIdentity = @{
        ExpectedDevicePath = $targetIdentity.Path
        ExpectedSize = $targetIdentity.Size
    }
    if ($targetIdentity.SerialNumber) { $writerIdentity.ExpectedSerialNumber = $targetIdentity.SerialNumber }
    Write-Host ("  Цель: Disk {0} ({1}, {2:N1} ГБ)" -f $target.Index, $target.Model, ($target.Size / 1GB)) -ForegroundColor Cyan
    Write-Host '  ВСЕ ДАННЫЕ НА НЕЙ БУДУТ УНИЧТОЖЕНЫ.' -ForegroundColor Red
    # First lock volumes; otherwise delete and verify the partition layout.
    # Про сброс разметки предупреждаем заранее, чтобы это не было сюрпризом.
    Write-Host '  Если том не удаётся освободить обычным способом, скрипт сбросит разметку носителя' -ForegroundColor Red
    Write-Host '  (флешка станет «нераспределённой») — образ всё равно перезапишет её целиком.' -ForegroundColor Red

    # Подтверждение вводом yes спрашиваем ЗДЕСЬ, а не внутри write-image.ps1.
    # Только в этом окне ввод виден человеку; elevated-процесс, который мы
    # запустим следом, отдельного консольного ввода не имеет, и Read-Host там
    # повис бы навсегда. Скрипту записи передаём -Yes: «уже подтверждено».
    while ($true) {
        $ans = (Read-Host "  Наберите yes для записи на Disk $($target.Index) (Enter — отмена)").Trim()
        if ($ans -eq '') {
            Write-Host '  Отменено пользователем. Флешка не тронута.' -ForegroundColor Yellow
            Stop-Log; exit 0
        }
        if ($ans -eq 'yes') { break }
        Write-Host "  Нужно именно «yes» (введено «$ans»)." -ForegroundColor Red
    }
    Write-Host '  Подтверждено вводом yes.' -ForegroundColor Green

    if (-not (Test-PfIsAdmin)) {
        Write-Host '  Требуются права администратора: запрошу UAC...' -ForegroundColor Yellow
        $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $ScriptDir 'write-image.ps1'),
               '-ImagePath', $RawPath, '-DiskNumber', [string]$target.Index, '-Yes',
               '-ExpectedDevicePath', $targetIdentity.Path, '-ExpectedSize', [string]$targetIdentity.Size)
        if ($targetIdentity.SerialNumber) { $a += @('-ExpectedSerialNumber', $targetIdentity.SerialNumber) }
        try {
            $code = Invoke-PfElevated -FilePath $PwshPath -ArgumentList $a -WorkDir $ScriptDir
        } catch {
            Write-Host '  UAC отклонён или недоступен.' -ForegroundColor Red
            Write-Host '  Запишите образ вручную: запустите win\write-image.bat от имени администратора.' -ForegroundColor Yellow
            Read-Host '  Enter'
            Stop-Log; exit 1
        }
        if ($code -ne 0) {
            Write-Host "  Запись не удалась (код возврата elevated-процесса: $code)." -ForegroundColor Red
            if (Have $WriteImageLog) {
                Write-Host "  Последние строки $WriteImageLog :" -ForegroundColor Yellow
                try {
                    Get-Content $WriteImageLog -Tail 25 | ForEach-Object {
                        $t = Format-PfLogLine -Text $_
                        if ($t) { Write-Host "    $t" -ForegroundColor DarkYellow }
                    }
                } catch { Write-Host "  Не смог прочитать лог: $($_.Exception.Message)" -ForegroundColor Yellow }
            } else {
                Write-Host "  Лог $WriteImageLog не создан — скрипт записи не стартовал." -ForegroundColor Yellow
                Write-Host '  Скопируйте win\ заново (robocopy /MIR win <куда>\win) и повторите.' -ForegroundColor Yellow
            }
            Stop-Log; exit 1
        }
    } else {
        Write-Host '  Всё уже запущено от администратора. Начинаю write-image.ps1...'
        & (Join-Path $ScriptDir 'write-image.ps1') -ImagePath $RawPath -DiskNumber $target.Index -Yes @writerIdentity
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  Запись не удалась (код выхода: $LASTEXITCODE). Подробности: $WriteImageLog" -ForegroundColor Red
            Stop-Log; exit 1
        }
    }
    Write-Host '  [OK] Запись выполнена.' -ForegroundColor Green
}

# ===================== 9. КОПИЯ QEMU И КНОПКА НА P1 =========================
if ($FromStage -le 9) {
    Step 9 'Размещение QEMU, кнопки и доков на томе P1 (FLASHCARD)'
    if (-not $targetIdentity) {
        $disks = @(Get-PfFlashUsb | Sort-Object Size)
        if (-not $disks) { throw 'No USB target found for stage 9.' }
        if ($disks.Count -eq 1) { $target = $disks[0] }
        else { $target = Ask-Disk $disks }
        $targetDisk = Get-Disk -Number $target.Index -ErrorAction Stop
        if ($targetDisk.IsBoot -or $targetDisk.IsSystem) { throw 'Refusing to copy to a boot/system disk.' }
        if ([string]::IsNullOrWhiteSpace([string]$targetDisk.Path)) { throw 'Target disk has no device path identity.' }
        $targetIdentity = [pscustomobject]@{
            Path = [string]$targetDisk.Path
            SerialNumber = ([string]$targetDisk.SerialNumber).Trim()
            Size = [long]$targetDisk.Size
            BusType = [string]$targetDisk.BusType
        }
    }
    # Disk numbers can change after writing; resolve only the saved device identity.
    $matchesTargetIdentity = {
        ([string]$_.Path -eq $targetIdentity.Path) -and
        (([string]$_.SerialNumber).Trim() -eq $targetIdentity.SerialNumber) -and
        ([long]$_.Size -eq $targetIdentity.Size) -and
        ([string]$_.BusType -eq $targetIdentity.BusType)
    }
    $letter = $null
    $volumeWait = [Diagnostics.Stopwatch]::StartNew()
    do {
        $matchedDisks = @(Get-Disk -ErrorAction Stop | Where-Object $matchesTargetIdentity)
        if ($matchedDisks.Count -gt 1) { throw 'Multiple disks match the saved target identity.' }
        if ($matchedDisks.Count -eq 1) {
            $targetDisk = $matchedDisks[0]
            if ($targetDisk.IsBoot -or $targetDisk.IsSystem) { throw 'Refusing to copy to a boot/system disk.' }
            $volumes = @(Get-Partition -DiskNumber $targetDisk.Number -ErrorAction SilentlyContinue |
                Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.FileSystemLabel -eq $FlashLabel })
            if ($volumes.Count -gt 1) { throw 'Multiple FLASHCARD volumes found on the target disk.' }
            if ($volumes.Count -eq 1 -and [string]$volumes[0].DriveLetter -notmatch '^[A-Za-z]$') {
                $targetDiskNumber = $targetDisk.Number
                $volumePath = [string]$volumes[0].Path
                if ([string]$volumes[0].FileSystem -ne 'FAT32') { throw 'Expected a FAT32 P1 volume before mounting.' }
                if ($volumePath -notmatch '^\\\\\?\\Volume\{[0-9a-fA-F-]{36}\}\\$') {
                    throw 'Target volume has no valid GUID volume path; refusing to mount.'
                }
                $mountParts = @(Get-Partition -DiskNumber $targetDiskNumber -ErrorAction Stop | Where-Object {
                    $partVolumes = @($_ | Get-Volume -ErrorAction SilentlyContinue)
                    @($partVolumes | Where-Object { [string]$_.Path -eq $volumePath }).Count -eq 1
                })
                if ($mountParts.Count -ne 1 -or
                    ([string]$mountParts[0].GptType).Trim('{}') -ne 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b') {
                    throw 'Expected the unmounted FAT32 volume to be the ESP on the selected USB.'
                }
                $mountPartitionNumber = $mountParts[0].PartitionNumber
                if (-not (Test-PfIsAdmin)) {
                    Write-Host '  The selected FAT32 ESP has no drive letter. Administrator rights are required.' -ForegroundColor Red
                    Write-Host '  After the writer has completed, run win\build-all.bat -FromStage 9 as administrator and select the same USB.' -ForegroundColor Yellow
                    Stop-Log; exit 1
                }
                # Repeat identity and volume checks immediately before either mount operation.
                foreach ($mountMethod in @('Add-PartitionAccessPath', 'mountvol')) {
                    $validatedDisks = @(Get-Disk -Number $targetDiskNumber -ErrorAction Stop | Where-Object $matchesTargetIdentity)
                    if ($validatedDisks.Count -ne 1 -or $validatedDisks[0].IsBoot -or $validatedDisks[0].IsSystem) {
                        throw 'Target disk identity changed before mounting.'
                    }
                    $mountPart = Get-Partition -DiskNumber $targetDiskNumber -PartitionNumber $mountPartitionNumber -ErrorAction Stop
                    $mountVolumes = @($mountPart | Get-Volume -ErrorAction Stop)
                    if (([string]$mountPart.GptType).Trim('{}') -ne 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b' -or
                        $mountVolumes.Count -ne 1 -or [string]$mountVolumes[0].Path -ne $volumePath -or
                        [string]$mountVolumes[0].FileSystemLabel -ne $FlashLabel -or [string]$mountVolumes[0].FileSystem -ne 'FAT32') {
                        throw 'Target ESP changed before mounting.'
                    }
                    if ([string]$mountVolumes[0].DriveLetter -match '^[A-Za-z]$') { break }
                    if ($mountMethod -eq 'Add-PartitionAccessPath') {
                        try {
                            Add-PartitionAccessPath -DiskNumber $targetDiskNumber -PartitionNumber $mountPartitionNumber -AssignDriveLetter -ErrorAction Stop
                        } catch {
                            Write-Host "  Add-PartitionAccessPath failed: $($_.Exception.Message); checking GUID mount fallback." -ForegroundColor Yellow
                        }
                        Start-Sleep -Seconds 1
                    } else {
                        $usedLetters = @(Get-Volume -ErrorAction Stop | ForEach-Object { [string]$_.DriveLetter })
                        $usedLetters += @(Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Name })
                        $usedLetters += @(Get-Partition -ErrorAction Stop | ForEach-Object { [string]$_.DriveLetter })
                        $freeLetter = @(68..90 | ForEach-Object { [string][char]$_ } |
                            Where-Object { $_ -ne 'E' -and $_ -notin $usedLetters } | Select-Object -First 1)
                        if ($freeLetter.Count -ne 1) { throw 'No free drive letter D..Z (excluding E) for the selected ESP.' }
                        $mountRoot = $freeLetter[0] + ':\'
                        & "$env:SystemRoot\System32\mountvol.exe" $mountRoot $volumePath
                        if ($LASTEXITCODE -ne 0) { throw "mountvol failed for the selected ESP (exit $LASTEXITCODE)." }
                        Start-Sleep -Seconds 1
                    }
                }
                $volumes = @(Get-Partition -DiskNumber $targetDiskNumber -PartitionNumber $mountPartitionNumber -ErrorAction Stop |
                    Get-Volume -ErrorAction Stop)
                if ($volumes.Count -ne 1 -or [string]$volumes[0].Path -ne $volumePath -or
                    [string]$volumes[0].DriveLetter -notmatch '^[A-Za-z]$') {
                    throw 'The selected ESP still has no drive letter after mounting.'
                }
                Write-Host "  Mounted selected ESP: Disk $targetDiskNumber, partition $mountPartitionNumber, $($volumes[0].DriveLetter):" -ForegroundColor Cyan
            }
            if ($volumes.Count -eq 1 -and [string]$volumes[0].DriveLetter -match '^[A-Za-z]$') {
                $selectedVolumePath = [string]$volumes[0].Path
                $letter = [string]$volumes[0].DriveLetter + ':'
                break
            }
        }
        Start-Sleep -Seconds 1
    } while ($volumeWait.Elapsed.TotalSeconds -lt 25)
    if (-not $letter) {
        Write-Host '  Том P1 с меткой FLASHCARD не проявился.' -ForegroundColor Red
        Write-Host '  Проверьте, что флешка извлечена и вставлена снова; затем скопируйте qemu/ и usb-launcher/ вручную.' -ForegroundColor Yellow
        Stop-Log; exit 1
    }
    $root = $letter + '\'
    Write-Host "  Том P1: $root" -ForegroundColor Cyan

    $qemu = Find-PfQemu -ScriptDir $ScriptDir -Exe $QemuExe
    if (-not $qemu -or -not (Test-Path -LiteralPath $qemu -PathType Leaf)) { throw 'QEMU is required for stage 9.' }
    if (-not (Find-PfOvmf -QemuExe $qemu)) { throw 'UEFI firmware is required for the USB QEMU launcher.' }
    if (-not (Test-Path -LiteralPath (Join-Path $UsbLauncher 'run-qemu.bat') -PathType Leaf)) {
        throw 'USB launcher run-qemu.bat is required for stage 9.'
    }
    $validatedDisks = @(Get-Disk -Number $targetDisk.Number -ErrorAction Stop | Where-Object $matchesTargetIdentity)
    if ($validatedDisks.Count -ne 1 -or $validatedDisks[0].IsBoot -or $validatedDisks[0].IsSystem) {
        throw 'Target disk identity changed before copying.'
    }
    $volumes = @(Get-Partition -DiskNumber $validatedDisks[0].Number -ErrorAction Stop |
        Get-Volume -ErrorAction Stop | Where-Object { $_.FileSystemLabel -eq $FlashLabel })
    if ($volumes.Count -ne 1 -or [string]$volumes[0].DriveLetter -notmatch '^[A-Za-z]$' -or
        [string]$volumes[0].Path -ne $selectedVolumePath -or
        ([string]$volumes[0].DriveLetter + ':') -ne $letter) { throw 'Target volume changed before copying.' }
    if ([string]$volumes[0].FileSystem -ne 'FAT32') { throw 'Expected a FAT32 P1 volume.' }
    $p1 = @(Get-Partition -DiskNumber $validatedDisks[0].Number -ErrorAction Stop |
        Where-Object { [string]$_.DriveLetter -eq [string]$volumes[0].DriveLetter })
    if ($p1.Count -ne 1 -or ([string]$p1[0].GptType).Trim('{}') -ne 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b') {
        throw 'Expected P1 to be the EFI System Partition on the selected USB.'
    }

    $ubuntuBoot = Join-Path $root 'EFI\ubuntu'
    $fallbackBoot = Join-Path $root 'EFI\BOOT'
    $shimSource = Join-Path $ubuntuBoot 'shimx64.efi'
    $bootX64Source = if (Test-Path -LiteralPath $shimSource) { 'shimx64.efi' } else { 'grubx64.efi' }
    $bootFiles = @(
        [pscustomobject]@{ Source = $bootX64Source; Destination = 'BOOTX64.EFI'; Hash = '' }
        [pscustomobject]@{ Source = 'grubx64.efi'; Destination = 'grubx64.efi'; Hash = '' }
        [pscustomobject]@{ Source = 'grub.cfg'; Destination = 'grub.cfg'; Hash = '' }
        [pscustomobject]@{ Source = 'mmx64.efi'; Destination = 'mmx64.efi'; Hash = '' }
    )
    # Validate the complete source chain before replacing any fallback boot file.
    foreach ($bootFile in $bootFiles) {
        $src = Join-Path $ubuntuBoot $bootFile.Source
        if (-not (Test-Path -LiteralPath $src -PathType Leaf) -or (Get-Item -LiteralPath $src).Length -le 0) {
            throw "Required UEFI boot-chain source is missing or empty: $src"
        }
        $bootFile.Hash = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash
    }
    New-Item $fallbackBoot -ItemType Directory -Force | Out-Null
    $bootBackup = $null
    foreach ($bootFile in $bootFiles) {
        $src = Join-Path $ubuntuBoot $bootFile.Source
        $dst = Join-Path $fallbackBoot $bootFile.Destination
        if (Test-Path -LiteralPath $dst) {
            if (-not (Test-Path -LiteralPath $dst -PathType Leaf)) { throw "UEFI destination is not a file: $dst" }
            $oldHash = (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash
            if ($oldHash -eq $bootFile.Hash) { continue }
            if (-not $bootBackup) {
                $bootBackup = Join-Path $fallbackBoot ('pf-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
                New-Item $bootBackup -ItemType Directory | Out-Null
                Write-Host "  UEFI boot-file backup: $bootBackup" -ForegroundColor Cyan
            }
            $backupFile = Join-Path $bootBackup $bootFile.Destination
            Copy-Item -LiteralPath $dst -Destination $backupFile -ErrorAction Stop
            if ((Get-FileHash -LiteralPath $backupFile -Algorithm SHA256).Hash -ne $oldHash) {
                throw "UEFI boot-file backup hash mismatch: $backupFile"
            }
        }
        Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop
        if ((Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash -ne $bootFile.Hash) {
            throw "UEFI boot-chain hash mismatch: $dst"
        }
    }

    $qemuDir = Split-Path $qemu
    $dest = Join-Path $root 'qemu'
    Write-Host "  Копирую QEMU ($([Math]::Round((Get-ChildItem $qemuDir -Recurse | Measure-Object Length -Sum).Sum/1MB,0)) МБ)..."
    New-Item $dest -ItemType Directory -Force | Out-Null
    Copy-Item (Join-Path $qemuDir '*') $dest -Recurse -Force
    Copy-Item (Join-Path $UsbLauncher '*') $root -Recurse -Force

    # README.txt
    $readme = @(
        'Linux Flashcard — два тома, одна система',
        '=',
        '',
        'Том P1: QEMU и кнопки; том P2: единственная система (Kubuntu).',
        '',
        'Запуск:',
        ' 1) run-qemu.bat   — открыть эту же систему в QEMU (нужны права администратора).',
        ' 2) Нативная загрузка — выбрать эту флешку в UEFI boot-меню ПК.',
        ' Подготовка файлов UEFI проверена по SHA256; загрузка на ПК ещё не проверена.',
        ' Legacy BIOS не поддерживается этим образом (MBR boot code отсутствует).',
        '',
        'При ошибке UAC на учебном ПК используйте нативную загрузку.',
        'Подробнее: docs\два-тома.md и docs\учебные-ПК.md'
    ) | Out-String
    Set-Content (Join-Path $root 'README.txt') $readme -Encoding UTF8

    $docsDst = Join-Path $root 'docs'
    New-Item $docsDst -ItemType Directory -Force | Out-Null
    foreach ($f in @('два-тома.md', 'учебные-ПК.md')) {
        $src = Join-Path $RepoRoot "docs\$f"
        if (Test-Path $src) { Copy-Item $src (Join-Path $docsDst $f) -Force }
    }

    if (-not (Test-Path -LiteralPath (Join-Path $dest (Split-Path $qemu -Leaf)) -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $root 'run-qemu.bat') -PathType Leaf)) {
        throw 'QEMU or USB launcher is missing from the target volume.'
    }
    foreach ($bootFile in $bootFiles) {
        $dst = Join-Path $fallbackBoot $bootFile.Destination
        if (-not (Test-Path -LiteralPath $dst -PathType Leaf) -or (Get-Item -LiteralPath $dst).Length -le 0 -or
            (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash -ne $bootFile.Hash -or
            (Get-FileHash -LiteralPath (Join-Path $ubuntuBoot $bootFile.Source) -Algorithm SHA256).Hash -ne $bootFile.Hash) {
            throw "Required UEFI boot chain failed final SHA256 verification: $dst"
        }
    }
    Write-Host '  [OK] Том P1 заполнен; файлы цепочки UEFI проверены по SHA256.' -ForegroundColor Green
    Write-Host ''
    Write-Host 'Готово! Флешка содержит ОДНУ систему; подготовка UEFI проверена:' -ForegroundColor Green
    Write-Host '  - нативная загрузка через UEFI boot-меню (требуется проверка на ПК);' -ForegroundColor Green
    Write-Host '  - Legacy BIOS не поддерживается: MBR boot code в образе отсутствует.' -ForegroundColor Yellow
    Write-Host '  - run-qemu.bat (QEMU с той же системы, нужны права).' -ForegroundColor Green
    Write-Host 'Исходные артефакты: virtual-disk.img / virtual-disk.qcow2 (исправления EFI стадии 9 только на выбранном USB).' -ForegroundColor Cyan

    if ($Eject) {
        $shell = New-Object -ComObject Shell.Application
        $drv = $shell.Namespace(17).ParseName($letter)
        if ($drv) { $drv.InvokeVerb('Eject'); Write-Host '  Том P1 безопасно отключён.' -ForegroundColor Cyan }
    }
}

Write-PfHeader 'Сборка завершена'
Write-Host "  Лог сборки: $BuildLog" -ForegroundColor DarkGray
Stop-Log
exit 0
