# Persistent host-only diagnostic VM. The RAW source is never a writable drive.
# Disconnect/unmount every NBD client before Stop -StopTarget Nbd -NbdClientsDisconnected.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Prepare', 'Configure', 'Export', 'Boot', 'Stop')][string]$Action,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$WorkspaceDirectory,
    [string]$SourceImage = '',
    [ValidateRange(1024, 65535)][int]$NbdPort = 22703,
    [ValidateRange(1024, 65535)][int]$SerialPort = 22701,
    [ValidateRange(1024, 65535)][int]$QmpPort = 22702,
    [ValidateRange(512, 131072)][int]$RamMb = 8192,
    [ValidateRange(1, 128)][int]$Cores = 4,
    [ValidateSet('Nbd', 'VM')][string]$StopTarget = 'VM',
    [switch]$NbdClientsDisconnected,
    [switch]$Wait,
    [ValidateSet('Auto', 'WHPX', 'TCG')][string]$Accel = 'Auto',
    [ValidateSet('Westmere', 'Haswell-noTSX')][string]$CpuModel = 'Westmere',
    [ValidateSet('None', 'Default')][string]$Display = 'None',
    [switch]$ReadOnlyExport
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'diagnostic-vm.ps1 requires Windows with PowerShell 5.1 or newer and host QEMU; no action was performed.'
}
if ($ReadOnlyExport -and $Action -ne 'Export') { throw '-ReadOnlyExport is only valid for Export.' }

function Get-SafePath {
    param([string]$Path)
    if ($Path -notmatch '^[A-Za-z]:[\\/]' -or $Path -match '[\x00-\x1f"\r\n]' -or
        $Path.Substring(2).Contains(':') -or $Path -match '(?i)PhysicalDrive') {
        throw "Only absolute local file paths are allowed: $Path"
    }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $cursor = $full
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Reparse points are forbidden: $cursor"
            }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
    $letter = $full.Substring(0, 1)
    $partitions = @(Get-Partition -DriveLetter $letter -ErrorAction Stop)
    if ($partitions.Count -ne 1) { throw "Cannot uniquely identify host volume: $full" }
    $disk = Get-Disk -Number $partitions[0].DiskNumber -ErrorAction Stop
    $drive = New-Object IO.DriveInfo ($letter + ':\')
    if ($drive.DriveType -ne [IO.DriveType]::Fixed -or
        [string]$disk.BusType -in @('USB', 'SD', 'MMC', 'Unknown')) {
        throw "Path must be on a known fixed non-USB host disk: $full"
    }
    return $full
}

function Write-Metadata {
    $text = $script:metadata | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($script:metadataPath, $text + "`n", [Text.UTF8Encoding]::new($true))
}

function Write-Command {
    param([string]$Executable, [string[]]$Arguments)
    $quoted = ConvertTo-PfArgumentList -Arguments $Arguments -What 'diagnostic VM'
    [IO.File]::AppendAllText((Join-Path $workspace 'commands.log'),
        "$(Get-Date -Format o) $Executable $(Join-PfArguments $quoted)`n", [Text.UTF8Encoding]::new($true))
    return ,$quoted
}

function Assert-SourceFingerprint {
    $item = Get-Item -LiteralPath $source -Force
    if ($item.PSIsContainer -or [uint64]$item.Length -ne [uint64]$metadata.SourceLength -or
        $item.LastWriteTimeUtc.ToString('o') -cne [string]$metadata.SourceLastWriteTimeUtc) {
        throw 'Source image length or modification time changed. Refusing to use this overlay.'
    }
}

function Assert-Overlay {
    $argsList = @('info', '--output=json', '--backing-chain', $overlay)
    $null = Write-Command $qemuImg $argsList
    $output = & $qemuImg @argsList
    if ($LASTEXITCODE -ne 0) { throw 'qemu-img info failed.' }
    $chain = ($output -join "`n") | ConvertFrom-Json
    if ($chain.Count -ne 2) { throw 'Expected exactly one qcow2 overlay and one RAW backing file.' }
    $top = $chain[0]
    $base = $chain[1]
    if ($top.format -cne 'qcow2' -or $top.'backing-filename-format' -cne 'raw' -or
        (Get-SafePath $top.filename) -ine $overlay -or
        (Get-SafePath $top.'backing-filename') -ine $source -or
        (Get-SafePath $top.'full-backing-filename') -ine $source -or
        $base.format -cne 'raw' -or (Get-SafePath $base.filename) -ine $source) {
        throw 'Overlay backing chain does not match the exact verified RAW source.'
    }
    Assert-SourceFingerprint
}

function Get-OwnedProcess {
    param([ValidateSet('Nbd', 'VM')][string]$Kind)
    $record = $metadata.Processes.$Kind
    $savedId = if ($Kind -eq 'Nbd') { $metadata.NbdProcessID } else { $metadata.VmProcessID }
    if ($null -eq $record) {
        if ($null -ne $savedId) { throw 'Inconsistent process metadata.' }
        return $null
    }
    if ([int]$record.ProcessID -le 0 -or [int]$record.ProcessID -ne [int]$savedId) {
        throw 'Invalid saved process identity.'
    }
    $process = Get-Process -Id ([int]$record.ProcessID) -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $null }
    $expectedExe = if ($Kind -eq 'Nbd') { $qemuNbd } else { $qemu }
    $cim = Get-CimInstance Win32_Process -Filter "ProcessId = $($record.ProcessID)"
    if ($null -eq $cim -or [string]::IsNullOrEmpty($cim.CommandLine) -or
        $cim.ExecutablePath -ine $expectedExe -or $cim.Name -ine ([IO.Path]::GetFileName($expectedExe)) -or
        $process.StartTime.ToUniversalTime().ToString('o') -cne [string]$record.ProcessStartTimeUtc -or
        $cim.CommandLine -cne [string]$record.CommandLine -or
        $cim.CommandLine.IndexOf($overlay, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "PID $($record.ProcessID) is not the saved owned $Kind process; refusing to signal it."
    }
    return $process
}

function Assert-NoUnknownProcesses {
    # Also catch an interrupted launch that never saved its identity.
    $known = @()
    foreach ($kind in @('Nbd', 'VM')) {
        $p = Get-OwnedProcess $kind
        if ($null -ne $p) { $known += $p.Id }
    }
    foreach ($p in @(Get-CimInstance Win32_Process)) {
        if ($known -contains [int]$p.ParentProcessId) {
            if ($p.Name -ieq 'conhost.exe' -and $p.ExecutablePath -ieq (Join-Path $env:SystemRoot 'System32\conhost.exe')) { continue }
            throw "Owned QEMU has an untracked running child PID $($p.ProcessId); refusing action."
        }
        if ($p.Name -match '^qemu.*\.exe$' -and
            ([string]::IsNullOrEmpty($p.CommandLine) -or
             $p.CommandLine.IndexOf($workspace, [StringComparison]::OrdinalIgnoreCase) -ge 0) -and
            $known -notcontains [int]$p.ProcessId) {
            throw "Untracked or uninspectable QEMU PID $($p.ProcessId); refusing action."
        }
    }
}

function Assert-FreePorts {
    param([int[]]$Ports)
    $listeners = @()
    try {
        foreach ($port in $Ports) {
            $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $port)
            $listener.Server.ExclusiveAddressUse = $true
            $listeners += $listener
            $listener.Start()
        }
    } catch { throw "A requested loopback port is unavailable: $($_.Exception.Message)" }
    finally { foreach ($listener in $listeners) { $listener.Stop() } }
}

function Start-OwnedProcess {
    param([string]$Kind, [string]$Executable, [string[]]$Arguments)
    $quoted = Write-Command $Executable $Arguments
    $stamp = [Guid]::NewGuid().ToString('N')
    $stdout = Join-Path $workspace "$Kind-$stamp-stdout.log"
    $stderr = Join-Path $workspace "$Kind-$stamp-stderr.log"
    $windowStyle = if ($Kind -eq 'VM' -and $Display -eq 'Default') { 'Normal' } else { 'Hidden' }
    $p = Start-Process -FilePath $Executable -ArgumentList $quoted -WorkingDirectory $workspace `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WindowStyle $windowStyle -PassThru
    $null = $p.Handle
    $startTime = $p.StartTime.ToUniversalTime().ToString('o')
    $cim = Get-CimInstance Win32_Process -Filter "ProcessId = $($p.Id)"
    if ($null -eq $cim -or $cim.ExecutablePath -ine $Executable -or
        [string]::IsNullOrEmpty($cim.CommandLine)) {
        throw "Cannot capture launched process identity. Inspect logs and PID $($p.Id); no unverified process will be killed."
    }
    $metadata.Processes.$Kind = [pscustomobject]@{
        ProcessID = $p.Id; ProcessStartTimeUtc = $startTime
        ExecutablePath = $Executable; CommandLine = $cim.CommandLine
        StdoutLog = $stdout; StderrLog = $stderr
    }
    if ($Kind -eq 'Nbd') { $metadata.NbdProcessID = $p.Id } else { $metadata.VmProcessID = $p.Id }
    Write-Metadata
    Start-Sleep -Seconds 1
    if ($p.HasExited) { throw "$Kind exited (code $($p.ExitCode)); see $stderr" }
    $null = Get-OwnedProcess $Kind
    Write-Host "$Kind running as PID $($p.Id). Logs and persistent state: $workspace"
    if ($Wait) {
        # A scheduled supervisor must stay alive, but Stop needs the action lock.
        $script:lock.Dispose()
        $script:lock = $null
        $p.WaitForExit()
    }
}

function Send-Powerdown {
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $pending = $client.ConnectAsync('127.0.0.1', [int]$metadata.QmpPort)
        if (-not $pending.Wait(3000)) { throw 'QMP connect timed out.' }
        $stream = $client.GetStream()
        $stream.ReadTimeout = 3000
        $stream.WriteTimeout = 3000
        $reader = [IO.StreamReader]::new($stream)
        $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
        $writer.AutoFlush = $true
        $greeting = $reader.ReadLine() | ConvertFrom-Json
        if ($null -eq $greeting.PSObject.Properties['QMP']) { throw 'Invalid QMP greeting.' }
        foreach ($command in @('qmp_capabilities', 'system_powerdown')) {
            $payload = @{ execute = $command; id = $command } | ConvertTo-Json -Compress
            $null = Write-Command 'QMP' @($payload)
            $writer.WriteLine($payload)
            do {
                $line = $reader.ReadLine()
                if ($null -eq $line) { throw 'QMP disconnected.' }
                $reply = $line | ConvertFrom-Json
            } while ($null -eq $reply.PSObject.Properties['id'] -or $reply.id -ne $command)
            if ($null -ne $reply.PSObject.Properties['error']) { throw "QMP rejected $command`: $line" }
        }
    } finally { $client.Dispose() }
}

$lock = $null
try {
    $repo = Get-SafePath (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
    if ($repo -notmatch '^(?i)E:\\') { throw 'Run the host repository on E:, not a USB deployment.' }
    $parent = Get-SafePath (Join-Path $repo 'diagnostics')
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "Workspace parent must already exist: $parent"
    }
    $workspace = Get-SafePath $WorkspaceDirectory
    if ([IO.Path]::GetDirectoryName($workspace) -ine $parent) {
        throw "WorkspaceDirectory must be a direct child of $parent (diagnostics\<name>)."
    }
    if (-not $SourceImage) { $SourceImage = Join-Path $repo 'virtual-disk.img' }
    $source = Get-SafePath $SourceImage
    if ([IO.Path]::GetExtension($source) -ine '.img' -or
        -not (Test-Path -LiteralPath $source -PathType Leaf) -or
        $source.StartsWith($workspace + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'SourceImage must be an existing absolute .img file outside the workspace.'
    }
    $module = Get-SafePath (Join-Path $repo 'win\lib\pf-tools.psm1')
    Import-Module $module -Force
    $qemu = Get-SafePath (Join-Path $repo 'qemu\qemu-system-x86_64.exe')
    $qemuImg = Get-SafePath (Join-Path $repo 'qemu\qemu-img.exe')
    $qemuNbd = Get-SafePath (Join-Path $repo 'qemu\qemu-nbd.exe')
    foreach ($exe in @($qemu, $qemuImg, $qemuNbd)) {
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Missing host QEMU executable: $exe" }
    }
    if ($Action -eq 'Prepare') {
        if (Test-Path -LiteralPath $workspace) { throw 'Prepare never overwrites an existing workspace.' }
        $null = New-Item -ItemType Directory -Path $workspace
    } elseif (-not (Test-Path -LiteralPath $workspace -PathType Container)) {
        throw 'Workspace does not exist. Run Prepare first.'
    }
    foreach ($entry in @(Get-ChildItem -LiteralPath $workspace -Force -Recurse)) {
        if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Workspace contains a reparse point: $($entry.FullName)" }
    }
    $lock = [IO.File]::Open((Join-Path $workspace 'action.lock'), [IO.FileMode]::OpenOrCreate,
        [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $overlay = Get-SafePath (Join-Path $workspace 'overlay.qcow2')
    $metadataPath = Get-SafePath (Join-Path $workspace 'metadata.json')
    if ($Action -eq 'Prepare') {
        if (@(@($NbdPort, $SerialPort, $QmpPort) | Select-Object -Unique).Count -ne 3) { throw 'Ports must be distinct.' }
        Assert-FreePorts @($NbdPort, $SerialPort, $QmpPort)
        $item = Get-Item -LiteralPath $source -Force
        if ($item.Length -le 0) { throw 'Source image is empty.' }
        $infoArgs = @('info', '--output=json', $source)
        $null = Write-Command $qemuImg $infoArgs
        $sourceInfo = & $qemuImg @infoArgs
        if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the source image.' }
        $sourceInfo = ($sourceInfo -join "`n") | ConvertFrom-Json
        if ($sourceInfo.format -cne 'raw') { throw 'Source image is not RAW.' }
        $metadata = [pscustomobject]@{
            Version = 1; WorkspaceID = [Guid]::NewGuid().ToString('D'); WorkspaceDirectory = $workspace
            SourceImage = $source; SourceLength = [uint64]$item.Length
            SourceLastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')
            OverlayPath = $overlay; QemuPath = $qemu; QemuImgPath = $qemuImg; QemuNbdPath = $qemuNbd
            NbdPort = $NbdPort; SerialPort = $SerialPort; QmpPort = $QmpPort; RamMb = $RamMb; Cores = $Cores
            NbdProcessID = $null; VmProcessID = $null
            Processes = [pscustomobject]@{ Nbd = $null; VM = $null }
        }
        if ((Test-Path -LiteralPath $overlay) -or (Test-Path -LiteralPath $metadataPath)) { throw 'Refusing to overwrite diagnostic state.' }
        $argsList = @('create', '-f', 'qcow2', '-F', 'raw', '-b', $source, $overlay)
        $null = Write-Command $qemuImg $argsList
        & $qemuImg @argsList
        if ($LASTEXITCODE -ne 0) { throw 'qemu-img create failed; workspace retained for inspection.' }
        Assert-Overlay
        Write-Metadata
        Write-Host "Prepared persistent overlay: $overlay"
        return
    }
    $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    $parsedGuid = [Guid]::Empty
    if ($metadata.Version -ne 1 -or -not [Guid]::TryParse([string]$metadata.WorkspaceID, [ref]$parsedGuid) -or
        $metadata.WorkspaceDirectory -ine $workspace -or $metadata.SourceImage -ine $source -or
        $metadata.OverlayPath -ine $overlay -or $metadata.QemuPath -ine $qemu -or
        $metadata.QemuImgPath -ine $qemuImg -or $metadata.QemuNbdPath -ine $qemuNbd) {
        throw 'Metadata identity or paths do not match this host workspace.'
    }
    foreach ($name in @('NbdPort', 'SerialPort', 'QmpPort', 'RamMb', 'Cores')) {
        $value = [int]$metadata.$name
        $min = 1024; $max = 65535
        if ($name -eq 'RamMb') { $min = 512; $max = 131072 }
        if ($name -eq 'Cores') { $min = 1; $max = 128 }
        if ($value -lt $min -or $value -gt $max -or
            ($PSBoundParameters.ContainsKey($name) -and (Get-Variable $name -ValueOnly) -ne $value -and
             -not ($Action -eq 'Configure' -and $name -in @('RamMb', 'Cores')))) {
            throw "Invalid or conflicting persisted setting: $name"
        }
    }
    if (@(@($metadata.NbdPort, $metadata.SerialPort, $metadata.QmpPort) | Select-Object -Unique).Count -ne 3) {
        throw 'Persisted ports must be distinct.'
    }
    if ($Action -eq 'Stop') {
        try { Assert-SourceFingerprint } catch { Write-Warning $_.Exception.Message }
    } else { Assert-SourceFingerprint }
    Assert-NoUnknownProcesses
    $nbd = Get-OwnedProcess 'Nbd'
    $vm = Get-OwnedProcess 'VM'
    if ($Action -eq 'Configure') {
        if ($null -ne $nbd -or $null -ne $vm) { throw 'Stop the VM/export before configuring resources.' }
        foreach ($name in @('RamMb', 'Cores')) {
            if ($PSBoundParameters.ContainsKey($name)) { $metadata.$name = Get-Variable $name -ValueOnly }
        }
        Write-Metadata
        Write-Host "Diagnostic profile: $($metadata.RamMb) MiB, $($metadata.Cores) vCPU"
        return
    }
    if ($Action -eq 'Stop') {
        $p = if ($StopTarget -eq 'Nbd') { $nbd } else { $vm }
        if ($null -ne $p) {
            if ($StopTarget -eq 'Nbd') {
                if (-not $NbdClientsDisconnected) { throw 'Disconnect all NBD clients first, then specify -NbdClientsDisconnected.' }
                $connections = @(Get-NetTCPConnection -LocalPort ([int]$metadata.NbdPort) -ErrorAction Stop)
                if (@($connections | Where-Object { $_.State -notin @('Listen', 'TimeWait', 'Closed') }).Count) {
                    throw 'NBD still has active TCP clients; refusing to kill it.'
                }
            } else {
                try { Send-Powerdown } catch { Write-Warning "Graceful QMP shutdown failed: $($_.Exception.Message)" }
                $null = $p.WaitForExit(60000)
            }
            $p = Get-OwnedProcess $StopTarget
            if ($null -ne $p) {
                Assert-NoUnknownProcesses
                $null = Write-Command 'Process.Kill' @("Owned $StopTarget PID=$($p.Id)")
                $p.Kill()
                if (-not $p.WaitForExit(10000)) { throw 'Owned process did not exit; identity retained.' }
            }
        }
        $metadata.Processes.$StopTarget = $null
        if ($StopTarget -eq 'Nbd') { $metadata.NbdProcessID = $null } else { $metadata.VmProcessID = $null }
        Write-Metadata
        Write-Host "$StopTarget stopped; persistent overlay and logs retained."
        return
    }
    if ($null -ne $nbd -or $null -ne $vm) { throw 'Stop the owned export or VM before launching another overlay writer.' }
    Assert-Overlay
    if ($Action -eq 'Export') {
        Assert-FreePorts @([int]$metadata.NbdPort)
        $exportArgs = @('--bind=127.0.0.1', '--port', "$($metadata.NbdPort)", '--persistent', '--shared=1')
        if ($ReadOnlyExport) { $exportArgs += '--read-only' }
        $exportArgs += @('--format=qcow2', $overlay)
        Start-OwnedProcess 'Nbd' $qemuNbd $exportArgs
        return
    }
    Assert-FreePorts @([int]$metadata.SerialPort, [int]$metadata.QmpPort)
    $firmware = Find-PfOvmf -QemuExe $qemu
    if (-not $firmware) { throw 'Host UEFI firmware is required; BIOS fallback is forbidden.' }
    $firmware = Get-SafePath $firmware
    $qemuArgs = Get-PfQemuBaseArgs -Uefi -QemuExe $qemu -ScriptDir $repo -RamMb $metadata.RamMb -Cores $metadata.Cores -CpuModel $CpuModel
    if ($Accel -eq 'WHPX') {
        $qemuArgs = @('-machine', 'type=q35', '-accel', 'whpx,kernel-irqchip=off') + @($qemuArgs | Select-Object -Skip 6)
    } elseif ($Accel -eq 'TCG') {
        $qemuArgs = @('-machine', 'type=q35', '-accel', 'tcg,thread=multi') + @($qemuArgs | Select-Object -Skip 6)
    }
    $firmwareDrive = "if=pflash,format=raw,readonly=on,file=$firmware"
    if ($qemuArgs -notcontains $firmwareDrive) { throw 'Helper did not select verified read-only UEFI code.' }
    $qemuArgs = @($qemuArgs | ForEach-Object {
        if ($_ -eq $firmwareDrive) { "if=pflash,format=raw,readonly=on,file=$($firmware.Replace(',', ',,'))" } else { $_ }
    })
    $vars = Get-SafePath (Join-Path $workspace 'uefi-vars.fd')
    foreach ($name in @('edk2-x86_64-vars.fd', 'edk2-i386-vars.fd')) {
        $template = Get-SafePath (Join-Path (Split-Path $firmware -Parent) $name)
        if (Test-Path -LiteralPath $template -PathType Leaf) {
            if (-not (Test-Path -LiteralPath $vars)) {
                [IO.File]::Copy($template, $vars, $false)
                (Get-Item -LiteralPath $vars -Force).IsReadOnly = $false
            }
            break
        }
    }
    if (Test-Path -LiteralPath $vars -PathType Leaf) {
        $qemuArgs += @('-drive', "if=pflash,format=raw,file=$($vars.Replace(',', ',,'))")
    }
    $serialLog = Get-SafePath (Join-Path $workspace 'serial.log')
    if (Test-Path -LiteralPath $serialLog) {
        Move-Item -LiteralPath $serialLog -Destination (Join-Path $workspace ('serial-before-' + [Guid]::NewGuid().ToString('N') + '.log'))
    }
    # Generic chardev logfile/logappend is version dependent; do not silently lose diagnostics.
    $helpArgs = Write-Command $qemu @('-chardev', 'socket,help')
    $helpStamp = [Guid]::NewGuid().ToString('N')
    $helpOut = Join-Path $workspace "chardev-help-$helpStamp-stdout.log"
    $helpErr = Join-Path $workspace "chardev-help-$helpStamp-stderr.log"
    # PS5.1 treats redirected native stderr as errors; inspect help through host logs.
    $helpProcess = Start-Process -FilePath $qemu -ArgumentList $helpArgs -WorkingDirectory $workspace `
        -RedirectStandardOutput $helpOut -RedirectStandardError $helpErr -WindowStyle Hidden -PassThru
    if (-not $helpProcess.WaitForExit(10000)) {
        throw "QEMU chardev help did not exit (PID $($helpProcess.Id)); inspect host logs."
    }
    $help = (Get-Content -LiteralPath $helpOut -Raw) + (Get-Content -LiteralPath $helpErr -Raw)
    $serial = "socket,id=diagserial,host=127.0.0.1,port=$($metadata.SerialPort),server=on,wait=off"
    if ($help -match '\blogfile\b' -and $help -match '\blogappend\b') {
        $serial += ",logfile=$($serialLog.Replace(',', ',,')),logappend=on"
    } else { Write-Warning 'This QEMU does not advertise generic chardev logfile/logappend; capture serial via the loopback socket.' }
    if ($Display -eq 'None') { $qemuArgs += @('-display', 'none') }
    $qemuArgs += @('-drive', "file=$($overlay.Replace(',', ',,')),format=qcow2,if=virtio",
        '-monitor', 'none',
        '-qmp', "tcp:127.0.0.1:$($metadata.QmpPort),server=on,wait=off",
        '-chardev', $serial, '-serial', 'chardev:diagserial')
    Start-OwnedProcess 'VM' $qemu $qemuArgs
} finally {
    if ($null -ne $lock) { $lock.Dispose() }
}
