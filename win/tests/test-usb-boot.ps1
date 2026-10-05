# Actual-USB UEFI smoke test. Run only after the writer, afterverify and stage 9 finish.
# Snapshot mode discards guest disk changes; this script never commits a snapshot.
# Requires an elevated Windows PowerShell 5.1 or PowerShell 7 session.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateRange(0, 2147483647)][int]$DiskNumber,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$ExpectedDevicePath,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ExpectedSerialNumber,
    [Parameter(Mandatory = $true)][ValidateRange(1, [long]::MaxValue)][long]$ExpectedSize,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$UsbRoot,
    [ValidateRange(1, 2147483647)][int]$TimeoutSec = 240,
    [ValidateRange(0, 86400)][int]$ObservationSec = 0,
    [ValidateRange(2048, 32768)][int]$RamMb = 4096,
    [ValidateRange(1, 16)][int]$Cores = 2,
    [ValidateRange(1024, 65535)][int]$QmpPort = 22705,
    [ValidateSet('Auto', 'WHPX', 'TCG')][string]$Accel = 'Auto',
    [switch]$DedicatedIoThread
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$locks = @()
$ownedProcess = $null
$runtimeDir = $null
$logPaths = @()
$locationPushed = $false
$environmentChanged = $false
$exitCode = 1
$savedTemp = $env:TEMP
$savedTmp = $env:TMP
$graphicalMarkerPattern = '(?im)\bStarted\s+(?:sddm\.service\b|Simple Desktop Display Manager)|\bReached target\s+(?:graphical\.target\b|Graphical Interface)'
$watchdogPattern = '(?im)BUG: soft lockup|watchdog:.*lockup|(?:rcu:|INFO: rcu_tasks(?:_rude|_trace)?).*(?:stall|self-detected)'

# Reject junctions, mounted folders, symlinks and network paths before disk mapping.
function Get-BootcheckDirectoryPartition {
    param([string]$Directory)
    $item = Get-Item -LiteralPath $Directory -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or $item.FullName -notmatch '^([A-Za-z]):\\') {
        throw 'Bootcheck paths must be existing local drive-letter directories.'
    }
    $letter = $Matches[1]
    for ($parent = $item; $null -ne $parent; $parent = $parent.Parent) {
        if ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Reparse paths are not permitted: $($parent.FullName)"
        }
    }
    $partitions = @(Get-Partition -DriveLetter $letter -ErrorAction Stop)
    if ($partitions.Count -ne 1) { throw "Cannot uniquely map directory to a disk: $Directory" }
    return $partitions[0]
}

function Save-BootcheckScreen {
    $client = [Net.Sockets.TcpClient]::new('127.0.0.1', $QmpPort)
    try {
        $stream = $client.GetStream()
        $stream.ReadTimeout = 10000
        $reader = [IO.StreamReader]::new($stream)
        $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
        $writer.AutoFlush = $true
        $greeting = $reader.ReadLine() | ConvertFrom-Json
        if (-not $greeting.PSObject.Properties['QMP']) { throw 'Invalid screenshot QMP endpoint.' }
        $commands = @(
            @{ execute = 'qmp_capabilities'; id = 1 },
            @{ execute = 'screendump'; arguments = @{ filename = (Join-Path $runtimeDir 'screen-before-input.ppm') }; id = 2 },
            @{ execute = 'send-key'; arguments = @{ keys = @(@{ type = 'qcode'; data = 'shift' }); 'hold-time' = 100 }; id = 3 },
            @{ execute = 'screendump'; arguments = @{ filename = (Join-Path $runtimeDir 'screen.ppm') }; id = 4 }
        )
        foreach ($command in $commands) {
            $writer.WriteLine(($command | ConvertTo-Json -Depth 6 -Compress))
            do { $reply = $reader.ReadLine() | ConvertFrom-Json } while (-not $reply.PSObject.Properties['id'] -or $reply.id -ne $command.id)
            if ($reply.PSObject.Properties['error']) { throw ($reply.error | ConvertTo-Json -Compress) }
            # Kubuntu hides login controls when idle; capture both states, not just wallpaper.
            if ($command.execute -eq 'send-key') { Start-Sleep -Seconds 2 }
        }
        Write-Host "Framebuffer saved: $(Join-Path $runtimeDir 'screen.ppm')"
    } finally { $client.Dispose() }
}

try {
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\pf-tools.psm1') -Force -ErrorAction Stop
    if (-not (Test-PfIsAdmin)) { throw 'Run this script in an elevated administrator session; no automatic elevation is performed.' }
    $identity = [pscustomobject]@{
        Path = $ExpectedDevicePath
        SerialNumber = $ExpectedSerialNumber.Trim()
        Size = $ExpectedSize
    }
    $null = Assert-PfUsbDisk -Number $DiskNumber -Identity $identity
    $esp = Get-BootcheckDirectoryPartition -Directory $UsbRoot
    if ($esp.DiskNumber -ne $DiskNumber -or
        ([string]$esp.GptType).Trim('{}') -ne 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b') {
        throw 'UsbRoot must be a mounted ESP on the confirmed USB disk.'
    }
    $sourceQemu = Join-Path (Get-Item -LiteralPath $UsbRoot -Force).FullName 'qemu'
    $null = Get-BootcheckDirectoryPartition -Directory $sourceQemu
    if (@(Get-ChildItem -LiteralPath $sourceQemu -Recurse -Force -ErrorAction Stop | Where-Object {
        $_.Attributes -band [IO.FileAttributes]::ReparsePoint
    }).Count) { throw 'The USB QEMU directory contains reparse files or directories.' }

    $hostTemp = [IO.Path]::GetTempPath()
    $tempPartition = Get-BootcheckDirectoryPartition -Directory $hostTemp
    if ($tempPartition.DiskNumber -eq $DiskNumber) { throw 'Host TEMP is on the confirmed USB disk.' }
    $runtimeDir = Join-Path $hostTemp ('pf-usb-bootcheck-' + [Guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $runtimeDir -ErrorAction Stop
    $stagedQemu = Join-Path $runtimeDir 'qemu'
    $null = New-Item -ItemType Directory -Path $stagedQemu -ErrorAction Stop
    Copy-Item -Path (Join-Path $sourceQemu '*') -Destination $stagedQemu -Recurse -Force -ErrorAction Stop
    if (@(Get-ChildItem -LiteralPath $sourceQemu -Recurse -File -Force).Count -ne
        @(Get-ChildItem -LiteralPath $stagedQemu -Recurse -File -Force).Count) { throw 'Host QEMU staging is incomplete.' }
    $runtimePartition = Get-BootcheckDirectoryPartition -Directory $runtimeDir
    if ($runtimePartition.DiskNumber -eq $DiskNumber) { throw 'Staged runtime is on the confirmed USB disk.' }
    if (@(Get-ChildItem -LiteralPath $runtimeDir -Recurse -Force -ErrorAction Stop | Where-Object {
        $_.Attributes -band [IO.FileAttributes]::ReparsePoint
    }).Count) { throw 'The staged runtime contains reparse files or directories.' }
    $qemuDir = Join-Path $runtimeDir 'qemu'
    $qemu = Join-Path $qemuDir 'qemu-system-x86_64.exe'
    if (-not (Test-Path -LiteralPath $qemu -PathType Leaf)) { throw 'The staged qemu-system-x86_64.exe is missing.' }
    $firmware = Find-PfOvmf -QemuExe $qemu
    if (-not $firmware -or -not (Test-Path -LiteralPath $firmware -PathType Leaf)) {
        throw 'Staged UEFI code firmware is missing; BIOS fallback is forbidden.'
    }
    $qemuArgs = Get-PfQemuBaseArgs -Uefi -QemuExe $qemu -ScriptDir $runtimeDir -RamMb $RamMb -Cores $Cores
    if ($Accel -eq 'WHPX') {
        $qemuArgs = @('-machine', 'type=q35', '-accel', 'whpx,kernel-irqchip=off') + @($qemuArgs | Select-Object -Skip 6)
    } elseif ($Accel -eq 'TCG') {
        $qemuArgs = @('-machine', 'type=q35', '-accel', 'tcg,thread=multi') + @($qemuArgs | Select-Object -Skip 6)
    }
    $firmwareDrive = "if=pflash,format=raw,readonly=on,file=$firmware"
    if ($qemuArgs -notcontains $firmwareDrive) { throw 'QEMU arguments do not contain the verified read-only UEFI firmware.' }
    $qemuArgs = @($qemuArgs | ForEach-Object {
        if ($_ -eq $firmwareDrive) { "if=pflash,format=raw,readonly=on,file=$($firmware.Replace(',', ',,'))" }
        else { $_ }
    })
    # QEMU's standard edk2 x86_64 code uses the shared i386 vars template.
    $firmwareDir = Split-Path $firmware -Parent
    foreach ($name in @('edk2-x86_64-vars.fd', 'edk2-i386-vars.fd')) {
        $template = Join-Path $firmwareDir $name
        if (Test-Path -LiteralPath $template -PathType Leaf) {
            $vars = Join-Path $runtimeDir 'uefi-vars.fd'
            Copy-Item -LiteralPath $template -Destination $vars -ErrorAction Stop
            (Get-Item -LiteralPath $vars -Force).IsReadOnly = $false
            $qemuArgs += @('-drive', "if=pflash,format=raw,file=$($vars.Replace(',', ',,'))")
            break
        }
    }
    $serialLog = Join-Path $runtimeDir 'boot-serial.log'
    $stdoutLog = Join-Path $runtimeDir 'qemu-stdout.log'
    $stderrLog = Join-Path $runtimeDir 'qemu-stderr.log'
    $logPaths = @($serialLog, $stdoutLog, $stderrLog)
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $QmpPort)
    try { $listener.Start() } finally { $listener.Stop() }
    $qemuArgs += @('-display', 'none', '-monitor', 'none', '-snapshot',
        '-qmp', "tcp:127.0.0.1:$QmpPort,server=on,wait=off",
        '-boot', 'order=c,once=c', '-no-reboot',
        '-chardev', "file,id=pfbootserial,path=$($serialLog.Replace(',', ',,'))",
        '-serial', 'chardev:pfbootserial')
    if ($DedicatedIoThread) {
        $qemuArgs += @('-object', 'iothread,id=pfio',
            '-drive', "file=\\.\PhysicalDrive$DiskNumber,format=raw,if=none,id=pfusb",
            '-device', 'virtio-blk-pci,drive=pfusb,iothread=pfio')
    } else { $qemuArgs += @('-drive', "file=\\.\PhysicalDrive$DiskNumber,format=raw,if=virtio") }
    $arguments = ConvertTo-PfArgumentList -Arguments $qemuArgs -What 'USB snapshot bootcheck'
    [IO.File]::WriteAllText((Join-Path $runtimeDir 'qemu-command.txt'),
        "$qemu`n$(Join-PfArguments $arguments)`n", [Text.Encoding]::UTF8)
    Write-Host "Host runtime and retained logs: $runtimeDir"
    Write-Host "Confirmed USB: \\.\PhysicalDrive$DiskNumber; UEFI, $RamMb MiB, $Cores cores, snapshot mode."

    # Host-only working directory and TEMP/TMP also contain QEMU's transient overlays.
    Push-Location -LiteralPath $runtimeDir
    $locationPushed = $true
    $env:TEMP = $runtimeDir
    $env:TMP = $runtimeDir
    $environmentChanged = $true
    $null = Assert-PfUsbDisk -Number $DiskNumber -Identity $identity
    $parts = @(Get-PfDiskPartitions -Number $DiskNumber)
    $expectedPaths = @()
    foreach ($part in $parts) {
        $gptType = ([string]$part.GptType).Trim('{}')
        if ($gptType -in '21686148-6449-6e6f-744e-656564454649', '0fc63daf-8483-4772-8e79-3d69d8477de4') {
            $mountedFilesystems = @($part | Get-Volume -ErrorAction Stop | Where-Object { $_.FileSystem })
            if (-not $mountedFilesystems.Count) { continue }
        }
        $volumes = @(Get-CimAssociatedInstance -InputObject $part -ResultClassName MSFT_Volume -ErrorAction Stop)
        $path = Get-PfVolumePath -Letter ([string]$part.DriveLetter) -DiskNumber $DiskNumber -PartitionNumber $part.PartitionNumber
        if ($volumes.Count -or $part.DriveLetter -or @($part.AccessPaths | Where-Object { $_ -like '\\?\Volume{*' }).Count) {
            if (-not $path) { throw "Cannot resolve Windows volume on partition $($part.PartitionNumber)." }
        }
        if ($path) { $expectedPaths += $path }
    }
    if (-not $expectedPaths.Count) { throw 'No Windows volumes found to lock on the mounted ESP disk.' }
    # Capture partial results so a later lock failure still releases earlier handles.
    Lock-PfDiskVolumes -Number $DiskNumber | ForEach-Object { $locks += $_ }
    foreach ($lock in $locks) {
        if (-not $lock.Locked -or -not $lock.Handle -or $lock.Handle.IsClosed -or $lock.Handle.IsInvalid) {
            throw "USB volume lock failed: $($lock.Path) $($lock.Detail)"
        }
    }
    foreach ($path in $expectedPaths) {
        if (@($locks | Where-Object { $_.Path -eq $path -and $_.Locked }).Count -ne 1) {
            throw "USB volume is not exclusively locked: $path"
        }
    }
    if ($locks.Count -ne $expectedPaths.Count) { throw 'USB volume enumeration changed during locking.' }
    $null = Assert-PfUsbDisk -Number $DiskNumber -Identity $identity
    $currentParts = @(Get-PfDiskPartitions -Number $DiskNumber)
    $before = @($parts | ForEach-Object { "$($_.PartitionNumber):$($_.Offset):$($_.Size)" })
    $after = @($currentParts | ForEach-Object { "$($_.PartitionNumber):$($_.Offset):$($_.Size)" })
    if ($before.Count -ne $after.Count -or
        (($before | Sort-Object) -join '|') -ne (($after | Sort-Object) -join '|')) {
        throw 'USB partition layout changed during locking.'
    }

    $ownedProcess = Start-Process -FilePath $qemu -ArgumentList $arguments -WorkingDirectory $runtimeDir `
        -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog -WindowStyle Hidden -PassThru
    $null = $ownedProcess.Handle
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $found = $false
    $graphicalAt = $null
    while ($true) {
        if (Test-Path -LiteralPath $serialLog -PathType Leaf) {
            $text = Get-Content -LiteralPath $serialLog -Raw -ErrorAction Stop
            if ($text) {
                $text = $text -replace '\x1b\[[0-?]*[ -/]*[@-~]', ''
                if ($text -match $watchdogPattern) {
                    throw 'Guest watchdog reported a lockup or RCU stall; retained serial log contains details.'
                }
                if ($text -match $graphicalMarkerPattern) {
                    if (-not $found) { $graphicalAt = $timer.Elapsed.TotalSeconds }
                    $found = $true
                }
            }
        }
        if ($ownedProcess.HasExited) { throw "QEMU exited before boot observation completed (exit code $($ownedProcess.ExitCode))." }
        if ($found -and ($timer.Elapsed.TotalSeconds - $graphicalAt) -ge $ObservationSec) { break }
        if (-not $found -and $timer.Elapsed.TotalSeconds -ge $TimeoutSec) { break }
        Start-Sleep -Milliseconds 500
    }
    Start-Sleep -Seconds 10
    if ((Get-Content -LiteralPath $serialLog -Raw -ErrorAction Stop) -match $watchdogPattern) {
        throw 'Guest watchdog reported a lockup or RCU stall; retained serial log contains details.'
    }
    if (-not $ownedProcess.HasExited) { Save-BootcheckScreen }
    if (-not $found) { throw "Timed out after $TimeoutSec seconds without a graphical-service marker." }
    if ($ownedProcess.HasExited -and $ownedProcess.ExitCode -ne 0) {
        throw "QEMU failed with exit code $($ownedProcess.ExitCode), despite a serial marker."
    }
    Write-Host "PASS: graphical-service marker and $ObservationSec seconds of observation without serial watchdog reports; not a GUI or physical-hardware boot guarantee."
    $exitCode = 0
}
catch {
    Write-Host "FAIL: $($_.Exception.Message)"
    $exitCode = 1
}
finally {
    # Use the retained process object, never process-name searches or unrelated PIDs.
    # No QMP endpoint: terminate this disposable snapshot VM, then verify its exit.
    if ($null -ne $ownedProcess) {
        while (-not $ownedProcess.HasExited) {
            try {
                $ownedProcess.Kill()
                $ownedProcess.WaitForExit()
            }
            catch {
                if (-not $ownedProcess.HasExited) {
                    Write-Warning "Cannot yet stop owned QEMU; retaining USB locks and retrying: $($_.Exception.Message)"
                    $exitCode = 1
                    Start-Sleep -Seconds 1
                }
            }
        }
        $ownedProcess.Dispose()
    }
    if ($locks.Count) { Release-PfVolumeLocks -Locks $locks }
    if ($environmentChanged) { $env:TEMP = $savedTemp; $env:TMP = $savedTmp }
    if ($locationPushed) { Pop-Location }
    foreach ($path in $logPaths) {
        Write-Host "--- Last 40 lines: $path ---"
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            try { Get-Content -LiteralPath $path -Tail 40 -ErrorAction Stop | ForEach-Object { Write-Host $_ } }
            catch { Write-Warning "Cannot read retained log: $($_.Exception.Message)" }
        }
    }
    if ($runtimeDir) { Write-Host "Host runtime retained: $runtimeDir" }
    Write-Host 'Guest disk changes were snapshot-only and discarded, never persisted to the USB. Host logs/firmware copy are retained.'
    Write-Host 'Limitations: serial/service smoke test only; no proof of a working GUI, real firmware compatibility, or hardware boot.'
}
exit $exitCode
