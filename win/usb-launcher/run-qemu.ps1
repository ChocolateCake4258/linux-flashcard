# Run the USB system in QEMU only while Windows volume locks are held.
param(
    [string]$DevicePath,
    [AllowEmptyString()][string]$SerialNumber,
    [long]$DeviceSize,
    [int]$RamMb = 0,
    [int]$Cores = 0,
    [ValidateSet('Auto', 'WHPX', 'TCG')][string]$Accel = 'Auto',
    [switch]$Runtime,
    [switch]$Elevated
)

try { [Console]::OutputEncoding = [Text.Encoding]::UTF8; $OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$ErrorActionPreference = 'Stop'
$locks = @()
$exitCode = 1
$runtimeDir = $null
$qemuProcess = $null
$stderrLog = $null

function Get-LauncherProfile {
    param([int]$RamMb, [int]$Cores)
    $hostInfo = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $totalMb = [Math]::Floor($hostInfo.TotalPhysicalMemory / 1MB)
    $freeMb = [Math]::Floor($os.FreePhysicalMemory / 1024)
    $logical = [int]$hostInfo.NumberOfLogicalProcessors
    if ($logical -lt 1) { throw 'Cannot determine host logical CPU count.' }
    if ($Cores -lt 0 -or $Cores -gt $logical) { throw "Cores must be 0 (auto) or 1..$logical." }
    $selectedCores = if ($Cores -eq 0) { [Math]::Min(4, [Math]::Max(1, [Math]::Floor($logical / 2))) } else { $Cores }
    if ($RamMb -eq 0) {
        $selectedRam = [Math]::Min(6144, [Math]::Floor($totalMb / 2 / 1024) * 1024)
        $selectedRam = [Math]::Min($selectedRam, [Math]::Floor(($freeMb - 2048) / 1024) * 1024)
        if ($selectedRam -lt 2048) {
            throw "Insufficient host memory for auto RAM: total $totalMb MB, free $freeMb MB; need at least 2048 MB guest RAM plus 2048 MB free for Windows, and at most half of total RAM."
        }
    } else {
        if ($RamMb -lt 2048 -or $RamMb -gt ($totalMb - 4096)) {
            throw "RamMb must be 0 (auto) or at least 2048 MB and at most total RAM minus 4096 MB ($($totalMb - 4096) MB)."
        }
        if ($freeMb -lt ($RamMb + 2048)) {
            throw "Insufficient available memory: requested $RamMb MB, free $freeMb MB; require $($RamMb + 2048) MB including the 2048 MB Windows reserve."
        }
        $selectedRam = $RamMb
    }
    [pscustomobject]@{ RamMb = [int]$selectedRam; Cores = [int]$selectedCores; FreeMb = $freeMb }
}

# Reject redirected directories as well as network paths: drive-letter mapping
# alone cannot establish which disk backs a junction or a mounted folder.
function Get-LauncherDirectoryDisk {
    param([string]$Directory)
    $item = Get-Item -LiteralPath $Directory -ErrorAction Stop
    if (-not $item.PSIsContainer -or $item.FullName -notmatch '^([A-Za-z]):\\') {
        throw 'The launcher/runtime must be on a local drive-letter volume.'
    }
    $letter = $Matches[1]
    for ($parent = $item; $null -ne $parent; $parent = $parent.Parent) {
        if ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Redirected launcher/runtime directory is not supported: $($parent.FullName)"
        }
    }
    $partitions = @(Get-Partition -DriveLetter $letter -ErrorAction Stop)
    if ($partitions.Count -ne 1) { throw 'Cannot uniquely resolve the launcher/runtime disk.' }
    return Get-Disk -Number $partitions[0].DiskNumber -ErrorAction Stop
}

try {
    Import-Module (Join-Path $PSScriptRoot 'lib\pf-tools.psm1') -Force -ErrorAction Stop
    foreach ($name in @('Assert-PfUsbDisk', 'Get-PfDiskPartitions', 'Lock-PfDiskVolumes', 'Release-PfVolumeLocks')) {
        $null = Get-Command $name -Module pf-tools -ErrorAction Stop
    }
    $pwshPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

    if (-not $Runtime) {
        # The actual launcher location selects the USB, never a global label.
        $disk = Get-LauncherDirectoryDisk -Directory $PSScriptRoot
        $identity = [pscustomobject]@{
            Path = [string]$disk.Path
            SerialNumber = ([string]$disk.SerialNumber).Trim()
            Size = [long]$disk.Size
        }
        $disk = Assert-PfUsbDisk -Number $disk.Number -Identity $identity
        $qemuSource = Find-PfQemu -ScriptDir $PSScriptRoot
        if (-not $qemuSource) { throw 'QEMU was not found.' }
        $temp = [IO.Path]::GetTempPath()
        $hostDisk = Get-LauncherDirectoryDisk -Directory $temp
        if ($hostDisk.Number -eq $disk.Number) { throw 'Host TEMP is on the destination USB disk.' }
        $runtimeDir = Join-Path $temp ('pf-usb-qemu-' + [Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $runtimeDir -ErrorAction Stop
        $null = New-Item -ItemType Directory -Path (Join-Path $runtimeDir 'lib') -ErrorAction Stop
        $hostScript = Join-Path $runtimeDir 'run-qemu.ps1'
        Copy-Item -LiteralPath $PSCommandPath -Destination $hostScript -ErrorAction Stop
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'lib\pf-tools.psm1') -Destination (Join-Path $runtimeDir 'lib\pf-tools.psm1') -ErrorAction Stop
        $qemuSourceDir = Split-Path $qemuSource -Parent
        $stagedQemu = Join-Path $runtimeDir 'qemu'
        $null = New-Item -ItemType Directory -Path $stagedQemu -ErrorAction Stop
        Copy-Item -Path (Join-Path $qemuSourceDir '*') -Destination $stagedQemu -Recurse -Force -ErrorAction Stop
        if (@(Get-ChildItem -LiteralPath $qemuSourceDir -Recurse -File -Force).Count -ne
            @(Get-ChildItem -LiteralPath $stagedQemu -Recurse -File -Force).Count -or
            -not (Test-Path -LiteralPath (Join-Path $stagedQemu (Split-Path $qemuSource -Leaf)))) {
            throw 'Host QEMU staging is incomplete.'
        }

        # Encode PowerShell literals, not a hand-joined native command line.
        # This preserves quotes, spaces, trailing backslashes and empty serials.
        $command = "& '" + $hostScript.Replace("'", "''") + "' -Runtime -Elevated -DevicePath '" +
            $identity.Path.Replace("'", "''") + "' -SerialNumber '" +
            $identity.SerialNumber.Replace("'", "''") + "' -DeviceSize " +
            $identity.Size.ToString([Globalization.CultureInfo]::InvariantCulture) +
            ' -RamMb ' + $RamMb.ToString([Globalization.CultureInfo]::InvariantCulture) +
            ' -Cores ' + $Cores.ToString([Globalization.CultureInfo]::InvariantCulture) +
            " -Accel '" + $Accel + "'"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $launchArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)
        Write-Host "Host runtime and log: $runtimeDir"
        if (-not (Test-PfIsAdmin)) {
            $exitCode = Invoke-PfElevated -FilePath $pwshPath -ArgumentList $launchArgs -WorkDir $runtimeDir
        } else {
            # Do not inherit a working directory on a volume about to be locked.
            Push-Location -LiteralPath $runtimeDir
            try {
                & $pwshPath @launchArgs
                $exitCode = $LASTEXITCODE
            } finally { Pop-Location }
        }
    } else {
        if (-not (Test-PfIsAdmin)) { throw 'The host runtime requires administrator rights.' }
        if (-not $DevicePath -or $DeviceSize -le 0) { throw 'Missing saved USB disk identity.' }
        $identity = [pscustomobject]@{ Path = $DevicePath; SerialNumber = $SerialNumber; Size = $DeviceSize }
        $matches = @(Get-Disk -ErrorAction Stop | Where-Object {
            [string]$_.Path -eq $identity.Path -and
            ([string]$_.SerialNumber).Trim() -eq $identity.SerialNumber -and
            [long]$_.Size -eq $identity.Size
        })
        if ($matches.Count -ne 1) { throw 'Saved USB identity does not resolve to exactly one disk.' }
        $disk = Assert-PfUsbDisk -Number $matches[0].Number -Identity $identity
        $diskN = $disk.Number
        $hostDisk = Get-LauncherDirectoryDisk -Directory $PSScriptRoot
        if ($hostDisk.Number -eq $diskN) { throw 'Runtime is on the destination USB disk.' }
        if (@(Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -Force -ErrorAction Stop | Where-Object {
            $_.Attributes -band [IO.FileAttributes]::ReparsePoint
        }).Count) { throw 'Runtime contains redirected files or directories.' }

        # Only the staged binary and its staged firmware may be used.
        $qemu = Find-PfQemu -Exe (Join-Path $PSScriptRoot 'qemu')
        if (-not $qemu -or (Split-Path $qemu -Parent) -ne (Join-Path $PSScriptRoot 'qemu')) {
            throw 'Staged QEMU binary is missing.'
        }
        $firmware = Find-PfOvmf -QemuExe $qemu
        if (-not $firmware -or -not (Test-Path -LiteralPath $firmware -PathType Leaf)) {
            throw 'Staged UEFI firmware is missing; BIOS fallback is not permitted.'
        }
        $profile = Get-LauncherProfile -RamMb $RamMb -Cores $Cores
        $qemuArgs = Get-PfQemuBaseArgs -RamMb $profile.RamMb -Cores $profile.Cores -Uefi -QemuExe $qemu -ScriptDir $PSScriptRoot
        if ($Accel -ne 'Auto') {
            $qemuArgs = @(for ($i = 0; $i -lt $qemuArgs.Count; $i++) {
                if ($qemuArgs[$i] -eq '-accel') {
                    $i++
                    if ($Accel -eq 'WHPX' -and $qemuArgs[$i] -like 'whpx*') { '-accel'; $qemuArgs[$i] }
                    elseif ($Accel -eq 'TCG' -and $qemuArgs[$i] -like 'tcg*') { '-accel'; 'tcg,thread=multi' }
                } else { $qemuArgs[$i] }
            })
        }
        $firmwareDrive = "if=pflash,format=raw,readonly=on,file=$firmware"
        if ($qemuArgs -notcontains $firmwareDrive) { throw 'QEMU arguments do not include the verified UEFI firmware.' }
        $qemuArgs = @($qemuArgs | ForEach-Object {
            if ($_ -eq $firmwareDrive) { "if=pflash,format=raw,readonly=on,file=$($firmware.Replace(',', ',,'))" }
            else { $_ }
        })
        $qemuArgs += @('-drive', "file=\\.\PhysicalDrive$diskN,format=raw,media=disk,if=virtio", '-boot', 'order=c,once=c')
        $log = Join-Path $PSScriptRoot 'qemu-usb.log'
        # QEMU option values escape commas by doubling them.
        $qemuArgs += @('-chardev', "file,id=pfser,path=$($log.Replace(',', ',,')),append=on", '-serial', 'chardev:pfser')
        Write-PfHeader 'USB QEMU: exclusive Windows volume locks required'
        Write-Host "USB: \\.\PhysicalDrive$diskN ($($disk.FriendlyName))"
        Write-Host "Runtime log: $log"
        $accelSelection = if ($Accel -eq 'Auto') { 'WHPX with TCG fallback' } else { $Accel }
        Write-Host "Profile: RAM $($profile.RamMb) MB / $($profile.Cores) vCPU; acceleration policy $accelSelection (requested: RAM $RamMb MB, cores $Cores, accel $Accel; 0 = auto)."
        Write-Warning 'Acceleration policy is not proof of actual acceleration. Check QEMU stderr for WHPX warnings or TCG fallback. No Windows hypervisor settings will be changed automatically.'
        Write-Host 'Close Explorer and all programs using the USB. Guest writes persist on the USB.' -ForegroundColor Yellow
        $null = Read-Host 'Enter to lock volumes and start QEMU'

        # Re-select auto RAM if other applications consumed memory during the prompt.
        $profile = Get-LauncherProfile -RamMb $RamMb -Cores $Cores
        for ($i = 0; $i -lt $qemuArgs.Count; $i++) {
            if ($qemuArgs[$i] -eq '-m') { $qemuArgs[$i + 1] = "$($profile.RamMb)M" }
            if ($qemuArgs[$i] -eq '-smp') { $qemuArgs[$i + 1] = [string]$profile.Cores }
        }
        Write-Host "Launch profile: RAM $($profile.RamMb) MB / $($profile.Cores) vCPU; acceleration policy $accelSelection (requested $Accel)."

        $disk = Assert-PfUsbDisk -Number $diskN -Identity $identity
        $parts = @(Get-PfDiskPartitions -Number $diskN)
        $expectedPaths = @()
        foreach ($part in $parts) {
            $gptType = ([string]$part.GptType).Trim('{}')
            if ($gptType -in '21686148-6449-6e6f-744e-656564454649', '0fc63daf-8483-4772-8e79-3d69d8477de4') {
                $mountedFilesystems = @($part | Get-Volume -ErrorAction Stop | Where-Object { $_.FileSystem })
                if (-not $mountedFilesystems.Count) { continue }
            }
            # Independently enumerate associated Windows volumes, including
            # letterless ones, so a helper omission cannot mean "safe to write".
            $volumes = @(Get-CimAssociatedInstance -InputObject $part -ResultClassName MSFT_Volume -ErrorAction Stop)
            $volumePath = Get-PfVolumePath -Letter ([string]$part.DriveLetter) -DiskNumber $diskN -PartitionNumber $part.PartitionNumber
            if ($volumes.Count -or $part.DriveLetter -or @($part.AccessPaths | Where-Object { $_ -like '\\?\Volume{*' }).Count) {
                if (-not $volumePath) { throw "Cannot resolve volume on partition $($part.PartitionNumber)." }
            }
            if ($volumePath) { $expectedPaths += $volumePath }
        }
        # Capture results as they arrive so finally can release partial results.
        Lock-PfDiskVolumes -Number $diskN | ForEach-Object { $locks += $_ }
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
        $null = Assert-PfUsbDisk -Number $diskN -Identity $identity
        $currentParts = @(Get-PfDiskPartitions -Number $diskN)
        $before = @($parts | ForEach-Object { "$($_.PartitionNumber):$($_.Offset):$($_.Size)" })
        $after = @($currentParts | ForEach-Object { "$($_.PartitionNumber):$($_.Offset):$($_.Size)" })
        if ($before.Count -ne $after.Count -or
            (($before | Sort-Object) -join '|') -ne (($after | Sort-Object) -join '|')) {
            throw 'USB partition layout changed during locking.'
        }
        Push-Location -LiteralPath $PSScriptRoot
        try {
            $freeMb = [Math]::Floor((Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).FreePhysicalMemory / 1024)
            if ($freeMb -lt ($profile.RamMb + 2048)) { throw "Available memory changed before QEMU launch: free $freeMb MB; require $($profile.RamMb + 2048) MB. QEMU was not started." }
            $stdoutLog = Join-Path $PSScriptRoot 'qemu-stdout.log'
            $stderrLog = Join-Path $PSScriptRoot 'qemu-stderr.log'
            $commandLog = Join-Path $PSScriptRoot 'qemu-command.txt'
            $nativeArgs = ConvertTo-PfArgumentList -Arguments $qemuArgs
            $commandLine = '"' + $qemu + '" ' + ($nativeArgs -join ' ')
            Set-Content -LiteralPath $commandLog -Value $commandLine -Encoding UTF8
            Write-Host "QEMU command: $commandLine"
            Write-Host "Host logs: $commandLog; $stdoutLog; $stderrLog; serial: $log"
            $qemuProcess = Start-Process -FilePath $qemu -ArgumentList $nativeArgs -WorkingDirectory $PSScriptRoot -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog -PassThru
            # Retain the process handle so ExitCode remains available after exit.
            $null = $qemuProcess.Handle
            $qemuProcess.WaitForExit()
            $exitCode = $qemuProcess.ExitCode
            if ($exitCode -ne 0) { Write-Host "QEMU failed with exit code $exitCode. See $stderrLog and $log" -ForegroundColor Red }
            else { Write-Host 'QEMU exited successfully.' -ForegroundColor Green }
        } finally { Pop-Location }
    }
} catch {
    Write-Host "[!] $($_.Exception.Message)" -ForegroundColor Red
    $exitCode = 1
} finally {
    # Never unlock a disk still owned by our child. Do not kill by name or PID.
    if ($null -ne $qemuProcess) {
        if (-not $qemuProcess.HasExited) { $qemuProcess.Kill() }
        $qemuProcess.WaitForExit()
        $qemuProcess.Dispose()
    }
    if ($locks.Count) { Release-PfVolumeLocks -Locks $locks }
    if ($stderrLog -and (Test-Path -LiteralPath $stderrLog)) {
        Write-Host 'QEMU stderr (last 20 lines):'
        Get-Content -LiteralPath $stderrLog -Tail 20 | ForEach-Object { Write-Host $_ }
        $accelMessages = @(Select-String -LiteralPath $stderrLog -Pattern '(?i)whpx|tcg|fall(?:ing)?\s*back|fallback')
        if ($accelMessages.Count) {
            Write-Warning 'QEMU acceleration diagnostics (warnings/fallback text do not alone prove the active accelerator):'
            $accelMessages | ForEach-Object { Write-Host $_.Line }
        } else { Write-Host 'No WHPX/TCG/fallback text found in stderr; actual acceleration is not verified.' }
    }
    # Keep the unique host runtime for diagnostics; never write logs to the USB.
    if ($runtimeDir) { Write-Host "Host runtime retained: $runtimeDir" }
    if (-not $Runtime) {
        Write-Host "Launcher exit code: $exitCode"
        $null = Read-Host 'Enter to close the launcher'
    }
}
exit $exitCode
