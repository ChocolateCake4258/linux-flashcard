# Whole-device baseline capture. Run locally as administrator; no elevation or SSH.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$ExpectedDevicePath,
    [string]$Destination = '',
    [ValidateRange(0, 2147483647)][int]$DiskNumber = 2,
    [switch]$Verification
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\pf-tools.psm1') -Force -ErrorAction Stop
if (-not (Test-PfIsAdmin)) { throw 'An administrator session is required; no automatic elevation.' }
if ([string]::IsNullOrWhiteSpace($Destination)) { $Destination = 'E:\linux-flashcard-v2\diagnostics\usb-baseline.img' }
$Destination = [IO.Path]::GetFullPath($Destination)
if ($Destination -notmatch '^E:\\[^:]+$' -or $Destination -match '["\r\n]') {
    throw 'Destination must be a regular absolute file path on host E:, without alternate streams.'
}
$partial = $Destination + '.partial'
$metadataPath = $Destination + '.json'
$hashPath = $Destination + '.sha256'
$work = Split-Path $Destination -Parent
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$qemuImg = Join-Path $repo 'qemu\qemu-img.exe'
$expectedSerial = '0E7113C55070'
[UInt64]$expectedSize = 31042043904
$identity = [pscustomobject]@{ Path = $ExpectedDevicePath; SerialNumber = $expectedSerial; Size = $expectedSize }
$physicalPath = "\\.\PhysicalDrive$DiskNumber"
$sourceOptions = "driver=raw,file.driver=host_device,file.filename=$physicalPath,file.read-only=on"
$destinationOptions = 'driver=raw,file.driver=file,file.filename=' + $partial.Replace(',', ',,') + ',file.read-only=on'
$locks = @()
$imageHandle = $null
$script:ownedProcess = $null
$script:ownedBirth = $null
$script:commands = @()
$logPrefix = Join-Path $work ('usb-capture-' + [Guid]::NewGuid().ToString('N'))
$startedUtc = [DateTime]::UtcNow.ToString('o')

function Assert-HostDirectory {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or $item.FullName -notmatch '^([A-Za-z]):\\') {
        throw "Not an existing local drive-letter directory: $Path"
    }
    $letter = $Matches[1]
    for ($parent = $item; $null -ne $parent; $parent = $parent.Parent) {
        if ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Reparse ancestor forbidden: $($parent.FullName)"
        }
    }
    $mapped = @(Get-Partition -DriveLetter $letter -ErrorAction Stop)
    if ($mapped.Count -ne 1) { throw "Ambiguous host disk: $Path" }
    $hostDisk = Get-Disk -Number $mapped[0].DiskNumber -ErrorAction Stop
    if ($hostDisk.Number -eq $DiskNumber -or [string]$hostDisk.BusType -in @('USB', 'Unknown') -or
        [string](Get-Volume -DriveLetter $letter -ErrorAction Stop).DriveType -ne 'Fixed') {
        throw "Path must be on a fixed non-USB host disk: $Path"
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

function New-HostFile {
    param([string]$Path, [string]$Text = '')
    Assert-HostDirectory -Path (Split-Path $Path -Parent)
    # CreateNew also refuses existing files, directories and reparse destinations.
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally { $stream.Dispose() }
}

function Assert-NoCompetingQemu {
    foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
        $_.Name -match '(?i)(qemu|nbd)'
    })) {
        if ($null -ne $script:ownedProcess -and -not $script:ownedProcess.HasExited -and
            $process.ProcessId -eq $script:ownedProcess.Id) { continue }
        if ([string]::IsNullOrWhiteSpace([string]$process.CommandLine)) {
            throw "Cannot inspect QEMU/NBD command line (PID $($process.ProcessId))."
        }
        if ($process.CommandLine -match '(?i)PhysicalDrive|Volume\{') {
            throw "Competing QEMU/NBD raw-device access (PID $($process.ProcessId)); stop it first."
        }
    }
}

function Stop-OwnedProcess {
    # Retain the original Process and native handle; never reopen/kill by PID.
    if ($null -eq $script:ownedProcess) { return }
    while (-not $script:ownedProcess.HasExited) {
        if ($script:ownedProcess.StartTime.ToUniversalTime().Ticks -ne $script:ownedBirth) {
            throw 'Owned process birth time changed; refusing cleanup.'
        }
        try { $script:ownedProcess.Kill() } catch {
            if (-not $script:ownedProcess.HasExited) { Write-Warning "Waiting for owned qemu-img cleanup: $_" }
        }
        $null = $script:ownedProcess.WaitForExit(1000)
    }
    $script:ownedProcess.WaitForExit()
    $script:ownedProcess.Dispose()
    $script:ownedProcess = $null
}

function Invoke-ImageTool {
    param([string[]]$Arguments, [string]$Label)
    if ($null -ne $script:ownedProcess) { throw 'A child is already owned.' }
    Assert-NoCompetingQemu
    Assert-HostFile -Path $qemuImg
    $prefix = $logPrefix + '-' + $Label
    $quoted = ConvertTo-PfArgumentList -Arguments $Arguments -What $Label
    $command = '"' + $qemuImg + '" ' + (Join-PfArguments $quoted)
    New-HostFile -Path ($prefix + '.command.txt') -Text ($command + "`n")
    New-HostFile -Path ($prefix + '.stdout.log')
    New-HostFile -Path ($prefix + '.stderr.log')
    $record = [pscustomobject]@{
        Command = $command; StdoutPath = $prefix + '.stdout.log'; StderrPath = $prefix + '.stderr.log'
        CommandPath = $prefix + '.command.txt'; ExitCode = $null
    }
    $script:commands += $record
    Write-Host "COMMAND=$command"
    Write-Host "PROGRESS_LOG=$($record.StderrPath)"
    $script:ownedProcess = Start-Process -FilePath $qemuImg -ArgumentList $quoted -WorkingDirectory $work `
        -RedirectStandardOutput $record.StdoutPath -RedirectStandardError $record.StderrPath `
        -WindowStyle Hidden -PassThru -ErrorAction Stop
    $null = $script:ownedProcess.Handle
    $script:ownedBirth = $script:ownedProcess.StartTime.ToUniversalTime().Ticks
    while (-not $script:ownedProcess.WaitForExit(500)) { Assert-NoCompetingQemu }
    $script:ownedProcess.WaitForExit()
    $record.ExitCode = $script:ownedProcess.ExitCode
    New-HostFile -Path ($prefix + '.exit-code.txt') -Text ([string]$record.ExitCode + "`n")
    Stop-OwnedProcess
    if ($record.ExitCode -ne 0) { throw "qemu-img $Label failed ($($record.ExitCode)); see $($record.StderrPath)" }
    return Get-Content -LiteralPath $record.StdoutPath -Raw -ErrorAction Stop
}

try {
    $source = Assert-PfUsbDisk -Number $DiskNumber -Identity $identity
    Assert-HostDirectory -Path $work
    Assert-HostFile -Path $qemuImg
    foreach ($path in @($Destination, $partial, $metadataPath, $hashPath)) {
        if (Test-Path -LiteralPath $path) { throw "Refusing existing destination/sidecar: $path" }
    }
    Assert-NoCompetingQemu
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
    $null = Assert-PfUsbDisk -Number $DiskNumber -Identity $identity
    $info = (Invoke-ImageTool -Arguments @('info', '--output=json', '--image-opts', $sourceOptions) -Label 'source-info') | ConvertFrom-Json
    if ($info.format -ne 'raw' -or [UInt64]$info.'virtual-size' -ne $expectedSize) {
        throw 'Whole host_device geometry differs from the confirmed USB size.'
    }
    New-HostFile -Path $partial
    $null = Assert-PfUsbDisk -Number $DiskNumber -Identity $identity
    $null = Invoke-ImageTool -Arguments @('convert', '-p', '--image-opts', '-O', 'raw', $sourceOptions, $partial) -Label 'convert'
    Assert-HostFile -Path $partial
    $imageHandle = [IO.File]::Open($partial, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    if ([UInt64]$imageHandle.Length -ne $expectedSize) { throw 'Captured image length is not exactly 31042043904 bytes.' }
    $null = Assert-PfUsbDisk -Number $DiskNumber -Identity $identity
    if ($Verification) {
        $null = Invoke-ImageTool -Arguments @('compare', '-p', '--image-opts', $sourceOptions, $destinationOptions) -Label 'compare'
        $null = Assert-PfUsbDisk -Number $DiskNumber -Identity $identity
    }
    $sha = (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash
    $metadata = [ordered]@{
        Version = 1; StartedUtc = $startedUtc; CompletedUtc = [DateTime]::UtcNow.ToString('o')
        Destination = $Destination; Size = $expectedSize; SHA256 = $sha; Verified = [bool]$Verification
        SourceIdentity = [ordered]@{
            DevicePath = [string]$source.Path; PhysicalDevicePath = $physicalPath
            SerialNumber = ([string]$source.SerialNumber).Trim(); Size = [UInt64]$source.Size; DiskNumber = $DiskNumber
        }
        Commands = $script:commands
    }
    New-HostFile -Path $hashPath -Text ($sha + '  ' + (Split-Path $Destination -Leaf) + "`n")
    New-HostFile -Path $metadataPath -Text (($metadata | ConvertTo-Json -Depth 8) + "`n")
    $imageHandle.Dispose()
    $imageHandle = $null
    Assert-HostDirectory -Path $work
    Assert-HostFile -Path $partial
    # Same-directory Move has no overwrite option: only a complete capture is published.
    [IO.File]::Move($partial, $Destination)
    Write-Warning 'Keep the captured baseline immutable. Use read-only opens/backing files; later USB changes are not part of this capture. The file read-only attribute is not a security boundary.'
    (Get-Item -LiteralPath $Destination -Force).IsReadOnly = $true
    Write-Output "CAPTURED_IMAGE=$Destination"
    Write-Output "CAPTURED_BYTES=$expectedSize"
    Write-Output "VERIFIED=$([bool]$Verification)"
    Write-Output "SHA256=$sha"
    Write-Output "METADATA=$metadataPath"
} finally {
    # Never release USB locks until the sole owned qemu-img has definitely exited.
    Stop-OwnedProcess
    try { Release-PfVolumeLocks -Locks $locks } finally {
        if ($null -ne $imageHandle) { $imageHandle.Dispose() }
    }
    # Failed captures and their host logs/sidecars are intentionally retained.
}
