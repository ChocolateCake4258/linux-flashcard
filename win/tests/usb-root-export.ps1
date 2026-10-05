# Root-partition backup/export only. The client sees a bounded raw slice, not GPT/ESP.
# Export always waits, including when launched by a parent-created S4U task.
# Stop safely: disconnect NBD clients, then create nbd.stop in the work directory.
# Do not forcibly terminate the supervisor/task: that bypasses PowerShell finally.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Backup', 'Export')][string]$Action,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$ExpectedDevicePath,
    [ValidateRange(0, 2147483647)][int]$DiskNumber = 2,
    [Parameter(Mandatory = $true)][string]$QemuImgPath,
    [string]$QemuNbdPath,
    [ValidateSet('Legacy', 'Esp2GiB')][string]$Layout = 'Legacy',
    [switch]$Wait,
    [switch]$ProbeRead
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\pf-tools.psm1') -Force -ErrorAction Stop
if (-not (Test-PfIsAdmin)) { throw 'An administrator session is required; no automatic elevation.' }
$ExpectedSerialNumber = '0E7113C55070'
[UInt64]$ExpectedSize = 31042043904
[UInt64]$rootOffset = if ($Layout -eq 'Esp2GiB') { 2149580800 } else { 7518289920 }
[UInt64]$rootSize = if ($Layout -eq 'Esp2GiB') { 28891414528 } else { 22545432576 }
$slice = "driver=raw,offset=$rootOffset,size=$rootSize,file.driver=host_device,file.filename=\\.\PhysicalDrive$DiskNumber"
$linuxGuid = '0fc63daf-8483-4772-8e79-3d69d8477de4'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$work = Join-Path $repo $(if ($Layout -eq 'Esp2GiB') { 'diagnostics\usb-before-firstboot-fix-esp2gib' } else { 'diagnostics\usb-before-firstboot-fix' })
$backup = Join-Path $work 'linux-before-fix.qcow2'
$metadataPath = Join-Path $work 'linux-before-fix.json'
$stopPath = Join-Path $work 'nbd.stop'
$identity = [pscustomobject][ordered]@{
    Path = $ExpectedDevicePath; SerialNumber = $ExpectedSerialNumber; Size = $ExpectedSize
}
$locks = @()
$owner = $null
$backupHandle = $null
$script:ownedProcess = $null
$script:ownedBirth = $null
$script:commandNumber = 0

function Assert-HostDirectory {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or $item.FullName -notmatch '^([A-Za-z]):\\') {
        throw "Not an existing local drive-letter directory: $Path"
    }
    $letter = $Matches[1]
    for ($parent = $item; $null -ne $parent; $parent = $parent.Parent) {
        if ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Reparse directory forbidden: $($parent.FullName)"
        }
    }
    $mapped = @(Get-Partition -DriveLetter $letter -ErrorAction Stop)
    if ($mapped.Count -ne 1) { throw "Ambiguous directory disk: $Path" }
    $hostDisk = Get-Disk -Number $mapped[0].DiskNumber -ErrorAction Stop
    if ($hostDisk.Number -eq $DiskNumber -or [string]$hostDisk.BusType -in @('USB', 'Unknown') -or
        [string](Get-Volume -DriveLetter $letter -ErrorAction Stop).DriveType -ne 'Fixed') {
        throw "Directory must be on a fixed non-USB host disk: $Path"
    }
}

function Assert-HostFile {
    param([string]$Path)
    Assert-HostDirectory -Path (Split-Path $Path -Parent)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Not a regular host file: $Path"
    }
}

function Get-PfGuidVolumePath {
    param($Partition)
    $volumes = @(Get-CimAssociatedInstance -InputObject $Partition -ResultClassName MSFT_Volume -ErrorAction Stop)
    $paths = @(@($Partition.AccessPaths) + @($volumes | ForEach-Object { $_.Path; $_.UniqueId }) |
        Where-Object { [string]$_ -match '^\\\\\?\\Volume\{[0-9a-fA-F-]{36}\}\\?$' } |
        ForEach-Object { ([string]$_).TrimEnd('\') } | Sort-Object -Unique)
    if ($paths.Count -ne 1) { throw 'Cannot uniquely resolve the Linux partition Volume GUID.' }
    return [string]$paths[0]
}

function Get-SourceFingerprint {
    $disk = Assert-PfUsbDisk -Number $DiskNumber -Identity $identity
    if ([string]$disk.PartitionStyle -ne 'GPT') { throw 'The confirmed USB must be GPT.' }
    $parts = @(Get-PfDiskPartitions -Number $DiskNumber)
    $roots = @($parts | Where-Object { ([string]$_.GptType).Trim('{}') -eq $linuxGuid })
    if ($roots.Count -ne 1) { throw 'Exactly one GPT Linux filesystem partition is required.' }
    $root = $roots[0]
    if ([UInt64]$root.Offset -ne $rootOffset -or [UInt64]$root.Size -ne $rootSize) {
        throw 'Linux root partition geometry differs from the confirmed layout.'
    }
    $volumes = @($root | Get-Volume -ErrorAction Stop)
    if (@($volumes | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.FileSystem) }).Count) {
        throw 'A Windows filesystem driver recognizes/mounts Linux root; refusing access.'
    }
    return [pscustomobject][ordered]@{
        DevicePath = [string]$disk.Path
        SerialNumber = ([string]$disk.SerialNumber).Trim()
        DiskSize = [UInt64]$disk.Size
        DiskNumber = [int]$disk.Number
        DiskGuid = [string]$disk.Guid
        PartitionNumber = [int]$root.PartitionNumber
        PartitionGuid = [string]$root.Guid
        GptType = ([string]$root.GptType).Trim('{}').ToLowerInvariant()
        Offset = [UInt64]$root.Offset
        Size = [UInt64]$root.Size
        VolumePath = Get-PfGuidVolumePath -Partition $root
        Layout = @($parts | Sort-Object PartitionNumber | ForEach-Object {
            '{0}:{1}:{2}:{3}:{4}' -f $_.PartitionNumber, [UInt64]$_.Offset, [UInt64]$_.Size, $_.GptType, $_.Guid
        })
    }
}

function Stop-OwnedProcess {
    # Retain the original Process object and native handle, never look up a PID.
    if ($null -eq $script:ownedProcess) { return }
    while (-not $script:ownedProcess.HasExited) {
        if ($script:ownedProcess.StartTime.ToUniversalTime().Ticks -ne $script:ownedBirth) {
            throw 'Owned process birth time changed; refusing PID-based cleanup.'
        }
        try { $script:ownedProcess.Kill() } catch {
            if (-not $script:ownedProcess.HasExited) { Write-Warning "Waiting for owned child cleanup: $_" }
        }
        $null = $script:ownedProcess.WaitForExit(1000)
    }
    $script:ownedProcess.WaitForExit()
    $script:ownedProcess.Dispose()
    $script:ownedProcess = $null
}

function Start-OwnedProcess {
    param([string]$Exe, [string[]]$Arguments, [string]$Label)
    if ($null -ne $script:ownedProcess) { throw 'A child is already owned.' }
    $script:commandNumber++
    $prefix = Join-Path $work ("{0}-{1}-{2}" -f $Action.ToLowerInvariant(), $script:commandNumber, $Label)
    foreach ($suffix in @('.stdout.log', '.stderr.log', '.command.txt')) {
        if (Test-Path -LiteralPath ($prefix + $suffix)) { Assert-HostFile -Path ($prefix + $suffix) }
    }
    $quoted = ConvertTo-PfArgumentList -Arguments $Arguments -What $Label
    [IO.File]::WriteAllText(($prefix + '.command.txt'), "$Exe`n$(Join-PfArguments $quoted)`n", [Text.Encoding]::UTF8)
    $script:ownedProcess = Start-Process -FilePath $Exe -ArgumentList $quoted -WorkingDirectory $work `
        -RedirectStandardOutput ($prefix + '.stdout.log') -RedirectStandardError ($prefix + '.stderr.log') `
        -WindowStyle Hidden -PassThru -ErrorAction Stop
    $null = $script:ownedProcess.Handle
    $script:ownedBirth = $script:ownedProcess.StartTime.ToUniversalTime().Ticks
    return $prefix
}

function Invoke-ImageTool {
    param([string[]]$Arguments, [string]$Label)
    $prefix = Start-OwnedProcess -Exe $QemuImgPath -Arguments $Arguments -Label $Label
    while (-not $script:ownedProcess.WaitForExit(500)) {
        Assert-NoCompetingQemu -VolumePath $source.VolumePath
    }
    $script:ownedProcess.WaitForExit()
    $code = $script:ownedProcess.ExitCode
    Stop-OwnedProcess
    if ($code -ne 0) { throw "qemu-img $Label failed ($code); see $prefix.stderr.log" }
    return Get-Content -LiteralPath ($prefix + '.stdout.log') -Raw -ErrorAction Stop
}

function Assert-Backup {
    Assert-HostFile -Path $backup
    $info = (Invoke-ImageTool -Arguments @('info', '--output=json', $backup) -Label 'info') | ConvertFrom-Json
    if ($info.format -ne 'qcow2' -or [UInt64]$info.'virtual-size' -ne $rootSize -or
        $info.PSObject.Properties.Name -contains 'backing-filename' -or
        ($info | ConvertTo-Json -Depth 20) -match '"data-file"\s*:') {
        throw 'Backup must be a standalone qcow2 of exactly the Linux partition size.'
    }
    $null = Invoke-ImageTool -Arguments @('check', '-f', 'qcow2', $backup) -Label 'check'
}

function Assert-NoCompetingQemu {
    param([string]$VolumePath)
    foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object { $_.Name -match '^qemu.*\.exe$' })) {
        if ($null -ne $script:ownedProcess -and -not $script:ownedProcess.HasExited -and
            $process.ProcessId -eq $script:ownedProcess.Id) { continue }
        if ([string]::IsNullOrWhiteSpace([string]$process.CommandLine)) { throw 'Cannot inspect a live QEMU command line.' }
        if ($process.CommandLine -match '(?i)PhysicalDrive' -or
            $process.CommandLine.IndexOf($VolumePath, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            throw "Competing QEMU disk access (PID $($process.ProcessId)); stop it first."
        }
    }
}

try {
    $source = Get-SourceFingerprint
    $sourceJson = $source | ConvertTo-Json -Depth 8 -Compress
    Assert-HostDirectory -Path (Split-Path $work -Parent)
    if (-not (Test-Path -LiteralPath $work)) { $null = New-Item -ItemType Directory -Path $work }
    Assert-HostDirectory -Path $work
    $ownerPath = Join-Path $work 'usb-root-export.owner.lock'
    if (Test-Path -LiteralPath $ownerPath) { Assert-HostFile -Path $ownerPath }
    # Exclusive ownership lock; a stale file is harmless, a live handle is not.
    $owner = [IO.File]::Open($ownerPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    Assert-HostFile -Path $QemuImgPath
    if ((Split-Path $QemuImgPath -Leaf) -ne 'qemu-img.exe') { throw 'QemuImgPath must name qemu-img.exe.' }
    if ($Action -eq 'Export') {
        if (-not $QemuNbdPath) { throw 'Export requires QemuNbdPath.' }
        Assert-HostFile -Path $QemuNbdPath
        if ((Split-Path $QemuNbdPath -Leaf) -ne 'qemu-nbd.exe') { throw 'QemuNbdPath must name qemu-nbd.exe.' }
        if (Test-Path -LiteralPath $stopPath) { throw 'Remove the stale nbd.stop marker before export.' }
        if (@(Get-NetTCPConnection -ErrorAction Stop | Where-Object { $_.LocalPort -eq 22704 }).Count) {
            throw 'Port 22704 is already in use.'
        }
    }
    Assert-NoCompetingQemu -VolumePath $source.VolumePath
    $sliceInfo = (Invoke-ImageTool -Arguments @('info', '--output=json', '--image-opts', $slice) -Label 'source-info') | ConvertFrom-Json
    if ($sliceInfo.format -ne 'raw' -or [UInt64]$sliceInfo.'virtual-size' -ne $rootSize) {
        throw 'The bounded raw slice does not match the Linux root partition size.'
    }
    if ($ProbeRead) {
        $probe = Open-PfRawDisk -Drive ([string]$source.VolumePath) -Access Read
        try {
            $bytes = New-Object byte[] 512
            if ((Read-PfRawBytes -Handle $probe -Bytes $bytes -Offset 0) -ne 512) { throw 'Short root-volume read.' }
        } finally { $probe.Dispose() }
    }

    if ($Action -eq 'Export') {
        Assert-HostFile -Path $metadataPath
        $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
        if ($metadata.Version -ne 1 -or -not $metadata.Verified -or $metadata.BackupPath -ne $backup -or
            ($metadata.SourceIdentity | ConvertTo-Json -Depth 8 -Compress) -cne $sourceJson) {
            throw 'Verified backup metadata does not match this USB/root partition.'
        }
        Assert-HostFile -Path $backup
        # Keep backup immutable throughout verification/export; no cached hash trust.
        $backupHandle = [IO.File]::Open($backup, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        Assert-Backup
        if ((Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash -cne $metadata.BackupSHA256) {
            throw 'Backup SHA256 differs from verified metadata.'
        }
    } else {
        if ((Test-Path -LiteralPath $backup) -or (Test-Path -LiteralPath $metadataPath)) {
            throw 'Backup or metadata already exists; refusing overwrite.'
        }
    }

    # Hold every recognized native volume even during read-only backup.
    $expectedPaths = @()
    foreach ($part in @(Get-PfDiskPartitions -Number $DiskNumber)) {
        $recognized = @($part | Get-Volume -ErrorAction Stop | Where-Object { $_.FileSystem })
        if (-not $recognized.Count) { continue }
        if (@($recognized | Where-Object { $_.FileSystem -notin @('FAT', 'FAT16', 'FAT32') }).Count) {
            throw 'Unexpected recognized USB filesystem; only native FAT volumes are allowed.'
        }
        $path = Get-PfVolumePath -Letter ([string]$part.DriveLetter) -DiskNumber $DiskNumber -PartitionNumber $part.PartitionNumber
        if (-not $path) { throw 'Cannot resolve a recognized FAT volume to lock.' }
        $expectedPaths += $path
    }
    Lock-PfDiskVolumes -Number $DiskNumber | ForEach-Object { $locks += $_ }
    foreach ($lock in $locks) {
        if (-not $lock.Locked -or -not $lock.Handle -or $lock.Handle.IsClosed -or $lock.Handle.IsInvalid) {
            throw "USB volume lock failed: $($lock.Path) $($lock.Detail)"
        }
    }
    foreach ($path in $expectedPaths) {
        if (@($locks | Where-Object { $_.Path -eq $path -and $_.Locked }).Count -ne 1) {
            throw "Recognized FAT volume not exclusively locked: $path"
        }
    }
    if (-not $expectedPaths.Count -or $locks.Count -ne $expectedPaths.Count) { throw 'USB volume lock coverage is incomplete.' }
    if ((Get-SourceFingerprint | ConvertTo-Json -Depth 8 -Compress) -cne $sourceJson) { throw 'Source identity/layout changed.' }
    Assert-NoCompetingQemu -VolumePath $source.VolumePath

    if ($Action -eq 'Backup') {
        # Atomically reserve a new destination; conversion may replace only our empty file.
        $reservation = [IO.File]::Open($backup, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $reservation.Dispose()
        $null = Invoke-ImageTool -Arguments @('convert', '--image-opts', '-O', 'qcow2', $slice, $backup) -Label 'convert'
        $backupHandle = [IO.File]::Open($backup, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        Assert-Backup
        if ((Get-SourceFingerprint | ConvertTo-Json -Depth 8 -Compress) -cne $sourceJson) { throw 'Source changed during backup.' }
        $metadata = [ordered]@{
            Version = 1; Verified = $true; CreatedUtc = [DateTime]::UtcNow.ToString('o')
            BackupPath = $backup; BackupSHA256 = (Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash
            SourceIdentity = $source
        }
        $stream = [IO.File]::Open($metadataPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $encoded = [Text.Encoding]::UTF8.GetBytes(($metadata | ConvertTo-Json -Depth 10))
            $stream.Write($encoded, 0, $encoded.Length)
            $stream.Flush($true)
        } finally { $stream.Dispose() }
        Write-Output "Verified root-only backup: $backup"
    } else {
        $null = Start-OwnedProcess -Exe $QemuNbdPath -Arguments @('--image-opts', '--bind', '127.0.0.1', '--port', '22704',
            '--persistent', '--shared', '1', $slice) -Label 'nbd'
        Write-Output "Supervised RW root-only NBD: 127.0.0.1:22704; stop marker: $stopPath"
        while (-not $script:ownedProcess.WaitForExit(500)) {
            Assert-NoCompetingQemu -VolumePath $source.VolumePath
            if (-not (Test-Path -LiteralPath $stopPath)) { continue }
            Assert-HostFile -Path $stopPath
            $active = @(Get-NetTCPConnection -ErrorAction Stop | Where-Object {
                $_.LocalPort -eq 22704 -and [string]$_.State -notin @('Listen', 'TimeWait', 'Closed', 'Bound')
            })
            if ($active.Count) {
                Write-Warning 'Stop refused: disconnect all NBD clients first.'
                Start-Sleep -Seconds 2
                continue
            }
            Stop-OwnedProcess
            break
        }
        if ($null -ne $script:ownedProcess) { throw "NBD exited unexpectedly: $($script:ownedProcess.ExitCode)" }
    }
} finally {
    # Nested finally deliberately does not release disk locks unless child exit is proven.
    Stop-OwnedProcess
    try { Release-PfVolumeLocks -Locks $locks } finally {
        if ($null -ne $backupHandle) { $backupHandle.Dispose() }
        if ($null -ne $owner) { $owner.Dispose() }
    }
}
