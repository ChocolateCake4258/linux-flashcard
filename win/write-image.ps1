# write-image.ps1 — безопасная запись RAW-образа «два тома, одна система» на USB.
# Требует прав администратора. Запускается ДОМА (на учебных ПК прав нет).
# Поддерживает прежний RAW и новый NTFS/Ventoy factory image с готовым payload.
# Побайтовый перенос образа -> \\.\PhysicalDriveN; factory проверяет тело до GPT.
#
# С ResultPath отдельный лог хранится рядом с receipt, иначе — в корне проекта.
# Раньше
# build-all.ps1 запускал этот файл через Start-Process -Verb RunAs, и при ошибке
# вывод уходил в отдельное окно, которое тут же закрывалось. Родительский
# процесс видел только ненулевой код выхода, а текст ошибки пропадал.

param(
    [string]$ImagePath = '',
    [int]$DiskNumber = -1,   # физический номер носителя (необязательно; иначе — выбор из меню)
    [string]$DiskPath = '',  # альтернатива: прямое имя \\.\PhysicalDriveN
    [switch]$Yes,
    [string]$ExpectedDevicePath = '',
    [string]$ExpectedSerialNumber = '',
    [long]$ExpectedSize = 0,
    [switch]$VerifyFull,
    [switch]$VerifyOnly,
    [switch]$AllowGptRelocation,
    [string]$ExpectedCurrentImagePath = '',
    [switch]$DeferPartitionTable,
    [switch]$VerifyBeforePublish,
    [string]$ResultPath = ''
)
# Русский вывод в консоли: принудительно UTF-8. Иначе Windows PowerShell 5.1
# печатает кириллицу в текущей кодовой странице как «кракозябры».
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8; $OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\lib\pf-tools.psm1"
. (Join-Path $PSScriptRoot 'lib\pf-deferred-write.ps1')

$RepoRoot = Split-Path $PSScriptRoot -Parent
if (-not $ImagePath) { $ImagePath = Join-Path $RepoRoot 'virtual-disk.img' }
$WriteLog = if($ResultPath){[IO.Path]::ChangeExtension([IO.Path]::GetFullPath($ResultPath),'.log')}else{Join-Path $RepoRoot $(if ($VerifyOnly) { 'write-image-verify.log' } else { 'write-image.log' })}

# Лог включаем ДО любых проверок, чтобы в него попали и сообщения об ошибках.
$LogOn = $false
try {
    if(-not $ResultPath){Start-Transcript -Path $WriteLog -Force | Out-Null;$LogOn = $true}
} catch {
    Write-Host "[i] Не смог включить $WriteLog : $($_.Exception.Message)" -ForegroundColor Yellow
}

$code = 0
$src = $null
$currentImage = $null
$handle = $null
$locks = @()
$deferredVerified = 0L
$writeFailure = $null
$resultAllowed = $false
$writerMutex = $null
$writerMutexHeld = $false
$validatedSourceSha256 = $null

function Confirm-PfDeferredSpan {
    param([IO.Stream]$Source,$ReadHandle,[long]$Offset,[long]$Length)
    $blockSha=[Security.Cryptography.SHA256]::Create()
    $expected=New-Object byte[] (4MB);$actual=New-Object byte[] (4MB)
    $position=$Offset;$end=$Offset+$Length;$reportAt=$Offset+2GB
    try{
        while($position -lt $end){
            $chunk=[int][Math]::Min([long]$expected.Length,[long]($end-$position))
            if($chunk -ne $expected.Length){$expected=New-Object byte[] $chunk;$actual=New-Object byte[] $chunk}
            $Source.Position=$position;$loaded=0
            while($loaded -lt $chunk){$n=$Source.Read($expected,$loaded,$chunk-$loaded);if($n -le 0){throw 'Source EOF during deferred verification.'};$loaded+=$n}
            $got=Read-PfRawBytes -Handle $ReadHandle -Bytes $actual -Offset $position
            if($got -ne $chunk -or [Convert]::ToBase64String($blockSha.ComputeHash($expected)) -cne [Convert]::ToBase64String($blockSha.ComputeHash($actual))){
                throw "Deferred read-back mismatch at byte $position (read $got of $chunk)."
            }
            $position+=$chunk
            if($position -ge $reportAt -or $position -eq $end){Write-Host ('    read-back: {0:N2} / {1:N2} GiB' -f (($position-$Offset)/1GB),($Length/1GB));$reportAt=$position+2GB}
        }
    }finally{$blockSha.Dispose()}
    return $Length
}

try {
    Write-Host "Лог записи: $WriteLog" -ForegroundColor DarkGray
    Write-Host "Запущен с ключами: -Yes=$Yes -DiskNumber=$DiskNumber -ImagePath=$ImagePath" -ForegroundColor DarkGray

    if (-not (Test-Path $ImagePath)) { throw "RAW-образ не найден: $ImagePath`nСначала выполните convert-disk.bat (стадия 7)." }
    if (-not (Test-PfIsAdmin)) {
        throw 'Запись на физический диск требует прав администратора. Запустите PowerShell от имени администратора.'
    }
    if ($AllowGptRelocation -and -not $VerifyOnly) { throw '-AllowGptRelocation is only supported with -VerifyOnly.' }
    if ($ExpectedCurrentImagePath -and $VerifyOnly) { throw '-ExpectedCurrentImagePath is only supported for writing.' }
    if ($DeferPartitionTable -and ($VerifyOnly -or $ExpectedCurrentImagePath)) { throw '-DeferPartitionTable is an explicit layout-clearing write mode; it cannot be combined with guarded rewriting or verify-only.' }
    if ($VerifyBeforePublish -and (-not $DeferPartitionTable -or -not $VerifyFull -or $VerifyOnly)) { throw '-VerifyBeforePublish requires -DeferPartitionTable and -VerifyFull for a new whole-disk write.' }
    if ($DiskPath) {
        if ($DiskPath -notmatch '^\\\\\.\\PhysicalDrive(\d+)$') { throw 'Invalid physical disk path.' }
        $pathNumber = [int]$Matches[1]
        if ($DiskNumber -ge 0 -and $DiskNumber -ne $pathNumber) { throw 'DiskPath and DiskNumber disagree.' }
        $DiskNumber = $pathNumber
    }
    $ImagePath = (Resolve-Path -LiteralPath $ImagePath -ErrorAction Stop).ProviderPath
    $src = [IO.File]::OpenRead($ImagePath)
    if ($ExpectedCurrentImagePath) {
        $ExpectedCurrentImagePath = (Resolve-Path -LiteralPath $ExpectedCurrentImagePath -ErrorAction Stop).ProviderPath
        $currentItem = Get-Item -LiteralPath $ExpectedCurrentImagePath -ErrorAction Stop
        if ($currentItem -isnot [IO.FileInfo] -or ($currentItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Expected current image must be a regular file.'
        }
        $currentImage = [IO.File]::Open($ExpectedCurrentImagePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    }
    $imageSize = $src.Length
    if ($imageSize -lt 8MB -or $imageSize % 512 -ne 0) { throw 'RAW image size must be at least 8 MB and sector-aligned.' }
    $header = New-Object byte[] 1024
    if ($src.Read($header, 0, $header.Length) -ne $header.Length -or
        $header[510] -ne 0x55 -or $header[511] -ne 0xAA -or
        [Text.Encoding]::ASCII.GetString($header, 512, 8) -ne 'EFI PART') {
        throw 'Expected a complete GPT disk image, not a partition image.'
    }
    $lastSector = [uint64]($imageSize / 512 - 1)
    if ([BitConverter]::ToUInt32($header, 524) -lt 92 -or
        [BitConverter]::ToUInt32($header, 524) -gt 512 -or
        [BitConverter]::ToUInt64($header, 536) -ne 1 -or
        [BitConverter]::ToUInt64($header, 544) -ne $lastSector) {
        throw 'GPT header does not describe this image size; the image may be incomplete.'
    }
    $backup = New-Object byte[] 512
    $src.Position = $imageSize - 512
    if ($src.Read($backup, 0, 512) -ne 512 -or
        [Text.Encoding]::ASCII.GetString($backup, 0, 8) -ne 'EFI PART' -or
        [BitConverter]::ToUInt64($backup, 24) -ne $lastSector -or
        [BitConverter]::ToUInt64($backup, 32) -ne 1) {
        throw 'Backup GPT header is missing or inconsistent; USB has not been modified.'
    }
    Assert-PfGptChecksums -Stream $src
    $hashPath = $ImagePath + '.sha256'
    if (Test-Path -LiteralPath $hashPath) {
        $expectedHash = (Get-Content -LiteralPath $hashPath -Raw).Trim()
        if ($expectedHash -notmatch '^[0-9a-fA-F]{64}$') { throw 'Invalid SHA256 sidecar.' }
        $hash = [Security.Cryptography.SHA256]::Create()
        try {
            $src.Position = 0
            $hashBuffer = New-Object byte[] (4MB)
            while (($hashRead = $src.Read($hashBuffer, 0, $hashBuffer.Length)) -gt 0) {
                $null = $hash.TransformBlock($hashBuffer, 0, $hashRead, $hashBuffer, 0)
            }
            $null = $hash.TransformFinalBlock($hashBuffer, 0, 0)
            $actualHash = [BitConverter]::ToString($hash.Hash).Replace('-', '')
            if ($actualHash -ne $expectedHash) { throw 'RAW image SHA256 does not match. USB has not been modified.' }
            $validatedSourceSha256=$actualHash
        } finally { $hash.Dispose() }
    }
    $src.Position = 0

    Write-PfHeader 'Запись образа на USB-накопитель'

    # ---- список съёмных дисков ----
    $disks = @(Get-CimInstance Win32_DiskDrive | Where-Object { $_.InterfaceType -eq 'USB' })
    if (-not $disks) {
        throw 'USB-диски не найдены. Подключите флешку и повторите.'
    }
    Write-Host 'Найденные USB-накопители:'
    for ($i = 0; $i -lt $disks.Count; $i++) {
        $d = $disks[$i]
        Write-Host ("  [{0}] Disk {1}: {2}  {3} ГБ" -f $i, $d.Index, $d.Model, [Math]::Round($d.Size/1GB,1))
    }

    if ($DiskNumber -lt 0) {
        if ($Yes) { throw 'Указан ключ -Yes, но номер диска не передан: указывать цель небезопасно. Запустите build-all.ps1 или выберите диск вручную.' }
        $sel = Read-Host 'Введите номер [0..] и нажмите Enter'
        $sel = [int]$sel; if ($sel -lt 0 -or $sel -ge $disks.Count) { throw 'Неверный выбор' }
        $target = $disks[$sel]
    } else {
        $target = $disks | Where-Object { $_.Index -eq $DiskNumber } | Select-Object -First 1
        if (-not $target) { throw "Диск с номером $DiskNumber не найден среди USB-накопителей." }
    }
    $Drive = "\\.\PhysicalDrive$($target.Index)"

    $disk = Get-Disk -Number $target.Index -ErrorAction Stop
    if ($Yes -and (-not $ExpectedDevicePath -or $ExpectedSize -le 0)) {
        throw '-Yes requires the device identity from the confirmation window.'
    }
    $identity = [pscustomobject]@{
        Path = [string]$disk.Path
        SerialNumber = ([string]$disk.SerialNumber).Trim()
        Size = [long]$disk.Size
    }
    if (($ExpectedDevicePath -and $identity.Path -ne $ExpectedDevicePath) -or
        ($ExpectedSize -gt 0 -and $identity.Size -ne $ExpectedSize) -or
        ($ExpectedSerialNumber -and $identity.SerialNumber -ne $ExpectedSerialNumber.Trim())) {
        throw 'USB disk changed after confirmation. Select and confirm it again.'
    }
    $disk = Assert-PfUsbDisk -Number $target.Index -Identity $identity
    $mutexSha=[Security.Cryptography.SHA256]::Create()
    try{$mutexKey=[BitConverter]::ToString($mutexSha.ComputeHash([Text.Encoding]::UTF8.GetBytes($identity.Path.ToUpperInvariant()))).Replace('-','')}finally{$mutexSha.Dispose()}
    $writerMutex=[Threading.Mutex]::new($false,('Global\LinuxFlashcard-Writer-'+$mutexKey))
    try{$writerMutexHeld=$writerMutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$writerMutexHeld=$true}
    if(-not $writerMutexHeld){throw 'Another writer owns this USB device.'}
    if($VerifyBeforePublish -and $imageSize -ne $identity.Size){throw 'Deferred publication verification requires an image built for the exact target capacity.'}
    if($ResultPath){
        $ResultPath=[IO.Path]::GetFullPath($ResultPath)
        $resultParent=Get-Item -LiteralPath (Split-Path ([IO.Path]::GetFullPath($ResultPath)) -Parent) -Force -ErrorAction Stop
        for($directory=$resultParent;$directory;$directory=$directory.Parent){if($directory.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Redirected writer result directories are not supported.'}}
        if(Test-Path -LiteralPath $ResultPath){throw 'Writer receipt already exists; use a new attempt filename.'}
        if($resultParent.FullName -match '^([A-Za-z]):\\'){
            if(@(Get-Partition -DriveLetter $Matches[1]|Where-Object{$_.DiskNumber -eq $target.Index}).Count){throw 'Writer result must be stored off the target USB.'}
        }
        $resultAllowed=$true
        try{Start-Transcript -LiteralPath $WriteLog -NoClobber|Out-Null;$LogOn=$true}catch{Write-Host ('Cannot start writer transcript: '+$_.Exception.Message) -ForegroundColor Yellow}
    }
    if ($currentImage -and $currentImage.Length -ne $identity.Size) { throw 'Expected current image length must equal the saved target disk size.' }
    if ($disk.LogicalSectorSize -ne 512) { throw 'This GPT image requires a USB disk with 512-byte logical sectors.' }
    $sourcePaths = @($ImagePath, $RepoRoot)
    if ($currentImage) { $sourcePaths += $ExpectedCurrentImagePath }
    foreach ($path in $sourcePaths) {
        $item = Get-Item -LiteralPath $path -ErrorAction Stop
        $directory = if ($item.PSIsContainer) { $item } else { $item.Directory }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Redirected source paths are not supported.' }
        while ($directory) {
            if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Redirected source paths are not supported.' }
            $directory = $directory.Parent
        }
        $root = [IO.Path]::GetPathRoot($path)
        if ($root -match '^([A-Za-z]):') {
            $sourceParts = @(Get-Partition -DriveLetter $Matches[1] -ErrorAction Stop)
            if (@($sourceParts | Where-Object { $_.DiskNumber -eq $target.Index }).Count) {
                throw 'The source image or running project is on the destination disk.'
            }
        }
    }
    Write-Host ''
    Write-Host "  Образ : $ImagePath  ($([Math]::Round($imageSize/1GB,1)) ГБ, $imageSize байт)"
    Write-Host "  Цель  : $Drive  ($($target.Model),  $([Math]::Round($identity.Size/1GB,1)) ГБ, $($identity.Size) байт)"
    if ($imageSize -gt $identity.Size) {
        throw ("Образ ($imageSize байт) больше флешки ($($target.Size) байт) — не влезет.`n" +
               "Нужен носитель объёмом не меньше $([Math]::Ceiling($imageSize/1GB)) ГБ.")
    }

    Write-Host ''
    if ($VerifyOnly) {
        Write-Host 'Проверка чтением: запись образа и удаление разметки отключены.' -ForegroundColor Cyan
    } elseif (-not $Yes) {
        Write-Host 'ВСЕ ДАННЫЕ НА ФЛЕШКЕ БУДУТ УНИЧТОЖЕНЫ!' -ForegroundColor Red
        $ans = Read-Host "Наберите yes для подтверждения записи на $Drive"
        if ($ans -ne 'yes') { Write-Host 'Отменено пользователем.'; $code = 0; return }
    } else {
        Write-Host 'ВНИМАНИЕ: ВСЕ ДАННЫЕ НА ФЛЕШКЕ БУДУТ УНИЧТОЖЕНЫ (подтверждено вводом yes в вызывающем окне).' -ForegroundColor Red
    }

    $disk = Assert-PfUsbDisk -Number $target.Index -Identity $identity
    if ($disk.IsReadOnly -or $disk.IsOffline) { throw 'Target is read-only or offline. Its protection flags were not changed.' }

    # ---- подготовка носителя и запись: каскад способов ----
    #
    # Keep volume locks throughout writing. If that is unavailable, remove
    # the layout and verify the disk is unpartitioned before opening it.
    $ModeNames = @(
        'блокировка томов (FSCTL_LOCK_VOLUME + DISMOUNT)',
        'удаление разметки (IOCTL_DISK_DELETE_DRIVE_LAYOUT / diskpart clean)'
    )
    $MaxMode = $ModeNames.Count
    if ($currentImage) { $MaxMode = 1 }
    if ($VerifyOnly) { $MaxMode = 0 }
    $buf = New-Object byte[] (4*1024*1024)
    $handle = $null
    $locks = @()
    $total = 0
    $writeCode = 0
    $done = [bool]$VerifyOnly
    $tried = 0
    $lastWhy = 'причина не установлена'

    $firstMode = if ($DeferPartitionTable) { 2 } else { 1 }
    for ($pass = $firstMode; $pass -le $MaxMode; $pass++) {
        $tried = $pass
        Write-Host ''
        Write-Host ("  Способ {0} из {1}: {2}" -f $pass, $MaxMode, $ModeNames[$pass-1]) -ForegroundColor Cyan
        if ($pass -gt 1) {
            # Дескрипторы прошлого способа освобождаем ДО новой подготовки.
            # Прежде просто перезаписывался $locks, и старые блокировки
            # утекали, продолжая держать носитель.
            if ($handle) { try { $handle.Dispose() } catch { }; $handle = $null }
            if ($locks.Count) { Release-PfVolumeLocks -Locks $locks; $locks = @() }
        }

        $openPath = $Drive
        $why = ''
        $null = Assert-PfUsbDisk -Number $target.Index -Identity $identity
        $parts = @(Get-PfDiskPartitions -Number $target.Index)
        if ($parts.Count -eq 0) { Write-Host '    разделов на носителе нет (чистый носитель) — продолжаю.' -ForegroundColor DarkGray }

        switch ($pass) {
            1 {
                $locks = @(Lock-PfDiskVolumes -Number $target.Index -Drive $Drive)
                foreach ($l in $locks) {
                    if ($l.Locked) { Write-Host "    том $($l.Letter) [$($l.Path)]: $($l.Detail)" -ForegroundColor DarkGray }
                    else { Write-Host "    том $($l.Letter) [$($l.Path)]: НЕ удержан — $($l.Detail)" -ForegroundColor DarkYellow }
                }
                $heldCount = @($locks | Where-Object { $_.Locked }).Count
                if ($heldCount -ne $locks.Count) { $why = 'Не все тома заблокированы.' }
            }
            2 {
                Write-Host '    сбрасываю разметку: носитель станет нераспределённым' -ForegroundColor Yellow
                if($VerifyBeforePublish){$layoutInitialization=Initialize-PfDeferredDiskLayout -Number $target.Index -Identity $identity}
                else{Remove-PfDiskLayout -Number $target.Index -Identity $identity}
            }
        }

        # Guarded rewrites never delete layout, and compare only while all locks are held.
        if ($currentImage) {
            if ($why) { throw 'Cannot exclusively lock volumes for expected current image check.' }
            $currentRead = $null
            $currentSha = [Security.Cryptography.SHA256]::Create()
            try {
                $null = Assert-PfUsbDisk -Number $target.Index -Identity $identity
                $currentRead = Open-PfRawDisk -Drive $Drive -Access 'Read'
                $currentOffset = 0L
                $currentImage.Position = 0
                $expectedBytes = New-Object byte[] (4MB)
                $currentBytes = New-Object byte[] (4MB)
                while ($currentOffset -lt $identity.Size) {
                    $currentCount = [int][Math]::Min([long]4MB, [long]($identity.Size - $currentOffset))
                    if ($currentCount -ne $currentBytes.Length) {
                        $expectedBytes = New-Object byte[] $currentCount
                        $currentBytes = New-Object byte[] $currentCount
                    }
                    $currentGot = Read-PfRawBytes -Handle $currentRead -Bytes $currentBytes -Offset $currentOffset
                    if ($currentGot -ne $currentCount) { throw "Short current disk read at byte $currentOffset (read $currentGot of $currentCount)." }
                    $currentLoaded = 0
                    while ($currentLoaded -lt $currentCount) {
                        $n = $currentImage.Read($expectedBytes, $currentLoaded, $currentCount - $currentLoaded)
                        if ($n -eq 0) { throw 'Unexpected end of expected current image.' }
                        $currentLoaded += $n
                    }
                    if ([BitConverter]::ToString($currentSha.ComputeHash($expectedBytes)) -ne
                        [BitConverter]::ToString($currentSha.ComputeHash($currentBytes))) {
                        throw "Expected current image mismatch at byte $currentOffset. USB has not been modified."
                    }
                    $currentOffset += [long]$currentCount
                }
            } finally {
                try { if ($currentRead) { $currentRead.Dispose() } }
                finally { $currentSha.Dispose() }
            }
        }

        # ---- открытие носителя с повторами ----
        if (-not $why) {
            $openWhy = ''
            for ($attempt = 1; $attempt -le 4 -and -not $handle; $attempt++) {
                if ($attempt -gt 1) {
                    Start-Sleep -Seconds 2
                    Write-Host "    повтор открытия $attempt из 4" -ForegroundColor DarkGray
                }
                try {
                    $null = Assert-PfUsbDisk -Number $target.Index -Identity $identity
                    $handle = Open-PfRawDisk -Drive $openPath -Access 'Write'
                } catch {
                    $e = Get-PfErrorInfo $_
                    if ($e.Code) {
                        $openWhy = "код Windows $($e.Code) — $(Get-PfWin32Hint -Code $e.Code)"
                        Write-Host "    не открылось: $($e.Text)" -ForegroundColor DarkYellow
                        Write-Host "      $openWhy" -ForegroundColor DarkYellow
                    } else {
                        $openWhy = "$($e.Type): $($e.Text)"
                        Write-Host "    не открылось: $openWhy" -ForegroundColor DarkYellow
                    }
                    $handle = $null
                }
            }
            if (-not $handle) { $why = if ($openWhy) { $openWhy } else { 'носитель не открылся' } }
        }
        if ($why) {
            $lastWhy = $why
            Write-Host "    способ не подошёл: $why" -ForegroundColor DarkYellow
            continue
        }
        Write-Host "  Носитель открыт на запись: $openPath" -ForegroundColor Green

        # ---- сама запись ----
        Write-Host ''
        Write-Host "Запись $openPath ..." -ForegroundColor Cyan
        $total = 0
        $nextReport = 0
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $src.Position = 0
        $hardFail = $false
        try {
            if ($DeferPartitionTable) {
                # Keep both GPT copies out of view until the filesystems are copied.
                # No mounted old/new volume is allowed during the long body write.
                $bodyEnd = $imageSize - 1MB
                $src.Position = 1MB
                $offset = 1MB
                Write-Host 'Deferred GPT: copy body first, then backup GPT and primary GPT.' -ForegroundColor Cyan
                while ($offset -lt $bodyEnd) {
                    $bodyCount = [int][Math]::Min([long]$buf.Length, [long]($bodyEnd - $offset))
                    $loaded = 0
                    while ($loaded -lt $bodyCount) {
                        $n = $src.Read($buf, $loaded, $bodyCount - $loaded)
                        if ($n -eq 0) { throw 'Unexpected source EOF during deferred body copy.' }
                        $loaded += $n
                    }
                    [PfRawDisk]::WriteAt($handle, $buf, $bodyCount, $offset)
                    $offset += [long]$bodyCount
                    $total += [long]$bodyCount
                    if ($total -ge $nextReport) {
                        Write-Host ("    {0}% - {1:N2} GiB copied (GPT still deferred)" -f [Math]::Round(100.0 * $total / $imageSize, 1), ($total / 1GB))
                        $nextReport = $total + 2GB
                    }
                }
                Flush-PfRawDisk -Handle $handle
                if (@(Get-PfDiskPartitions -Number $target.Index).Count) { throw 'Partitions appeared before deferred GPT commit; refusing to claim a verified write.' }
                if($VerifyBeforePublish){
                    $null=Assert-PfUsbDisk -Number $target.Index -Identity $identity
                    $bodyRead=$null
                    try{
                        $bodyRead=Open-PfRawDisk -Drive $Drive -Access Read
                        $deferredVerified+=Confirm-PfDeferredSpan -Source $src -ReadHandle $bodyRead -Offset 1MB -Length ($bodyEnd-1MB)
                    }finally{if($bodyRead){$bodyRead.Dispose()}}
                    if(@(Get-PfDiskPartitions -Number $target.Index).Count){throw 'Partitions appeared during pre-publication verification.'}
                    $null=Assert-PfUsbDisk -Number $target.Index -Identity $identity
                    Write-Host '[OK] Filesystem body verified before GPT publication.' -ForegroundColor Green
                }
                foreach ($finalOffset in @([long]$bodyEnd, [long]0)) {
                    $src.Position = $finalOffset
                    $finalBytes = New-Object byte[] (1MB)
                    $loaded = 0
                    while ($loaded -lt $finalBytes.Length) {
                        $n = $src.Read($finalBytes, $loaded, $finalBytes.Length - $loaded)
                        if ($n -eq 0) { throw 'Unexpected source EOF in deferred GPT region.' }
                        $loaded += $n
                    }
                    for ($commitAttempt = 1; $commitAttempt -le 3; $commitAttempt++) {
                        try { [PfRawDisk]::WriteAt($handle, $finalBytes, $finalBytes.Length, $finalOffset); break }
                        catch {
                            $commitError = Get-PfErrorInfo $_
                            if ($commitError.Code -ne 433 -or $commitAttempt -eq 3) { throw }
                            # A layout rescan may invalidate the old handle. Only the
                            # final, already staged GPT regions are idempotently retried.
                            $handle.Dispose(); $handle = $null
                            Start-Sleep -Seconds 1
                            $null = Assert-PfUsbDisk -Number $target.Index -Identity $identity
                            $handle = Open-PfRawDisk -Drive $Drive -Access 'Write'
                        }
                    }
                    $total += [long]$finalBytes.Length
                }
                for ($flushAttempt = 1; $flushAttempt -le 3; $flushAttempt++) {
                    try { Flush-PfRawDisk -Handle $handle; break }
                    catch {
                        if ((Get-PfErrorInfo $_).Code -ne 433 -or $flushAttempt -eq 3) { throw }
                        $handle.Dispose(); $handle = $null
                        Start-Sleep -Seconds 1
                        $null = Assert-PfUsbDisk -Number $target.Index -Identity $identity
                        $handle = Open-PfRawDisk -Drive $Drive -Access 'Write'
                    }
                }
                $handle.Dispose(); $handle = $null
                $null = Assert-PfUsbDisk -Number $target.Index -Identity $identity
                if($VerifyBeforePublish){
                    $bootRead=$null
                    try{
                        $bootRead=Open-PfRawDisk -Drive $Drive -Access Read
                        $deferredVerified+=Confirm-PfDeferredSpan -Source $src -ReadHandle $bootRead -Offset 0 -Length 1MB
                        $deferredVerified+=Confirm-PfDeferredSpan -Source $src -ReadHandle $bootRead -Offset $bodyEnd -Length 1MB
                    }finally{if($bootRead){$bootRead.Dispose()}}
                    if($deferredVerified -ne $imageSize){throw 'Deferred verification did not cover every image byte.'}
                }else{
                    Add-PfRawDiskNative
                    [PfRawDisk]::Refresh($Drive)
                    Start-Sleep -Seconds 1
                    Lock-PfDiskVolumes -Number $target.Index | ForEach-Object { $locks += $_ }
                    if (@($locks | Where-Object { -not $_.Locked }).Count) { throw 'New Windows volumes could not be locked for full read-back.' }
                }
            } else {
            while (($n = $src.Read($buf, 0, $buf.Length)) -gt 0) {
                Write-PfRawBytes -Handle $handle -Bytes $buf -Count $n
                $total += $n
                if ($total -ge $nextReport) {
                    $pct = [Math]::Round(100.0 * $total / $imageSize, 1)
                    Write-Host ("    {0}% — {1} ГБ из {2} ГБ" -f $pct, [Math]::Round($total/1GB,2), [Math]::Round($imageSize/1GB,2)) -ForegroundColor DarkCyan
                    $nextReport = $total + 2GB
                }
            }
            }
            if ($total -ne $imageSize) { throw 'Source image length changed or copying was incomplete.' }
            $sw.Stop()
            if ($handle) { Flush-PfRawDisk -Handle $handle }
            $secs = [Math]::Max($sw.Elapsed.TotalSeconds, 0.001)
            Write-Host ("[OK] Записано {0} ГБ за {1:N0} сек ({2:N0} МБ/с)" -f `
                [Math]::Round($total/1GB,2), $sw.Elapsed.TotalSeconds, (($total/1MB)/$secs)) -ForegroundColor Green
            $done = $true
            $writeCode = 0
            break
        } catch {
            # Only access/sharing errors before any successful write allow
            # escalation. Never clear the layout after a partially written image.
            $e = Get-PfErrorInfo $_
            $writeCode = $e.Code
            $lastWhy = if ($writeCode) { "код Windows $writeCode — $(Get-PfWin32Hint -Code $writeCode)" }
                       else { "$($e.Type): $($e.Text)" }
            Write-Host ("  Запись остановлена на {0:N2} ГБ: {1}" -f ($total/1GB), $lastWhy) -ForegroundColor Yellow
            $hardFail = $total -gt 0 -or -not $writeCode -or ($writeCode -ne 5 -and $writeCode -ne 32)
        }
        if ($hardFail) { break }
    }

    # Keep locks until read-back completes; all resources are released below.
    if ($handle) { try { $handle.Dispose() } catch { }; $handle = $null }

    if (-not $done) {
        $advice = if ($writeCode -eq 19) { 'Носитель защищён от записи — нужна другая флешка.' }
                  elseif($VerifyBeforePublish){'Закройте программы, использующие флешку, и повторите build-all.bat.'}
                  else { 'Закройте всё, что использует флешку, и повторите: build-legacy.bat -FromStage 8' }
        throw ("Запись прервана на $([Math]::Round($total/1GB,2)) ГБ из $([Math]::Round($imageSize/1GB,2)) ГБ.`n" +
               "Причина: $lastWhy`n" +
               "Испробовано способов освободить носитель: $tried из $MaxMode.`n$advice")
    }

    # ---- сверка: читаем обратно начало, середину и конец образа ----
    if($VerifyBeforePublish){
        if($deferredVerified -ne $imageSize){throw 'Missing complete pre-publication read-back.'}
        $verified=$deferredVerified
        Write-Host "[OK] Verified $verified bytes: unpartitioned body plus committed boot/GPT regions." -ForegroundColor Green
    }else{
    if ($VerifyOnly) {
        $null = Assert-PfUsbDisk -Number $target.Index -Identity $identity
        Lock-PfDiskVolumes -Number $target.Index | ForEach-Object { $locks += $_ }
        if (@($locks | Where-Object { -not $_.Locked }).Count) { throw 'Cannot exclusively lock volumes for verification.' }
    }
    Write-Host ''
    Write-Host "Проверяю запись чтением (VerifyFull=$VerifyFull)..." -ForegroundColor Cyan
    $probe = 4MB
    $rh = $null
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $null = Assert-PfUsbDisk -Number $target.Index -Identity $identity
        $rh = Open-PfRawDisk -Drive $Drive -Access 'Read'
        $relocatedPrimary = $null
        if ($AllowGptRelocation) {
            $expectedPrimary = New-Object byte[] 512
            $actualPrimary = New-Object byte[] 512
            $src.Position = 512
            if ($src.Read($expectedPrimary, 0, 512) -ne 512 -or
                (Read-PfRawBytes -Handle $rh -Bytes $actualPrimary -Offset 512) -ne 512) { throw 'Short GPT header read.' }
            $sourceHash = [BitConverter]::ToString($sha.ComputeHash($expectedPrimary))
            $actualHash = [BitConverter]::ToString($sha.ComputeHash($actualPrimary))
            if ($sourceHash -ne $actualHash) {
                $canonical = Get-PfRelocatedGptHeader -Header $expectedPrimary -ImageBytes $imageSize -DiskBytes $identity.Size
                if ([BitConverter]::ToString($sha.ComputeHash($canonical)) -ne $actualHash) {
                    throw 'Primary GPT differs beyond the exact expected relocation.'
                }
                $originalBackup = New-Object byte[] 512
                $actualBackup = New-Object byte[] 512
                $src.Position = $imageSize - 512
                if ($src.Read($originalBackup, 0, 512) -ne 512 -or
                    (Read-PfRawBytes -Handle $rh -Bytes $actualBackup -Offset ($identity.Size - 512)) -ne 512) { throw 'Short backup GPT header read.' }
                $canonicalBackup = Get-PfRelocatedGptHeader -Header $originalBackup -ImageBytes $imageSize -DiskBytes $identity.Size -Backup
                if ([BitConverter]::ToString($sha.ComputeHash($canonicalBackup)) -ne [BitConverter]::ToString($sha.ComputeHash($actualBackup))) {
                    throw 'Relocated backup GPT header is inconsistent.'
                }
                $tableBytes = [int]([long][BitConverter]::ToUInt32($originalBackup, 80) * [BitConverter]::ToUInt32($originalBackup, 84))
                $sourceTable = New-Object byte[] $tableBytes
                $actualTable = New-Object byte[] $tableBytes
                $src.Position = [long][BitConverter]::ToUInt64($originalBackup, 72) * 512
                if ($src.Read($sourceTable, 0, $tableBytes) -ne $tableBytes -or
                    (Read-PfRawBytes -Handle $rh -Bytes $actualTable -Offset ([long][BitConverter]::ToUInt64($canonicalBackup, 72) * 512)) -ne $tableBytes) {
                    throw 'Short relocated partition table read.'
                }
                if ([BitConverter]::ToString($sha.ComputeHash($sourceTable)) -ne [BitConverter]::ToString($sha.ComputeHash($actualTable))) {
                    throw 'Relocated backup partition table differs from the image.'
                }
                $relocatedPrimary = $canonical
                Write-Host '[OK] Проверен точный перенос GPT в конец большего носителя, включая резервный заголовок и таблицу.' -ForegroundColor Green
            }
        }
        $verified = 0L
        $samples = @([long]0, [long]([Math]::Floor($imageSize / 2 / 512) * 512), [long]($imageSize - $probe))
        $off = 0L
        $sampleIndex = 0
        while ($off -lt $imageSize) {
            $count = [int][Math]::Min([long]$probe, [long]($imageSize - $off))
            $mine = New-Object byte[] $count
            $diskB = New-Object byte[] $count
            $got = Read-PfRawBytes -Handle $rh -Bytes $diskB -Offset $off
            $src.Position = $off
            $read = 0
            while ($read -lt $count) {
                $n = $src.Read($mine, $read, $count - $read)
                if ($n -eq 0) { throw 'Unexpected end of source during verification.' }
                $read += $n
            }
            if ($relocatedPrimary -and $off -eq 0) { $relocatedPrimary.CopyTo($mine, 512) }
            # Сравниваем блок ЦЕЛИКОМ, а не выборку: эти 4 МБ мы всё равно уже
            # прочитали с носителя, а хеш считается за микросекунды. Выборка
            # «каждый 1024-й байт» пропускала бы локальную порчу в сотни байт.
            $hImg = [BitConverter]::ToString($sha.ComputeHash($mine))
            $hUsb = [BitConverter]::ToString($sha.ComputeHash($diskB))
            $same = ($hImg -eq $hUsb) -and ($got -eq $count)
            if (-not $same) { throw "Read-back mismatch at byte $off (read $got of $count)." }
            $verified += $count
            $txt = if ($same) { 'совпадает' } else { 'РАСХОЖДЕНИЕ' }
            if (-not $VerifyFull -or $off % 1GB -eq 0 -or $verified -eq $imageSize) {
                Write-Host ("    смещение {0,12:N0} байт: прочитано {1}, {2}" -f $off, $got, $txt) -ForegroundColor Green
            }
            if ($VerifyFull) { $off += $count }
            else {
                $sampleIndex++
                if ($sampleIndex -ge $samples.Count) { break }
                $off = $samples[$sampleIndex]
            }
        }
        Write-Host "[OK] Сверено $verified байт; полная проверка: $VerifyFull." -ForegroundColor Green
        if ($relocatedPrimary) { Write-Host 'Единственное разрешённое отличие от исходника: проверенная геометрия заголовка GPT.' -ForegroundColor Yellow }
    } finally {
        $sha.Dispose()
        if ($rh) { try { $rh.Dispose() } catch { } }
    }
    }

    Write-Host ''
    Write-Host '[ИНФО] Перед извлечением: безопасно отключите устройство (иконка в трее).' -ForegroundColor Yellow
    Write-Host '[ИНФО] После записи том P1 (метка FLASHCARD) станет съёмным диском.' -ForegroundColor Yellow
    if ($VerifyOnly) { Write-Host '[ГОТОВО] Проверка чтением завершена; запись образа не выполнялась.' -ForegroundColor Green }
    elseif($VerifyBeforePublish){Write-Host '[OK] Данные и GPT проверены; Windows перечитывает разметку.' -ForegroundColor Green}
    else { Write-Host '[ГОТОВО] Образ записан и проверен. Размещение QEMU выполняет стадия 9.' -ForegroundColor Green }
    if(-not $VerifyBeforePublish){Write-Host 'На учебном ПК без прав QEMU-кнопка недоступна — используйте нативную загрузку.' -ForegroundColor Cyan}
} catch {
    $code = 1
    $writeFailure=($_|Out-String)
    Write-Host ''
    Write-Host '================ ОШИБКА ЗАПИСИ ================' -ForegroundColor Red
    # Показываем код Windows: без него причина не видна. MethodInvocationException
    # (обёртка PowerShell) кода не несёт — спускаемся по InnerException до
    # Win32Exception, где код лежит в NativeErrorCode.
    $ex = $_.Exception
    $chain = @()
    while ($ex) { $chain += $ex; $ex = $ex.InnerException }
    Write-Host "  $($chain[0].Message)" -ForegroundColor Red
    $wcode = 0
    foreach ($e in $chain) {
        if ($e.PSObject.Properties['NativeErrorCode']) { $wcode = [int]$e.NativeErrorCode; break }
    }
    if ($wcode) {
        Write-Host "  Код Windows: $wcode" -ForegroundColor Red
        Write-Host "  $($chain[-1].Message)" -ForegroundColor DarkYellow
        Write-Host "  $(Get-PfWin32Hint -Code $wcode)" -ForegroundColor DarkYellow
    } elseif ($chain.Count -gt 1) {
        Write-Host "  Внутренняя ошибка: $($chain[-1].GetType().Name): $($chain[-1].Message)" -ForegroundColor DarkRed
    }
    # Срез по носителю: показывает, не защищён ли он и что с разделами.
    if ($target) {
        Write-Host '  --- состояние носителя ---' -ForegroundColor DarkGray
        foreach ($line in @(Get-PfDiskReport -Number $target.Index)) {
            Write-Host "    $line" -ForegroundColor DarkGray
        }
    }
    Write-Host "  Подробности: $WriteLog" -ForegroundColor Yellow
    Write-Host '=============================================' -ForegroundColor Red
} finally {
    if ($handle) { try { $handle.Dispose() } catch { } }
    if ($locks.Count) { Release-PfVolumeLocks -Locks $locks }
    if ($src) { $src.Dispose() }
    if ($currentImage) { $currentImage.Dispose() }
    if ($done -and -not $VerifyOnly) {
        try {
            $null = Assert-PfUsbDisk -Number $target.Index -Identity $identity
            [PfRawDisk]::Refresh($Drive)
            Update-HostStorageCache -ErrorAction Stop
        } catch {
            $code = 1
            $writeFailure=($_|Out-String)
            Write-Host "[!] Не удалось перечитать разметку: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    if($ResultPath -and $resultAllowed){
        $record=[ordered]@{
            Complete=($code -eq 0 -and $done);ImagePath=$ImagePath;ImageBytes=$imageSize
            BytesWritten=[long]$total;BytesVerified=[long]$verified
            VerificationMethod=$(if($VerifyBeforePublish){'DeferredBodyAndBootRegions'}elseif($VerifyFull){'FullReadBack'}else{'SampledReadBack'})
            BeforePublicationBodyVerified=[bool]($VerifyBeforePublish -and $deferredVerified -eq $imageSize)
            ExpectedSourceSha256=$validatedSourceSha256;Target=$identity;DiskNumber=$target.Index
            LayoutInitialization=$layoutInitialization
            Error=$writeFailure;Time=(Get-Date).ToString('o')
        }
        try{
            $temporary=$ResultPath+'.new'
            [IO.File]::WriteAllText($temporary,($record|ConvertTo-Json -Depth 4),[Text.Encoding]::UTF8)
            if(Test-Path -LiteralPath $ResultPath){[IO.File]::Delete($ResultPath)}
            [IO.File]::Move($temporary,$ResultPath)
        }catch{$code=1;Write-Host ('Failed to save writer receipt: '+($_|Out-String)) -ForegroundColor Red}
    }
    if($writerMutex){if($writerMutexHeld){$writerMutex.ReleaseMutex()};$writerMutex.Dispose()}
    if ($LogOn) { try { Stop-Transcript | Out-Null } catch { } }
}

exit $code
