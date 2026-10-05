# pf-tools.psm1 — общие функции для скриптов работы с флешкой и QEMU.
# Импорт: Import-Module "$PSScriptRoot\pf-tools.psm1"
# (здесь $PSScriptRoot = каталог lib\ внутри win\)

$ErrorActionPreference = 'Stop'

# Версия модуля. Печатается на стадии 0 рядом с путём к логу: если в build.log
# версия старая, значит на компьютере лежит не тот файл. Такое уже случалось
# дважды (старый lib\pf-tools.psm1 при свежем build-all.ps1) и стоило
# нескольких прогонов по 40 минут, поэтому версия видна сразу.
$script:PfToolsVersion = '2026-10-01.16'
function Get-PfToolsVersion { return $script:PfToolsVersion }

# ---------------------------------------------------------------------------
# Ресурсы хоста (замена wmic, которого больше нет в новых Windows)
# ---------------------------------------------------------------------------
function Get-PfRamMb {
    $cim = Get-CimInstance -ClassName Win32_ComputerSystem
    return [int][Math]::Round($cim.TotalPhysicalMemory / 1MB)
}

function Get-PfCores {
    $cim = Get-CimInstance -ClassName Win32_ComputerSystem
    return [int]$cim.NumberOfLogicalProcessors
}

# Рекомендуемый размер ОЗУ ВМ: max(4, min(RAM/3, 12))
function Get-PfRecommendedRamGb {
    param([int]$RamMb = (Get-PfRamMb))
    $ramGb = [Math]::Floor($RamMb / 3 / 1024)
    $ramGb = [Math]::Max(4, [Math]::Min($ramGb, 12))
    return [int]$ramGb
}

# ---------------------------------------------------------------------------
# Поиск portable QEMU: на флешке рядом с модулем (../../qemu), затем в профиле,
# в Program Files, и, наконец, в PATH.
# ---------------------------------------------------------------------------
function Find-PfQemu {
    param(
        [string]$ScriptDir = '',
        [string]$Exe = ''          # явный путь (build-all.ps1 -QemuExe)
    )
    # Явный путь важнее всего: он единственный переживает копирование проекта
    # поверх E:\ (папка qemu\ при этом стирается). Принимаем и файл, и папку.
    if ($Exe) {
        if (Test-Path $Exe -PathType Container) {
            foreach ($n in @('qemu-system-x86_64.exe', 'qemu-system-x86_64w.exe')) {
                $inDir = Join-Path $Exe $n
                if (Test-Path $inDir) { return (Resolve-Path $inDir).Path }
            }
            Write-Host "  [!] В папке -QemuExe нет qemu-system-x86_64.exe: $Exe" -ForegroundColor Yellow
        } elseif (Test-Path $Exe) {
            return (Resolve-Path $Exe).Path
        } else {
            Write-Host "  [!] -QemuExe не найден: $Exe" -ForegroundColor Yellow
        }
    }
    # Модуль всегда лежит в win\lib -> флешка-директория = win\..
    $moduleWin = Split-Path $PSScriptRoot -Parent

    $rootList = @()
    if ($ScriptDir) {
        $rootList += @(
            (Join-Path $ScriptDir 'qemu')       # том P1 (два тома): <P1>:\qemu
            (Join-Path $ScriptDir '..\qemu')    # репозиторий: linux-flashcard/qemu
            (Join-Path $ScriptDir 'win\qemu')   # win\qemu
        )
    }
    $rootList += @(
        (Join-Path $moduleWin '..\qemu')   # флешка: linux-flashcard/qemu
        (Join-Path $moduleWin 'qemu')      # если положили в win/qemu
        (Join-Path $env:LOCALAPPDATA 'qemu')
        (Join-Path $env:USERPROFILE 'qemu')        # портативная сборка в профиле
        (Join-Path $env:USERPROFILE 'Downloads\qemu')
        (Join-Path $env:ProgramFiles 'qemu')
        (Join-Path ${env:ProgramFiles(x86)} 'qemu')
    )
    foreach ($root in $rootList) {
        foreach ($exe in @('qemu-system-x86_64.exe', 'qemu-system-x86_64w.exe')) {
            $cand = Join-Path $root $exe
            if (Test-Path $cand) { return $cand }
        }
    }
    $inPath = Get-Command 'qemu-system-x86_64.exe' -ErrorAction SilentlyContinue
    if ($inPath) { return $inPath.Source }
    return $null
}

function Find-PfQemuDir {
    $exe = Find-PfQemu
    if (-not $exe) { return $null }
    return Split-Path $exe
}

# qemu-img находится рядом с qemu-system
function Find-PfQemuImg {
    param([string]$QemuExe)
    if (-not $QemuExe) { return $null }
    $share = Join-Path (Split-Path $QemuExe) 'qemu-img.exe'
    if (Test-Path $share) { return $share }
    return $null
}

# Прошивка UEFI (OVMF)
function Find-PfOvmf {
    param([string]$QemuExe)
    if (-not $QemuExe) { return $null }
    $share = Join-Path (Split-Path $QemuExe) 'share'
    $cands = @(
        (Join-Path $share 'edk2-x86_64-code.fd'),
        (Join-Path $share 'qemu\edk2-x86_64-code.fd')
    )
    foreach ($c in $cands) { if (Test-Path $c) { return $c } }
    return $null
}

# ---------------------------------------------------------------------------
# База аргументов QEMU. Всегда передаём whpx И tcg — QEMU сам выбирает
# доступное ускорение (TCG работает и без прав администратора, и без
# аппаратной виртуализации).
# ---------------------------------------------------------------------------
function Get-PfQemuBaseArgs {
    param(
        [int]$RamMb,
        [int]$Cores,
        [string]$CpuModel = 'Westmere',   # оптимизировано под баги эмуляции WHPX
        [switch]$Uefi,
        [string]$ScriptDir = '',
        [string]$QemuExe = ''
    )
    $a = @('-machine', 'type=q35')
    $a += @('-accel', 'whpx,kernel-irqchip=off')
    $a += @('-accel', 'tcg')
    if ($Uefi) {
        $qemu = Find-PfQemu -ScriptDir $ScriptDir -Exe $QemuExe
        $ovmf = Find-PfOvmf -QemuExe $qemu
        if ($ovmf) {
            $a += @('-drive', "if=pflash,format=raw,readonly=on,file=$ovmf")
        } else {
            Write-Host '[ИНФО] OVMF не найден — запуск в режиме Legacy BIOS.' -ForegroundColor Yellow
        }
    }
    $a += @('-cpu', $CpuModel)
    $a += @('-smp', "$Cores")
    $a += @('-m', "$($RamMb)M")
    # сеть: user-NAT с фиксированным DNS (работает даже при странном DNS хоста)
    $a += @('-device', 'virtio-net-pci,netdev=pfnet')
    $a += @('-netdev', 'user,id=pfnet,dns=8.8.8.8')
    $a += @('-vga', 'virtio')
    $a += @('-usb')
    $a += @('-device', 'usb-tablet')
    return ,$a
}

# ---------------------------------------------------------------------------
# seed.iso: сборка ISO с метаданными для cloud-init через встроенный IMAPI2FS
# (ISO9660 + Joliet + UDF, том CIDATA). Никаких внешних утилит не нужно.
# ---------------------------------------------------------------------------
function Make-PfSeedIso {
    param(
        [string]$SeedDir,
        [string]$OutIso,
        [string]$Label = 'CIDATA'
    )
    if (-not (Test-Path $SeedDir)) { throw "Каталог seed не найден: $SeedDir" }
    $metaData = Join-Path $SeedDir 'meta-data'
    if (-not (Test-Path $metaData)) { New-Item $metaData -ItemType File -Force | Out-Null }

    if (Test-Path $OutIso) { Remove-Item $OutIso -Force }

    if (-not ('PfImapiWrite' -as [type])) {
        Add-Type -TypeDefinition @"
using System;using System.IO;using System.Runtime.InteropServices;using System.Runtime.InteropServices.ComTypes;
public static class PfImapiWrite {
    public static void Write(object s, string p){
        IStream stream=(IStream)s;
        using(FileStream fs=File.Create(p)){
            byte[] b=new byte[4096]; IntPtr pR=Marshal.AllocHGlobal(4);
            try{ while(true){ stream.Read(b,b.Length,pR); int r=Marshal.ReadInt32(pR); if(r==0)break; fs.Write(b,0,r);} }
            finally{ Marshal.FreeHGlobal(pR); }
        }
    }
}
"@
    }
    $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $fsi.FileSystemsToCreate = 3
    $fsi.VolumeName = $Label
    $fsi.Root.AddTree($SeedDir, $false)
    $result = $fsi.CreateResultImage()
    [PfImapiWrite]::Write($result.ImageStream, $OutIso)
}

# ---------------------------------------------------------------------------
# Файлы загрузки из ISO: casper/vmlinuz и casper/initrd.
# Зачем они нужны: параметр `autoinstall` обязан попасть в cmdline ЯДРА. Если
# ISO просто загрузить через GRUB, инсталлятор покажет экран подтверждения
# разметки диска, а в headless-режиме его не видно — отсюда «висит вечно».
# Поэтому ядро и initrd отдаём QEMU явно (-kernel/-initrd/-append), а ISO
# остаётся подключённым cdrom, откуда initrd находит live-систему.
# ---------------------------------------------------------------------------

# Каталог с casper\ на уже смонтированном ISO (или $null).
function Find-PfCasperRoot {
    foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if (-not $d.Root) { continue }
        $casper = Join-Path $d.Root 'casper'
        if (Test-Path (Join-Path $casper 'vmlinuz')) { return $casper }
    }
    return $null
}

# Возвращает @{ Kernel=...; Initrd=...; Cached=$true/$false }
function Get-PfIsoBootFiles {
    param(
        [Parameter(Mandatory = $true)][string]$IsoPath,
        [string]$CacheDir = '',
        [int]$MinKernelMb = 5,
        [int]$MinInitrdMb = 50
    )
    if (-not (Test-Path $IsoPath)) { throw "Нет ISO: $IsoPath" }
    $iso = Get-Item $IsoPath

    # --- кэш: копии переиспользуются между запусками -------------------------
    # ЕДИНСТВЕННЫЙ выход в конце функции (return $result). Раньше здесь было
    # два return, и старая копия модуля отдавала лишний объект: $boot.Kernel
    # становился массивом, и Start-Process падал с "Cannot convert System.Object[]".
    $result = $null
    $stamp = '{0}_{1}_{2}' -f $iso.BaseName, $iso.Length, $iso.LastWriteTimeUtc.Ticks
    $kCache = ''
    $iCache = ''
    if ($CacheDir) {
        if (-not (Test-Path $CacheDir)) { New-Item $CacheDir -ItemType Directory -Force | Out-Null }
        $kCache = Join-Path $CacheDir "$stamp-vmlinuz"
        $iCache = Join-Path $CacheDir "$stamp-initrd.img"
        $cacheOk = (Test-Path $kCache) -and (Test-Path $iCache)
        if ($cacheOk) {
            $cacheOk = ((Get-Item $kCache).Length -gt $MinKernelMb * 1MB) -and
                       ((Get-Item $iCache).Length -gt $MinInitrdMb * 1MB)
        }
        if ($cacheOk) {
            $result = [pscustomobject]@{ Kernel = $kCache; Initrd = $iCache; Cached = $true }
        }
    }
    if (-not $result) {

        if (-not $CacheDir) {
            $kCache = Join-Path $env:TEMP "pf-$stamp-vmlinuz"
            $iCache = Join-Path $env:TEMP "pf-$stamp-initrd.img"
        }

        # --- находим ISO в файловой системе --------------------------------------
        $casper = Find-PfCasperRoot
        $mountedByUs = $false
        if (-not $casper) {
            # Mount-DiskImage требует прав администратора. Сначала пробуем его
            # (быстрее и без лишнего окна), а при отказе монтируем через Проводник —
            # так делает двойной щелчок по ISO, и права администратора не нужны.
            try {
                $null = Mount-DiskImage -ImagePath $IsoPath -PassThru -ErrorAction Stop
                $mountedByUs = $true
            } catch {
                Write-Host '  Проводник: монтирую ISO (Mount-DiskImage требует прав администратора)...' -ForegroundColor Yellow
                try {
                    Start-Process -FilePath 'explorer.exe' -ArgumentList $IsoPath -ErrorAction Stop
                    $mountedByUs = $true
                } catch {
                    throw ("Не удалось открыть ISO: " + $_.Exception.Message +
                           "`nОткройте файл $($iso.Name) двойным щелчком в Проводнике" +
                           "`n(Windows смонтирует его на отдельную букву) и повторите запуск.")
                }
            }
            $swMount = [Diagnostics.Stopwatch]::StartNew()
            while (-not $casper -and $swMount.Elapsed.TotalSeconds -lt 40) {
                Start-Sleep -Milliseconds 500
                $casper = Find-PfCasperRoot
            }
            if (-not $casper) {
                if ($mountedByUs) { Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue }
                throw "После монтирования ISO не найден каталог casper\ с vmlinuz.`nКаталог в образе: casper\`nПроверьте, что ISO скачался целиком (стадия 2)."
            }
        }

        try {
            $kernelSrc = Join-Path $casper 'vmlinuz'
            $initrdSrc = $null
            foreach ($n in @('initrd.img', 'initrd', 'initrd.img.gz')) {
                $cand = Join-Path $casper $n
                if (Test-Path $cand) { $initrdSrc = $cand; break }
            }
            if (-not $initrdSrc) {
                $have = ((Get-ChildItem $casper -ErrorAction SilentlyContinue) | ForEach-Object { $_.Name }) -join ', '
                throw "В $casper нет initrd.img. Найдено: $have"
            }
            Write-Host "  Копирую: $kernelSrc" -ForegroundColor DarkGray
            Copy-Item $kernelSrc $kCache -Force
            Write-Host "  Копирую: $initrdSrc" -ForegroundColor DarkGray
            Copy-Item $initrdSrc $iCache -Force
        } finally {
            if ($mountedByUs) { Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue }
        }

        $kSize = (Get-Item $kCache).Length
        $iSize = (Get-Item $iCache).Length
        if (($kSize -le $MinKernelMb * 1MB) -or ($iSize -le $MinInitrdMb * 1MB)) {
            throw ("Файлы ядра выглядят некорректно: vmlinuz = $([Math]::Round($kSize/1MB,1)) МБ," +
                   " initrd = $([Math]::Round($iSize/1MB,1)) МБ. Возможно, ISO повреждён.")
        }
        $result = [pscustomobject]@{
            Kernel = $kCache
            Initrd = $iCache
            Cached = $false
        }

    } # конец «если кэш не годен»

    return $result
}

# ---------------------------------------------------------------------------
# «Живой» хвост растущего лога (install.log и т.п.): курсор + чтение новых строк
# ---------------------------------------------------------------------------
function New-PfLogCursor {
    param([string]$Path)
    return [pscustomobject]@{ Path = $Path; Pos = [long]0 }
}

# Возвращает только те строки, которых курсор ещё не видел.
function Read-PfNewLogLines {
    param(
        [Parameter(Mandatory = $true)]$Cursor,
        [int]$MaxLines = 200
    )
    $out = @()
    if (-not (Test-Path $Cursor.Path)) { return $out }
    $fs = $null
    try {
        $fs = [IO.File]::Open($Cursor.Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        if ($fs.Length -lt $Cursor.Pos) { $Cursor.Pos = 0 }   # лог перезаписан
        if ($fs.Length -eq $Cursor.Pos) { return $out }
        $null = $fs.Seek($Cursor.Pos, [IO.SeekOrigin]::Begin)
        $take = [int][Math]::Min(262144, $fs.Length - $Cursor.Pos)
        $buf = New-Object byte[] $take
        $got = $fs.Read($buf, 0, $take)
        $Cursor.Pos = $Cursor.Pos + $got
        $txt = [Text.Encoding]::UTF8.GetString($buf, 0, $got)
        $out = @($txt -split "`r?`n")
        if ($out.Count -gt $MaxLines) { $out = $out[($out.Count - $MaxLines)..($out.Count - 1)] }
    } catch {
        # лог может быть занят QEMU — молча пропускаем и пробуем позже
    } finally {
        if ($fs) { $fs.Close() }
    }
    return $out
}

# Чистка строки лога: escape-последовательности терминала, CR, длинные хвосты.
function Format-PfLogLine {
    param([string]$Text, [int]$MaxLen = 200)
    if ($null -eq $Text) { return '' }
    $esc = [string][char]27
    $t = $Text
    if ($t.Contains($esc)) {
        $t = [regex]::Replace($t, [regex]::Escape($esc) + '\[[0-9;?]*[ -/]*[@-~]', '')
        $t = [regex]::Replace($t, [regex]::Escape($esc) + '\][^\x07\x1b]*(\x07|\x1b\\)?', '')
    }
    $t = $t -replace "`r", ' '
    $t = $t -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', ''
    $t = $t.Trim()
    if ($t.Length -gt $MaxLen) { $t = $t.Substring(0, $MaxLen) + '...' }
    return $t
}

# ---------------------------------------------------------------------------
# QMP: состояние ВМ и объём чтения/записи по блочным устройствам.
# Нужен, чтобы видеть «идёт ли работа» даже когда гость молчит.
# ---------------------------------------------------------------------------
function Get-PfFreeTcpPort {
    param([int]$Start = 4500, [int]$Count = 100)
    $busy = @{}
    try {
        foreach ($c in (Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)) {
            $busy[[int]$c.LocalPort] = $true
        }
    } catch { }
    for ($p = $Start; $p -lt ($Start + $Count); $p++) {
        if (-not $busy.ContainsKey($p)) { return $p }
    }
    return $Start
}

function Read-PfQmpReply {
    param($Reader)
    for ($i = 0; $i -lt 60; $i++) {
        $line = $Reader.ReadLine()
        if ($null -eq $line) { return $null }
        if (-not $line.Trim()) { continue }
        $obj = $null
        try { $obj = $line | ConvertFrom-Json } catch { continue }
        if ($obj.PSObject.Properties['return'] -or $obj.PSObject.Properties['error']) { return $obj }
    }
    return $null
}

# Один опрос ВМ. $null, если QMP недоступен (не критично).
function Get-PfQemuIo {
    param(
        [int]$Port = 4500,
        [string]$MatchFile = ''
    )
    $result = $null
    $client = $null
    try {
        $client = New-Object Net.Sockets.TcpClient
        $client.ReceiveTimeout = 5000
        $client.SendTimeout = 5000
        $client.Connect('127.0.0.1', $Port)
        $stream = $client.GetStream()
        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8)
        $writer = New-Object IO.StreamWriter($stream, (New-Object Text.UTF8Encoding($false)))
        $writer.AutoFlush = $true
        $null = $reader.ReadLine()                                   # приветствие QMP
        $writer.WriteLine('{"execute":"qmp_capabilities"}')
        $null = Read-PfQmpReply -Reader $reader
        $writer.WriteLine('{"execute":"query-status"}')
        $st = Read-PfQmpReply -Reader $reader
        $status = 'unknown'
        if ($st -and $st.PSObject.Properties['return'] -and $st.return -and $st.return.PSObject.Properties['status']) {
            $status = [string]$st.return.status
        }
        $writer.WriteLine('{"execute":"query-blockstats"}')
        $bs = Read-PfQmpReply -Reader $reader

        $devs = @()
        $rd = [long]0
        $wr = [long]0
        $matched = -not $MatchFile
        if ($bs -and $bs.PSObject.Properties['return'] -and $bs.return) {
            $want = [IO.Path]::GetFileName($MatchFile)
            foreach ($d in $bs.return) {
                if (-not $d.inserted) { continue }
                $fileName = ''
                if ($d.inserted.PSObject.Properties['file'] -and $d.inserted.file) { $fileName = [string]$d.inserted.file }
                if ((-not $fileName) -and $d.inserted.image -and $d.inserted.image.PSObject.Properties['filename']) {
                    $fileName = [string]$d.inserted.image.filename
                }
                if ($MatchFile) {
                    if ((-not $fileName) -or ($fileName -notlike "*$want*")) { continue }
                }
                $r = [long]0
                $w = [long]0
                if ($d.stats) {
                    if ($d.stats.PSObject.Properties['rd_bytes']) { $r = [long]$d.stats.rd_bytes }
                    if ($d.stats.PSObject.Properties['wr_bytes']) { $w = [long]$d.stats.wr_bytes }
                }
                $rd += $r
                $wr += $w
                $matched = $true
                $name = [string]$d.node
                if ((-not $name) -and $d.PSObject.Properties['device']) { $name = [string]$d.device }
                $devs += [pscustomobject]@{ Node = $name; File = $fileName; Read = $r; Write = $w }
            }
        }
        $result = [pscustomobject]@{
            Status     = $status
            ReadTotal  = $rd
            WriteTotal = $wr
            Matched    = $matched
            Devices    = $devs
        }
    } catch {
        $result = $null
    } finally {
        if ($client) { $client.Close() }
    }
    return $result
}

# ---------------------------------------------------------------------------
# Работа с флешками и томами
# ---------------------------------------------------------------------------
function Get-PfFlashUsb {
    return @(Get-CimInstance Win32_DiskDrive | Where-Object { $_.InterfaceType -eq 'USB' })
}

# Буква тома по метке (например, FLASHCARD) -> 'E:'
function Get-PfVolumeByLabel {
    param([string]$Label = 'FLASHCARD')
    $esc = $Label.Replace("'", "''")
    $vol = Get-CimInstance Win32_LogicalDisk -Filter "VolumeName='$esc'" -ErrorAction SilentlyContinue
    if ($vol) { return $vol.DeviceID }
    return $null
}

# Ожидание появления тома с меткой (после записи образа Windows перечитывает том).
function Wait-PfVolumeByLabel {
    param([string]$Label = 'FLASHCARD', [int]$TimeoutSec = 25)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $letter = Get-PfVolumeByLabel -Label $Label
        if ($letter) { return $letter }
        Start-Sleep -Seconds 1
    }
    return $null
}

# Номер физического диска (PhysicalDriveN), на котором живёт том с меткой.
# Цепочка WMI: LogicalDisk -> LogicalDiskToPartition -> DiskDriveToDiskPartition.
function Get-PfPhysicalDriveOfVolume {
    param([string]$Label = 'FLASHCARD')
    $letter = Get-PfVolumeByLabel -Label $Label
    if (-not $letter) { return -1 }
    if (@($letter).Count -ne 1) { return -1 }
    $parts = @(Get-Partition -DriveLetter $letter.Substring(0, 1) -ErrorAction Stop)
    if ($parts.Count -eq 1) { return [int]$parts[0].DiskNumber }
    return -1
}

# Съёмный USB-диск, на котором есть том с меткой (сама флешка).
function Get-PfFlashByLabel {
    param([string]$Label = 'FLASHCARD')
    $n = Get-PfPhysicalDriveOfVolume -Label $Label
    if ($n -lt 0) { return $null }
    return Get-CimInstance Win32_DiskDrive -Filter "Index=$n" -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Прямая запись на физический диск: \\.\PhysicalDriveN
#
# ПОЧЕМУ НЕ System.IO.File. Раньше диск открывался так:
#     [System.IO.File]::Open($Drive, 'Open', 'Write', 'None')
# FileShare.None требует МОНОПОЛЬНЫЙ доступ. Пока на носителе смонтирован том
# (окно Проводника, индексатор, антивирус), хоть один его handle живёт, и
# Windows отвечает на такой open для \\.\PhysicalDriveN не «sharing violation»,
# а ERROR_ACCESS_DENIED — «Отказано в доступе по данному пути». Отсюда был
# сбой записи с кодом возврата 1 при заведомо исправной флешке.
#
# Теперь открываем через Win32 CreateFile с dwShareMode =
# FILE_SHARE_READ|FILE_SHARE_WRITE, то есть ДЕЛИМ доступ, как это делают Rufus,
# balenaEtcher и dd для Windows.
# ---------------------------------------------------------------------------
function Add-PfRawDiskNative {
    if ('PfRawDisk' -as [type]) { return }
    Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class PfRawDisk {
    const uint GENERIC_READ       = 0x80000000;
    const uint GENERIC_WRITE      = 0x40000000;
    const uint FILE_SHARE_READ    = 0x1;
    const uint FILE_SHARE_WRITE   = 0x2;
    const uint OPEN_EXISTING      = 3;
    const uint FILE_ATTRIBUTE_NORMAL = 0x80;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFileW(
        string lpFileName, uint dwDesiredAccess, uint dwShareMode,
        IntPtr lpSecurityAttributes, uint dwCreationDisposition,
        uint dwFlagsAndAttributes, IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool WriteFile(SafeFileHandle hFile, byte[] lpBuffer,
        uint nNumberOfBytesToWrite, out uint lpNumberOfBytesWritten, IntPtr lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadFile(SafeFileHandle hFile, byte[] lpBuffer,
        uint nNumberOfBytesToRead, out uint lpNumberOfBytesRead, IntPtr lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool FlushFileBuffers(SafeFileHandle hFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetFilePointerEx(SafeFileHandle hFile, long distance,
        IntPtr newPointer, uint moveMethod);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(SafeFileHandle hDevice, uint dwIoControlCode,
        IntPtr lpInBuffer, uint nInBufferSize, IntPtr lpOutBuffer, uint nOutBufferSize,
        out uint lpBytesReturned, IntPtr lpOverlapped);

    // CTL_CODE(FILE_DEVICE_DISK, 0x40, METHOD_BUFFERED, READ | WRITE).
    const uint IOCTL_DISK_DELETE_DRIVE_LAYOUT = 0x0007C100;
    const uint IOCTL_DISK_UPDATE_PROPERTIES = 0x00070140;

    public static SafeFileHandle Open(string path, bool forWrite) {
        uint access = forWrite ? GENERIC_WRITE : GENERIC_READ;
        uint share  = FILE_SHARE_READ | FILE_SHARE_WRITE;
        SafeFileHandle h = CreateFileW(path, access, share, IntPtr.Zero,
                                       OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, IntPtr.Zero);
        if (h.IsInvalid) {
            int err = Marshal.GetLastWin32Error();
            h.Dispose();
            throw new Win32Exception(err, "CreateFile не удался для " + path);
        }
        return h;
    }

    public static void Write(SafeFileHandle h, byte[] buf) {
        Write(h, buf, buf.Length);
    }

    // Записать первые count байт буфера. Последний блок обычно короче
    // целого, и без count пришлось бы копировать срез массива.
    public static void Write(SafeFileHandle h, byte[] buf, int count) {
        uint done;
        if (!WriteFile(h, buf, (uint)count, out done, IntPtr.Zero))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "WriteFile");
        if (done != (uint)count)
            throw new IOException("WriteFile записал " + done + " из " + count + " байт");
    }

    public static uint Read(SafeFileHandle h, byte[] buf, long offset) {
        if (!SetFilePointerEx(h, offset, IntPtr.Zero, 0))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "SetFilePointerEx");
        uint done;
        if (!ReadFile(h, buf, (uint)buf.Length, out done, IntPtr.Zero))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "ReadFile");
        return done;
    }

    public static void Flush(SafeFileHandle h) {
        if (!FlushFileBuffers(h))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "FlushFileBuffers");
    }

    public static int DeleteLayout(string path) {
        SafeFileHandle h = CreateFileW(path, GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero,
            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, IntPtr.Zero);
        if (h.IsInvalid) {
            int err = Marshal.GetLastWin32Error();
            h.Dispose();
            return err;
        }
        try {
            uint ret;
            if (!DeviceIoControl(h, IOCTL_DISK_DELETE_DRIVE_LAYOUT, IntPtr.Zero, 0,
                                 IntPtr.Zero, 0, out ret, IntPtr.Zero))
                return Marshal.GetLastWin32Error();
            if (!DeviceIoControl(h, IOCTL_DISK_UPDATE_PROPERTIES, IntPtr.Zero, 0,
                                 IntPtr.Zero, 0, out ret, IntPtr.Zero))
                return Marshal.GetLastWin32Error();
            return 0;
        } finally { h.Dispose(); }
    }

    public static void Refresh(string path) {
        SafeFileHandle h = CreateFileW(path, GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero,
            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, IntPtr.Zero);
        if (h.IsInvalid) {
            int err = Marshal.GetLastWin32Error();
            h.Dispose();
            throw new Win32Exception(err, "CreateFile: " + path);
        }
        try {
            uint ret;
            if (!DeviceIoControl(h, IOCTL_DISK_UPDATE_PROPERTIES, IntPtr.Zero, 0,
                                 IntPtr.Zero, 0, out ret, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "IOCTL_DISK_UPDATE_PROPERTIES");
        } finally { h.Dispose(); }
    }
}
"@
}

# ---------------------------------------------------------------------------
# Блокировка томов съёмного носителя: FSCTL_LOCK_VOLUME + FSCTL_DISMOUNT_VOLUME
#
# ПОЧЕМУ НЕ Set-Disk -IsOffline. Для USB-флешки Windows отвечает отказом:
#     «Not Supported / Removable media cannot be set to offline»
# Съёмные носители нельзя уводить в offline вообще, поэтому весь прежний
# план «оставить диск offline перед записью» на флешке неисполним. Это
# подтверждено на реальном запуске.
#
# ЧТО ДЕЛАЕТ ЭТОТ БЛОК. Смонтированный том держит носитель открытым, и
# WriteFile в \\.\PhysicalDriveN получает ERROR_ACCESS_DENIED (5). Общий
# доступ в CreateFile решает только открытие, но не запись: файловая система
# должна отпустить том. Для этого том открывается как \\.\X: и на нём
# выполняются FSCTL_LOCK_VOLUME (запретить другим открытия) и
# FSCTL_DISMOUNT_VOLUME (отсоединить от системы). Пока том заблокирован,
# носитель можно писать целиком. Так поступают Rufus и balenaEtcher.
# ---------------------------------------------------------------------------
function Add-PfVolumeNative {
    if ('PfVolume' -as [type]) { return }
    Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class PfVolume {
    const uint GENERIC_READ  = 0x80000000;
    const uint GENERIC_WRITE = 0x40000000;
    const uint FILE_SHARE_READ  = 0x1;
    const uint FILE_SHARE_WRITE = 0x2;
    const uint OPEN_EXISTING = 3;
    const uint FILE_ATTRIBUTE_NORMAL = 0x80;
    // CTL_CODE(FILE_DEVICE_FILE_SYSTEM, Function, METHOD_BUFFERED, FILE_ANY_ACCESS)
    // winioctl.h function numbers: LOCK=6, UNLOCK=7, DISMOUNT=8, IS_MOUNTED=10.
    // Прежнее значение UNLOCK 0x00090028 было неверным (это функция 10, то
    // есть чужой IOCTL) и маскировалось тем, что блокировка всегда падала
    // раньше. С неправильной константой Unlock рушил бы очистку в finally.
    const uint FSCTL_LOCK_VOLUME       = 0x00090018;
    const uint FSCTL_UNLOCK_VOLUME     = 0x0009001C;
    const uint FSCTL_DISMOUNT_VOLUME   = 0x00090020;
    const uint FSCTL_IS_VOLUME_MOUNTED = 0x00090028;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFileW(
        string lpFileName, uint dwDesiredAccess, uint dwShareMode,
        IntPtr lpSecurityAttributes, uint dwCreationDisposition,
        uint dwFlagsAndAttributes, IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(SafeFileHandle hDevice, uint dwIoControlCode,
        IntPtr lpInBuffer, uint nInBufferSize, IntPtr lpOutBuffer, uint nOutBufferSize,
        out uint lpBytesReturned, IntPtr lpOverlapped);

    // Открыть \\.\X: (например \\.\D:) для управления томом.
    // Open a direct-access volume handle, not a root-directory handle.
    public static SafeFileHandle OpenVolume(string letter) {
        SafeFileHandle h = CreateFileW(letter.TrimEnd('\\'), GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero,
            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, IntPtr.Zero);
        if (h.IsInvalid) {
            int err = Marshal.GetLastWin32Error();
            h.Dispose();
            throw new Win32Exception(err, "Не удалось открыть том " + letter);
        }
        return h;
    }

    static void Ctl(SafeFileHandle h, uint code, string name) {
        uint ret;
        if (!DeviceIoControl(h, code, IntPtr.Zero, 0, IntPtr.Zero, 0, out ret, IntPtr.Zero))
            throw new Win32Exception(Marshal.GetLastWin32Error(), name);
    }

    // Заблокировать и отсоединить том. Порядок именно такой: сначала LOCK
    // (запрещаем чужие открытия), затем DISMOUNT (отдаём том системе).
    public static void LockAndDismount(SafeFileHandle h) {
        Ctl(h, FSCTL_LOCK_VOLUME, "FSCTL_LOCK_VOLUME");
        Ctl(h, FSCTL_DISMOUNT_VOLUME, "FSCTL_DISMOUNT_VOLUME");
    }

    // Dismount alone does not prevent another process from remounting.
    public static void DismountOnly(SafeFileHandle h) {
        Ctl(h, FSCTL_DISMOUNT_VOLUME, "FSCTL_DISMOUNT_VOLUME");
    }

    // Смонтирован ли том сейчас. Без успешного LOCK том может быть
    // перемонтирован кем угодно, поэтому это стоит проверять честно.
    public static bool IsMounted(SafeFileHandle h) {
        uint ret;
        if (DeviceIoControl(h, FSCTL_IS_VOLUME_MOUNTED, IntPtr.Zero, 0,
                            IntPtr.Zero, 0, out ret, IntPtr.Zero)) return true;
        int err = Marshal.GetLastWin32Error();
        if (err == 21) return false; // ERROR_NOT_READY: volume is not mounted.
        throw new Win32Exception(err, "FSCTL_IS_VOLUME_MOUNTED");
    }

    // Открыть \\.\X: с правом записи — запись напрямую в том, в обход ФС.
    // Имеет смысл, когда раздел начинается с сектора 0 и покрывает весь
    // носитель: тогда адреса тома совпадают с адресами диска.
    public static SafeFileHandle OpenVolumeWrite(string letter) {
        SafeFileHandle h = CreateFileW(letter.TrimEnd('\\'), GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero,
            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, IntPtr.Zero);
        if (h.IsInvalid) {
            int err = Marshal.GetLastWin32Error();
            h.Dispose();
            throw new Win32Exception(err, "Не удалось открыть том " + letter + " на запись");
        }
        return h;
    }

    public static void Unlock(SafeFileHandle h) {
        Ctl(h, FSCTL_UNLOCK_VOLUME, "FSCTL_UNLOCK_VOLUME");
    }
}
"@
}

# Открыть \\.\PhysicalDriveN. Access: 'Write' или 'Read'.
# Возвращает SafeFileHandle, который обязан быть Dispose() через finally.
function Open-PfRawDisk {
    param(
        [Parameter(Mandatory = $true)][string]$Drive,
        [ValidateSet('Write', 'Read')][string]$Access = 'Write'
    )
    Add-PfRawDiskNative
    return [PfRawDisk]::Open($Drive, ($Access -eq 'Write'))
}

function Write-PfRawBytes {
    param(
        [Parameter(Mandatory = $true)]$Handle,
        [byte[]]$Bytes,
        [int]$Count = -1
    )
    # PS 5.1 scans every element of a mandatory array; check null explicitly.
    if ($null -eq $Bytes) { throw 'Bytes are required.' }
    if ($Count -lt 0 -or $Count -gt $Bytes.Length) { $Count = $Bytes.Length }
    [PfRawDisk]::Write($Handle, $Bytes, $Count)
}

# Прочитать с произвольного смещения (нужно для сверки записанного).
function Read-PfRawBytes {
    param(
        [Parameter(Mandatory = $true)]$Handle,
        [byte[]]$Bytes,
        [Parameter(Mandatory = $true)][long]$Offset
    )
    if ($null -eq $Bytes) { throw 'Bytes are required.' }
    return [int][PfRawDisk]::Read($Handle, $Bytes, $Offset)
}

function Flush-PfRawDisk {
    param([Parameter(Mandatory = $true)]$Handle)
    [PfRawDisk]::Flush($Handle)
}

# Заблокировать и отмонтировать тома носителя.
#
# Прежняя версия полагалась на Set-Disk -IsOffline и молча глотала ошибки
# (`catch { }`), из-за чего на USB-флешке тихо возвращала 0: Windows не
# даёт увести removable в offline, а Dismount-Volume для FAT16-съёмника
# ничего не делал. Теперь используем блокировку томов средствами ФС
# (FSCTL_LOCK_VOLUME + FSCTL_DISMOUNT_VOLUME) — путь Rufus/Etcher.
#
# Возвращает массив PSCustomObject: Letter, Handle (держать до конца записи!),
# Locked, Detail. Handle освобождать через Release-PfVolumeLocks.
function Get-PfVolumePath {
    param(
        [string]$Letter = '',
        [int]$DiskNumber = 0,
        [int]$PartitionNumber = 0
    )
    # CreateFile needs the volume name without its root-directory slash.
    # Буквы может не быть (том без точки монтирования) — тогда берём GUID
    # из Win32_Volume.DeviceID. Раньше путь строился как "\\.\D" БЕЗ
    # двоеточия, и CreateFile отвечал кодом 2 (ERROR_FILE_NOT_FOUND).
    # ${Letter} в фигурных скобках обязателен: в "$Letter:" PowerShell
    # посчитал бы двоеточие частью имени переменной и не распарсил файл.
    if ($Letter -eq [string][char]0) { $Letter = '' }
    if ($Letter) {
        if ($Letter -notmatch '^[A-Za-z]$') { throw 'Invalid volume drive letter.' }
        return "\\.\${Letter}:"
    }

    $part = $null
    if ($DiskNumber -ge 0 -and $PartitionNumber -gt 0) {
        try { $part = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -ErrorAction Stop } catch { }
    }

    if ($part) {
        # 1) AccessPaths раздела уже содержит путь \\?\Volume{GUID}\ —
        #    самый дешёвый и точный источник.
        foreach ($a in @($part.AccessPaths)) {
            if ("$a" -like '\\?\Volume{*') { return ([string]$a).TrimEnd('\') }
        }
        # 2) Связь «раздел -> том» через хранилище CIM. MSFT_Volume.DeviceID
        #    уже содержит \\?\Volume{GUID}\.
        try {
            $mp = Get-CimInstance -Namespace 'Root/Microsoft/Windows/Storage' -ClassName MSFT_Partition `
                    -Filter ("DiskNumber={0} AND PartitionNumber={1}" -f $DiskNumber, $PartitionNumber) -ErrorAction Stop
            foreach ($v in @(Get-CimAssociatedInstance -InputObject $mp -ResultClassName MSFT_Volume -ErrorAction Stop)) {
                if ($v.DeviceID) { return ([string]$v.DeviceID).TrimEnd('\') }
            }
        } catch { }
    }

    # 3) Последний довод — перебор локальных томов, но СТРОГО по номеру
    #    диска. Прежний код возвращал ПЕРВЫЙ попавшийся том DriveType=3,
    #    не сверяя его с целевым диском: на машине с несколькими локальными
    #    томами это означало блокировку не того тома (вплоть до C:).
    try {
        foreach ($v in @(Get-CimInstance Win32_Volume -Filter 'DriveType=3' -ErrorAction Stop)) {
            $letter = [string]$v.DriveLetter
            $letter = $letter.TrimEnd(':')
            if (-not $letter) { continue }   # без буквы диск не определить
            try {
                $pp = Get-Partition -DriveLetter $letter -ErrorAction Stop
                if ($pp.DiskNumber -eq $DiskNumber -and $pp.PartitionNumber -eq $PartitionNumber) {
                    return ([string]$v.DeviceID).TrimEnd('\')
                }
            } catch { }
        }
    } catch { }
    return ''
}

# Заблокировать и отмонтировать тома носителя.
#
# Прежняя версия полагалась на Set-Disk -IsOffline и молча глотала ошибки
# (`catch { }`), из-за чего на USB-флешке тихо возвращала 0: Windows не
# даёт увести removable в offline, а Dismount-Volume для FAT16-съёмника
# ничего не делал. Теперь используем блокировку томов средствами ФС
# (FSCTL_LOCK_VOLUME + FSCTL_DISMOUNT_VOLUME) — путь Rufus/Etcher.
#
# Возвращает массив PSCustomObject: Letter, Path, Handle (держать до конца
# записи!), Locked, Detail. Handle освобождать через Release-PfVolumeLocks.
function Lock-PfDiskVolumes {
    param(
        [Parameter(Mandatory = $true)][int]$Number,
        [string]$Drive = ''
    )
    Add-PfVolumeNative
    Add-PfRawDiskNative
    $result = @()
    $paths = @()
    $letters = @()
    try {
        foreach ($p in @(Get-PfDiskPartitions -Number $Number)) {
            $gptType = ([string]$p.GptType).Trim('{}')
            if ($gptType -in '21686148-6449-6e6f-744e-656564454649', '0fc63daf-8483-4772-8e79-3d69d8477de4') {
                # BIOS/Linux partitions have volume names even without a Windows
                # filesystem. Still lock them if a third-party driver mounts one.
                $mountedFilesystems = @($p | Get-Volume -ErrorAction Stop | Where-Object { $_.FileSystem })
                if (-not $mountedFilesystems.Count) { continue }
            }
            $L = ''
            if ($p.DriveLetter) { $L = [string]$p.DriveLetter }
            $vol = Get-PfVolumePath -Letter $L -DiskNumber $Number -PartitionNumber $p.PartitionNumber
            if (-not $vol -and ($L -or @($p.AccessPaths | Where-Object { $_ -like '\\?\Volume{*' }).Count)) {
                throw "Cannot resolve the Windows volume on partition $($p.PartitionNumber)."
            }
            if ($vol) {
                $paths += $vol
                $letters += if ($L) { "$L" } else { '(без буквы)' }
            }
        }
    } catch {
        throw
    }
    # Томов может не быть вовсе (чистый носитель) — это нормально.
    for ($i = 0; $i -lt $paths.Count; $i++) {
        $vol = $paths[$i]
        $name = $letters[$i]
        $h = $null
        $held = $false
        $state = 'ошибка'
        try {
            $h = [PfVolume]::OpenVolume($vol)
            [PfVolume]::LockAndDismount($h)
            $held = $true
            $state = 'заблокирован и отсоединён'
        } catch {
            $e2 = Get-PfErrorInfo $_
            $state = if ($e2.Code) { "код $($e2.Code) ($($e2.Text))" }
                     else { "$($e2.Type): $($e2.Text)" }
        }
        if ($h -and -not $held) { try { $h.Dispose() } catch { }; $h = $null }
        $result += [pscustomobject]@{
            Letter = $name; Path = $vol; Handle = $h; Locked = $held; Detail = $state
        }
    }

    return @($result)
}

# Identity checks are repeated before destructive operations. A failed
# enumeration never establishes that a disk has no partitions.
function Get-PfCrc32 {
    param([byte[]]$Bytes)
    $crc = [uint32]::MaxValue
    $polynomial = [Convert]::ToUInt32('EDB88320', 16)
    foreach ($b in $Bytes) {
        $crc = $crc -bxor $b
        for ($bit = 0; $bit -lt 8; $bit++) {
            if ($crc -band 1) { $crc = ($crc -shr 1) -bxor $polynomial }
            else { $crc = $crc -shr 1 }
        }
    }
    return [uint32]($crc -bxor [uint32]::MaxValue)
}

function Assert-PfGptChecksums {
    param([Parameter(Mandatory = $true)][IO.Stream]$Stream)
    $primary = $null
    foreach ($offset in @(512L, ($Stream.Length - 512))) {
        $header = New-Object byte[] 512
        $Stream.Position = $offset
        if ($Stream.Read($header, 0, 512) -ne 512) { throw 'Incomplete GPT header.' }
        $size = [BitConverter]::ToUInt32($header, 12)
        if ($size -lt 92 -or $size -gt 512) { throw 'Invalid GPT header size.' }
        $expected = [BitConverter]::ToUInt32($header, 16)
        $header[16] = $header[17] = $header[18] = $header[19] = 0
        if ((Get-PfCrc32 -Bytes $header[0..($size - 1)]) -ne $expected) { throw 'GPT header CRC32 mismatch.' }
        $entries = [BitConverter]::ToUInt32($header, 80)
        $entrySize = [BitConverter]::ToUInt32($header, 84)
        $tableSector = [BitConverter]::ToUInt64($header, 72)
        $tableBytes = [long]$entries * $entrySize
        if ($entries -eq 0 -or $entrySize -lt 128 -or ($entrySize -band ($entrySize - 1)) -ne 0 -or
            $tableBytes -gt 16MB -or $tableSector -lt 2 -or
            $tableSector -ge [uint64]($Stream.Length / 512) -or
            $tableBytes -gt ($Stream.Length - 512 - [long]$tableSector * 512)) {
            throw 'Invalid or unsupported GPT partition table bounds.'
        }
        if ($primary) {
            foreach ($field in @(56, 60, 64, 68, 80, 84, 88)) {
                if ([BitConverter]::ToUInt32($header, $field) -ne [BitConverter]::ToUInt32($primary, $field)) {
                    throw 'Primary and backup GPT metadata disagree.'
                }
            }
        } else { $primary = $header }
        $table = New-Object byte[] $tableBytes
        $Stream.Position = [long]$tableSector * 512
        $read = 0
        while ($read -lt $table.Length) {
            $n = $Stream.Read($table, $read, $table.Length - $read)
            if ($n -eq 0) { throw 'Incomplete GPT partition table.' }
            $read += $n
        }
        if ((Get-PfCrc32 -Bytes $table) -ne [BitConverter]::ToUInt32($header, 88)) {
            throw 'GPT partition table CRC32 mismatch.'
        }
    }
}

function Get-PfRelocatedGptHeader {
    param([byte[]]$Header, [long]$ImageBytes, [long]$DiskBytes, [switch]$Backup)
    if ($Header.Length -ne 512 -or $DiskBytes -le $ImageBytes -or
        $ImageBytes % 512 -ne 0 -or $DiskBytes % 512 -ne 0) { throw 'Invalid GPT relocation geometry.' }
    $result = [byte[]]$Header.Clone()
    $delta = [uint64](($DiskBytes - $ImageBytes) / 512)
    $last = [uint64]($DiskBytes / 512 - 1)
    $size = [BitConverter]::ToUInt32($Header, 12)
    if ($size -lt 92 -or $size -gt 512) { throw 'Invalid GPT header size.' }
    if ($Backup) {
        [BitConverter]::GetBytes($last).CopyTo($result, 24)
        [BitConverter]::GetBytes([uint64]([BitConverter]::ToUInt64($Header, 72) + $delta)).CopyTo($result, 72)
    } else { [BitConverter]::GetBytes($last).CopyTo($result, 32) }
    [BitConverter]::GetBytes([uint64]([BitConverter]::ToUInt64($Header, 48) + $delta)).CopyTo($result, 48)
    $result[16] = $result[17] = $result[18] = $result[19] = 0
    [BitConverter]::GetBytes((Get-PfCrc32 -Bytes $result[0..($size - 1)])).CopyTo($result, 16)
    return ,$result
}

function Assert-PfUsbDisk {
    param([int]$Number, [Parameter(Mandatory = $true)]$Identity)
    $disk = Get-Disk -Number $Number -ErrorAction Stop
    if ($disk.IsBoot -or $disk.IsSystem -or [string]$disk.BusType -ne 'USB') {
        throw 'Refusing access to a boot/system or non-USB disk.'
    }
    if (-not $Identity.Path -or [string]$disk.Path -ne $Identity.Path -or
        ([string]$disk.SerialNumber).Trim() -ne $Identity.SerialNumber -or
        [long]$disk.Size -ne $Identity.Size) { throw 'USB disk identity changed. Select and confirm the disk again.' }
    return $disk
}

function Get-PfDiskPartitions {
    param([int]$Number)
    $disk = Get-Disk -Number $Number -ErrorAction Stop
    if ($null -eq $disk.NumberOfPartitions) { throw 'Cannot determine the partition count.' }
    if ($disk.NumberOfPartitions -eq 0) { return }
    $parts = @(Get-Partition -DiskNumber $Number -ErrorAction Stop)
    if ($parts.Count -ne $disk.NumberOfPartitions) { throw 'Partition enumeration is incomplete.' }
    return $parts
}

function Remove-PfDiskLayout {
    param([int]$Number, [Parameter(Mandatory = $true)]$Identity)
    $null = Assert-PfUsbDisk -Number $Number -Identity $Identity
    Add-PfRawDiskNative
    $drive = "\\.\PhysicalDrive$Number"
    $code = [PfRawDisk]::DeleteLayout($drive)
    Write-Host "    IOCTL_DISK_DELETE_DRIVE_LAYOUT: Windows code $code"
    if ($code -ne 0) {
        $null = Assert-PfUsbDisk -Number $Number -Identity $Identity
        $tmp = [IO.Path]::GetTempFileName()
        try {
            Set-Content -LiteralPath $tmp -Value "select disk $Number`r`nclean`r`nexit" -Encoding ASCII
            & diskpart.exe /s $tmp 2>&1 | ForEach-Object { Write-Host "    $_" }
            $diskpartCode = $LASTEXITCODE
            Write-Host "    diskpart exit code: $diskpartCode"
            if ($diskpartCode -ne 0) { throw "diskpart clean failed: $diskpartCode" }
        } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
    $wait = [Diagnostics.Stopwatch]::StartNew()
    do {
        Update-HostStorageCache -ErrorAction Stop
        $disk = Assert-PfUsbDisk -Number $Number -Identity $Identity
        $parts = @(Get-PfDiskPartitions -Number $Number)
        if ($disk.NumberOfPartitions -eq 0 -and $parts.Count -eq 0) { return }
        Start-Sleep -Seconds 1
    } while ($wait.Elapsed.TotalSeconds -lt 15)
    throw 'Partition layout removal could not be verified.'
}

# Снять блокировки томов и вернуть носителю видимость в Проводнике.
function Release-PfVolumeLocks {
    param($Locks)
    foreach ($l in @($Locks)) {
        if ($l -and $l.Handle) {
            try { [PfVolume]::Unlock($l.Handle) } catch { }
            try { $l.Handle.Dispose() } catch { }
        }
    }
    # Refresh: разделы после записи новые, без него том не появится.
    try { Update-HostStorageCache -ErrorAction SilentlyContinue } catch { }
}

# Removing a drive letter does not lock or dismount the volume.
function Remove-PfMountPoint {
    param([Parameter(Mandatory = $true)][string]$Letter)
    & mountvol.exe ($Letter + ':') /D 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# Достать настоящий код Windows из ошибки PowerShell. C# бросает
# Win32Exception, PowerShell заворачивает его в MethodInvocationException,
# а код лежит в NativeErrorCode (НЕ в ErrorCode — это HRESULT).
# Раньше этот обход повторялся в шести местах копипастой.
function Get-PfErrorInfo {
    param([Parameter(Mandatory = $true)]$ErrorRecord)
    $ex = $ErrorRecord.Exception
    while ($ex.InnerException) { $ex = $ex.InnerException }
    $code = 0
    if ($ex.PSObject.Properties['NativeErrorCode']) { $code = [int]$ex.NativeErrorCode }
    return [pscustomobject]@{
        Code = $code
        Text = $ex.Message
        Type = $ex.GetType().Name
    }
}

# Человеческое объяснение кода Win32, чтобы лог был понятен без гугления.
function Get-PfWin32Hint {
    param([Parameter(Mandatory = $true)][int]$Code)
    switch ($Code) {
        5    { return 'Отказано в доступе. Носитель держит другая программа (окно Проводника, антивирус) либо его тома не отпущены. Скрипт уже пробовал снять тома всеми способами — если не помогло, закройте всё, что использует флешку, и повторите.' }
        1    { return 'Запрошенная операция не поддерживается для данного дескриптора. Проверьте путь тома и конкретный вызов; это не доказывает отсутствие поддержки блокировки FAT.' }
        32   { return 'Носитель занят другим процессом. Закройте программы, использующие флешку, и повторите.' }
        3    { return 'Носитель не найден. Проверьте, что флешка вставлена, и запустите стадию 8 заново.' }
        21   { return 'Носитель не готов. Переставьте флешку.' }
        1117 { return 'Ошибка ввода/вывода: носитель отключился или неисправен. Проверьте его в другом порту.' }
        19   { return 'Носитель защищён от записи.' }
        50   { return 'Операция не поддерживается.' }
        87   { return 'Некорректный параметр вызова Windows API.' }
        default { return "Системный код Windows #$Code (см. System Error Codes)." }
    }
}

# Итоговый срез по диску — печатается в лог, если запись не удалась.
function Get-PfDiskReport {
    param([Parameter(Mandatory = $true)][int]$Number)
    $out = @()
    try {
        $d = Get-Disk -Number $Number -ErrorAction Stop
        $out += ('Get-Disk    : Number={0} FriendlyName="{1}" Bus={2} Size={3} IsReadOnly={4} IsOffline={5} PartitionStyle={6}' -f
                 $d.Number, $d.FriendlyName, $d.BusType, $d.Size, $d.IsReadOnly, $d.IsOffline, $d.PartitionStyle)
    } catch { $out += "Get-Disk    : ошибка $($_.Exception.Message)" }
    try {
        foreach ($p in @(Get-Partition -DiskNumber $Number -ErrorAction SilentlyContinue)) {
            # Печатаем и путь тома, а не только букву: пустой DriveLetter
            # означает, что блокировать нечего, и это главная причина отказа.
            $L = ''
            if ($p.DriveLetter) { $L = [string]$p.DriveLetter }
            $vpath = Get-PfVolumePath -Letter $L -DiskNumber $Number -PartitionNumber $p.PartitionNumber
            $out += ('Get-Partition: №{0} Type={1} Size={2} DriveLetter="{3}" VolumePath="{4}" IsReadOnly={5}' -f
                     $p.PartitionNumber, $p.Type, $p.Size, $L, $vpath, $p.IsReadOnly)
        }
    } catch { $out += "Get-Partition: ошибка $($_.Exception.Message)" }
    try {
        $mb = Get-CimInstance -Namespace 'root\Microsoft\Windows\Storage' `
                -ClassName MSFT_Volume -Filter "DriveType=2" -ErrorAction Stop
        $out += "BitLocker  : томов с защитой в списке $($mb.Count)"
    } catch { }
    return $out
}

# ---------------------------------------------------------------------------
# Загрузка текстового файла по HTTP (мелкие .sha512 / .txt). Fallback — curl.
# НИКОГДА не бросает исключение: отсутствие сети/прокси — штатная ситуация,
# а throw здесь ронял всю сборку из-за второстепенной проверки. Возвращает ''
# и печатает причину, вызывающий решает сам (обычно: «сервер недоступен»).
# ---------------------------------------------------------------------------
function Get-PfRemoteText {
    param(
        [string]$Url,
        [int]$TimeoutSec = 30
    )
    # Сначала curl: на части учебных ПК Invoke-WebRequest отдаёт HTML-заглушку
    # (прокси/ captive portal) вместо файла, и хеш потом не находится.
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        $tmp = [System.IO.Path]::GetTempFileName()
        try {
            $code = & $curl.Source -sL --fail --max-time $TimeoutSec -o $tmp -w '%{http_code}' $Url
            if ($LASTEXITCODE -eq 0 -and $code -eq '200') {
                return (Get-Content $tmp -Raw -ErrorAction SilentlyContinue)
            }
            $why = "curl: код HTTP '$code', код возврата $LASTEXITCODE"
        } catch {
            $why = "curl: $($_.Exception.Message)"
        } finally {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    } else {
        $why = 'curl.exe не найден в системе'
    }

    try {
        return (Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec).Content
    } catch {
        # Внимание: двоеточие сразу после знака доллара и имени переменной —
        # недопустимая ссылка (нужен ${Url} в фигурных скобках). Раньше именно
        # эта строка падала вместо внятного сообщения о недоступности сети.
        $why2 = ($_.Exception.Message -split "`n")[0]
        Write-Host "  [!] Не удалось получить ${Url}: $why; Invoke-WebRequest: $why2" -ForegroundColor DarkYellow
        return ''
    }
}

# Ожидаемая SHA-512 из файла "<файл>.sha512" (формат: <hash>  <имя>)
function Get-PfRemoteSha512 {
    param(
        [string]$Url,
        [int]$TimeoutSec = 30
    )
    # НЕ бросаем исключение: отсутствие опубликованной суммы — штатная ситуация,
    # а throw здесь превращался в пугающую "TerminatingError" в build.log.
    $txt = ''
    try { $txt = [string](Get-PfRemoteText -Url $Url -TimeoutSec $TimeoutSec) } catch { return '' }
    $m = [regex]::Match($txt, '(?i)([0-9a-f]{128})')
    if (-not $m.Success) {
        # Показываем, что реально пришло, — иначе причину невозможно понять.
        $head = ($txt -replace '\s+', ' ').Trim()
        if ($head.Length -gt 100) { $head = $head.Substring(0, 100) + '...' }
        Write-Host "  [i] В ответе $Url нет хеша SHA-512; пришло: '$head'" -ForegroundColor DarkGray
        return ''
    }
    return $m.Groups[1].Value.ToUpper()
}

# ---------------------------------------------------------------------------
# Актуальный установщик QEMU для Windows.
# Имя файла содержит дату и меняется с каждым релизом, а в корне каталога
# сервер держит только несколько последних сборок (остальные уходят в
# подпапки по годам) — поэтому ищем последнюю доступную сами:
# корень индекса, затем годовые подпапки; каждый кандидат проверяем HEAD.
# Возвращает объект {Url, FileName, Date, Sha512Url}.
# ---------------------------------------------------------------------------
function Get-PfQemuInstallerUrl {
    param(
        [string]$IndexUrl = 'https://qemu.weilnetz.de/w64/',
        [int]$TimeoutSec = 30,
        [int]$MaxProbes = 20
    )
    $base = $IndexUrl.TrimEnd('/')
    $pattern = 'qemu-w64-setup-(\d{8})\.exe'

    # каталоги по убыванию «свежести»: корень (там последние сборки), затем годы
    $dirs = @($base)
    $thisYear = (Get-Date).Year
    for ($y = $thisYear; $y -ge ($thisYear - 3); $y--) { $dirs += "$base/$y" }

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    $probed = 0
    $newest = $null
    $anyIndex = $false

    foreach ($dir in $dirs) {
        if ($probed -ge $MaxProbes) { break }
        $html = ''
        try { $html = [string](Get-PfRemoteText -Url ($dir + '/') -TimeoutSec $TimeoutSec) } catch { $html = '' }
        if (-not $html) { continue }
        $anyIndex = $true

        $stamps = @([regex]::Matches($html, $pattern) | ForEach-Object { $_.Groups[1].Value } |
            Sort-Object -Descending -Unique)
        foreach ($stamp in $stamps) {
            if ($probed -ge $MaxProbes) { break }
            $cand = [pscustomobject]@{
                Url      = "$dir/qemu-w64-setup-$stamp.exe"
                FileName = "qemu-w64-setup-$stamp.exe"
                Date     = $stamp
            }
            if (-not $newest -or $stamp -gt $newest.Date) { $newest = $cand }

            $ok = $false
            if ($curl) {
                $code = & $curl.Source -sI -L -o NUL -w '%{http_code}' --max-time $TimeoutSec $cand.Url
                $ok = ($LASTEXITCODE -eq 0 -and $code -eq '200')
            } else {
                try {
                    $req = [System.Net.HttpWebRequest]::Create($cand.Url)
                    $req.Method = 'HEAD'
                    $req.Timeout = $TimeoutSec * 1000
                    $resp = $req.GetResponse()
                    $ok = ([int]$resp.StatusCode -eq 200)
                    $resp.Close()
                } catch { $ok = $false }
            }
            $probed++
            if ($ok) {
                Add-Member -InputObject $cand -NotePropertyName Sha512Url `
                           -NotePropertyValue ($cand.Url -replace '\.exe$', '.sha512') -Force
                return $cand
            }
        }
    }

    $hint = if ($anyIndex) {
        "Последняя сборка в индексе: $($newest.Url)"
    } else {
        "Индекс $base недоступен (нет сети или прокси)."
    }
    throw ("Не удалось получить установщик QEMU (проверено ссылок: {0})." -f $probed +
           "`n$hint" +
           "`nСкачайте установщик вручную с $base, переименуйте в qemu-installer.exe" +
           "`nи положите рядом с папкой win\, затем запустите build-all.bat -FromStage 1." +
           "`nЛибо укажите адрес явно: build-all.bat -QemuUrl <url>.")
}

# ---------------------------------------------------------------------------
# Загрузка с докачкой (curl -C -) и проверка SHA256/SHA-512. Fallback — BITS.
# ---------------------------------------------------------------------------
function Resume-PfDownload {
    param(
        [string]$Url,
        [string]$OutFile,
        [string]$ExpectedSha = '',
        [string]$ExpectedSha512 = ''
    )
    $d = Split-Path $OutFile -Parent
    if (-not (Test-Path $d)) { $d = $PSScriptRoot }
    $free = (Get-Item $d).PSDrive.Free
    if ($null -eq $free) { $free = 0 }
    Write-PfHeader 'Загрузка'
    Write-Host "  URL : $Url"
    Write-Host "  Файл: $OutFile"
    if ($free -lt 1GB) { Write-Host '  [!] Мало свободного места на диске.' -ForegroundColor Yellow }

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        # Запускаем curl фоном и сами следим за размером файла: так виден
        # прогресс (а на 2.6-ГБ ISO молчание длится минутами).
        $errFile = "$OutFile.curlerr.txt"
        $cargs = @('-L', '-C', '-', '--retry', '3', '--retry-delay', '2',
                   '--connect-timeout', '30', '--speed-time', '60', '--speed-limit', '1024',
                   '--fail', '--silent', '--show-error', '-o', $OutFile, $Url)

        # Попытки с докачкой: -C - продолжает с места обрыва.
        $attempts = 3
        $code = 0
        for ($try = 1; $try -le $attempts; $try++) {
            if (Test-Path $errFile) { Remove-Item $errFile -Force }
            $mb0 = 0
            if (Test-Path $OutFile) { $mb0 = [int]((Get-Item $OutFile).Length / 1MB) }
            if ($try -gt 1) { Write-Host ("  Попытка {0}/{1}, продолжаю с {2} МБ..." -f $try, $attempts, $mb0) -ForegroundColor Yellow }

            $cp = Start-Process -FilePath $curl.Source -ArgumentList $cargs `
                   -WindowStyle Hidden -PassThru -RedirectStandardError $errFile
            $null = $cp.Handle   # без этого ExitCode после выхода бывает $null (баг PS 5.1)

            $lastMb = -1
            while (-not $cp.HasExited) {
                Start-Sleep -Seconds 3
                if (Test-Path $OutFile) {
                    $mb = [int]((Get-Item $OutFile).Length / 1MB)
                    if ($mb -ne $lastMb) {
                        $lastMb = $mb
                        Write-Host ("  ... скачано {0} МБ" -f $mb) -ForegroundColor DarkCyan
                    }
                }
            }
            $cp.WaitForExit()
            $code = $cp.ExitCode
            # $null == 0: у Start-Process -PassThru в PS 5.1 код мог не читаться,
            # и "$null -ne 0" давал ложную ошибку на успешно скачанном файле.
            $why = ''
            if (Test-Path $errFile) { $why = (Format-PfLogLine -Text (Get-Content $errFile -Raw) -MaxLen 300) }
            if ($null -eq $code) { $code = 0 }
            $mbNow = 0
            if (Test-Path $OutFile) { $mbNow = [int]((Get-Item $OutFile).Length / 1MB) }
            # Код 0, но файл не появился/пуст — явно считаем провалом и докачиваем.
            if (($code -eq 0) -and ($mbNow -eq 0)) { $code = 1; $why = 'curl завершился с кодом 0, но файл пуст' }

            if ($code -eq 0) {
                Write-Host ("  [OK] Скачано {0} МБ{1}" -f $mbNow, $(if ($why) { " (замечание curl: $why)" } else { '' })) -ForegroundColor Green
                break
            }
            if ($try -lt $attempts) {
                Write-Host ("  [!] curl: код {0}{1} — докачиваю" -f $code, $(if ($why) { ": $why" } else { '' })) -ForegroundColor Yellow
                Start-Sleep -Seconds 3
            }
        }
        if ($code -ne 0) {
            throw "Скачивание не удалось (curl, код $code) после $attempts попыток: $Url`n$why"
        }
    } else {
        Import-Module BitsTransfer -ErrorAction SilentlyContinue
        Start-BitsTransfer -Source $Url -Destination $OutFile -ErrorAction Stop
    }

    if ($ExpectedSha) {
        $h = (Get-FileHash $OutFile -Algorithm SHA256).Hash
        if ($h -ne $ExpectedSha.ToUpper()) {
            throw "Контрольная сумма не совпадает: $h`nОжидалось: $($ExpectedSha.ToUpper()). Файл повреждён — удалите его и повторите."
        }
        Write-Host "  [OK] SHA256 совпадает: $h" -ForegroundColor Green
    }
    if ($ExpectedSha512) {
        $h5 = (Get-FileHash $OutFile -Algorithm SHA512).Hash
        if ($h5 -ne $ExpectedSha512.ToUpper()) {
            Remove-Item $OutFile -Force
            throw "Контрольная сумма SHA-512 не совпадает: $h5`nОжидалось: $($ExpectedSha512.ToUpper()). Битый файл удалён — повторите загрузку."
        }
        Write-Host '  [OK] SHA-512 совпадает' -ForegroundColor Green
    }
    Write-Host '  [ГОТОВО] Файл загружен.' -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Конвертация qcow2 -> raw (результат сборки; сам raw нужен для записи на USB).
# ---------------------------------------------------------------------------
function Convert-PfQcow2ToRaw {
    param([string]$QemuImg, [string]$QcowPath, [string]$RawPath)
    if (-not $QemuImg) { throw 'qemu-img.exe не найден.' }
    if (-not (Test-Path $QcowPath)) { throw "Нет установленного образа: $QcowPath" }
    if (Test-Path $RawPath) {
        Write-Host "[!] $RawPath уже существует. Перезаписываем..." -ForegroundColor Yellow
        Remove-Item $RawPath -Force
    }
    & $QemuImg convert -p -f qcow2 -O raw $QcowPath $RawPath
    if ($LASTEXITCODE -ne 0) { throw 'Конвертация QCOW2 -> RAW не удалась.' }
}

# ---------------------------------------------------------------------------
# Права администратора
# ---------------------------------------------------------------------------
function Test-PfIsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------------------
# Нормализация аргументов командной строки для Start-Process -ArgumentList.
#
# Зачем это нужно (три проверенные на живой Windows ошибки):
#  1) Вложенный массив: PS 5.1 не принимает Object[] внутри списка аргументов —
#     "Cannot convert 'System.Object[]' to the type 'System.String' required by
#     parameter 'ArgumentList'". Такое даёт, например, $boot.Kernel, если
#     Get-PfIsoBootFiles вернул не один объект.
#  2) Пробел по краям элемента: QEMU ищет файл ядра с именем " E:\...vmlinuz"
#     и не находит его. Раньше склейка строк добавляла такой пробел.
#  3) Пробел ВНУТРИ элемента: PS 5.1 соединяет элементы массива пробелами и НЕ
#     ставит кавычки. Без них "-append autoinstall ds=nocloud fsck.mode=skip"
#     распадается на 6 отдельных аргументов, и QEMU не понимает -append.
#     Поэтому элементы с пробелами берём в кавычки САМИ.
#
# ВНИМАНИЕ: только для Start-Process -ArgumentList. Для оператора "&" массив
# передаётся как есть, и добавленные кавычки стали бы частью пути.
# ---------------------------------------------------------------------------
function ConvertTo-PfArgumentList {
    param(
        [object[]]$Arguments,
        [string]$What = 'процесса'
    )
    if (-not $Arguments) { return [string[]]@() }

    $flat = New-Object System.Collections.Generic.List[string]
    foreach ($a in $Arguments) {
        if ($null -eq $a) { continue }
        if ($a -is [string]) { $flat.Add($a); continue }
        if ($a -is [System.Collections.IEnumerable]) {
            foreach ($x in $a) { if ($null -ne $x) { $flat.Add([string]$x) } }
            continue
        }
        $flat.Add([string]$a)
    }

    $out = New-Object System.Collections.Generic.List[string]
    foreach ($s in $flat) {
        $t = $s.Trim()
        if ($t -eq '') { continue }
        if ($t -match '[\s"]') { $t = '"' + $t + '"' }
        $out.Add($t)
    }
    if ($out.Count -eq 0) { throw "Список аргументов для $What пуст после нормализации." }
    return [string[]]$out.ToArray()
}

# Показать команду в логе. Работает по уже нормализованному списку, поэтому
# напечатанное совпадает с тем, что реально получает процесс.
function Join-PfArguments {
    param([string[]]$Arguments)
    if (-not $Arguments) { return '' }
    return ($Arguments -join ' ')
}

# Перезапуск команды с правами администратора (UAC). Возвращает ExitCode
# запущенного процесса; при отказе UAC бросает исключение.
function Invoke-PfElevated {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [string]$WorkDir = ''
    )
    # Именно МАССИВ, не строка: у склеенной строки PS 5.1 добавляет внешние
    # кавычки, и путь с пробелами доезжает до процесса с лишними кавычками.
    $args = ConvertTo-PfArgumentList -Arguments $ArgumentList -What "'$FilePath' (с правами администратора)"
    $p = Start-Process -FilePath $FilePath -ArgumentList $args -WorkingDirectory $WorkDir `
        -Verb RunAs -Wait -PassThru -ErrorAction Stop
    return $p.ExitCode
}

# ---------------------------------------------------------------------------
# Заголовок
# ---------------------------------------------------------------------------
function Write-PfHeader {
    param([string]$Title)
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " $Title" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
}
