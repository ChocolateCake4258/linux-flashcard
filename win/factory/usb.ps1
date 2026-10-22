# Automatic USB preparation helpers. Dot-sourced by build-all and its harness.
function Write-PfPreparationJson {
    param([string]$Path,$Value)
    $temporary=$Path+'.new'
    [IO.File]::WriteAllText($temporary,($Value|ConvertTo-Json -Depth 10),[Text.Encoding]::UTF8)
    if(Test-Path -LiteralPath $Path){[IO.File]::Replace($temporary,$Path,[System.Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($temporary,$Path)}
}

function Get-PfPreparationSettingsPath {
    param([string]$SourceRoot)
    Join-Path (Get-PfStorageRoot $SourceRoot) 'last-build.json'
}

function Test-PfPreparationIdentity {
    param($Left,$Right)
    $Left -and $Right -and $Left.Path -and $Left.Path -eq $Right.Path -and
        $Left.SerialNumber -eq $Right.SerialNumber -and [long]$Left.Size -eq [long]$Right.Size
}

function Get-PfPreparationDisks {
    param([long]$MinimumBytes)
    foreach($entry in @(Get-CimInstance Win32_DiskDrive -ErrorAction Stop|Where-Object{$_.InterfaceType -eq 'USB'})){
        $disk=Get-Disk -Number $entry.Index -ErrorAction Stop
        if($disk.BusType -ne 'USB' -or $disk.IsBoot -or $disk.IsSystem -or $disk.IsReadOnly -or $disk.IsOffline -or
            $disk.LogicalSectorSize -ne 512 -or $disk.Size -lt $MinimumBytes -or -not $disk.Path){continue}
        [pscustomobject]@{Number=[int]$disk.Number;Path=[string]$disk.Path;SerialNumber=([string]$disk.SerialNumber).Trim();Size=[long]$disk.Size;Model=[string]$entry.Model}
    }
}

function Assert-PfPreparationLocation {
    param([string]$Path,[int]$DiskNumber)
    $full=[IO.Path]::GetFullPath($Path)
    if($full -notmatch '^[A-Za-z]:\\.+'){throw 'Use an ordinary local directory, not a volume root or network path.'}
    for($current=$full;$current;$current=Split-Path $current -Parent){
        if(Test-Path -LiteralPath $current){
            if((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Redirected preparation paths are not supported.'}
        }
        if((Split-Path $current -Parent) -eq $current){break}
    }
    $parts=@(Get-Partition -DriveLetter $full.Substring(0,1) -ErrorAction Stop)
    if($parts.Count -ne 1){throw 'Cannot identify the local preparation volume.'}
    if($parts[0].DiskNumber -eq $DiskNumber){throw 'The source, workspace and preparation settings must be off the target USB.'}
    return $full.TrimEnd('\')
}

function Assert-PfPreparationWorkspace {
    param([string]$Workspace,[string]$Source,[int]$DiskNumber)
    $full=Assert-PfPreparationLocation $Workspace $DiskNumber
    $sourcePath=[IO.Path]::GetFullPath($Source).TrimEnd('\')
    if($full -ieq $sourcePath -or $full.StartsWith($sourcePath+'\',[StringComparison]::OrdinalIgnoreCase) -or $sourcePath.StartsWith($full+'\',[StringComparison]::OrdinalIgnoreCase)){
        throw 'Choose a dedicated workspace outside the source tree.'
    }
    $volume=Get-Volume -DriveLetter $full.Substring(0,1) -ErrorAction Stop
    if($volume.DriveType -ne 'Fixed' -or $volume.FileSystem -ne 'NTFS'){throw 'The factory workspace requires a local fixed NTFS volume.'}
    $state=Join-Path $full 'factory-state.json'
    if(Test-Path -LiteralPath $state){
        $owner=Get-Content -LiteralPath $state -Raw -Encoding UTF8|ConvertFrom-Json
        if($owner.schema -ne 1 -or $owner.workspace -ine $full){throw 'Factory workspace ownership mismatch.'}
    }elseif((Test-Path -LiteralPath $full) -and @(Get-ChildItem -LiteralPath $full -Force|Where-Object{$_.Name -ne 'bootstrap'}).Count){
        throw 'Refusing an unowned, nonempty factory workspace.'
    }
    return $full
}

function Resolve-PfPreparationWorkspace {
    param([string]$Requested,[string]$Source,$Target,[string]$SettingsPath,[switch]$NewBuild,[long]$RequiredBytes)
    if($Requested -and $NewBuild){throw '-NewBuild selects a new automatic workspace; do not combine it with -Workspace.'}
    if(-not $Requested -and -not $NewBuild -and (Test-Path -LiteralPath $SettingsPath)){
        $last=Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8|ConvertFrom-Json
        if($last.Schema -ne 1){throw 'Unsupported automatic preparation settings.'}
        if([long]$last.MediaBytes -eq $Target.Size){$Requested=[string]$last.Workspace}
    }
    if(-not $Requested){
        $storage=Split-Path $SettingsPath -Parent
        $volume=Get-Volume -DriveLetter $storage.Substring(0,1) -ErrorAction Stop
        if($volume.DriveType -ne 'Fixed' -or $volume.FileSystem -ne 'NTFS' -or $volume.SizeRemaining -lt $RequiredBytes){throw ('The selected storage volume requires {0:N1} GiB free. Move the extracted package to another NTFS volume or specify -Workspace.' -f ($RequiredBytes/1GB))}
        $Requested=Join-Path $storage ('builds\build-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    }
    return Assert-PfPreparationWorkspace $Requested $Source $Target.Number
}

function Find-PfPreparationTarget {
    param($Identity,[long]$MinimumBytes)
    $matches=@(Get-PfPreparationDisks $MinimumBytes|Where-Object{Test-PfPreparationIdentity $_ $Identity})
    if($matches.Count -ne 1){throw 'The confirmed USB is absent or its identity changed. Reconnect the same device and retry.'}
    $null=Assert-PfUsbDisk -Number $matches[0].Number -Identity $Identity
    return $matches[0]
}

function Invoke-PfPreparationScript {
    param([string]$Path,[hashtable]$Parameters)
    $command="& '"+$Path.Replace("'","''")+"'"
    foreach($key in @($Parameters.Keys|Sort-Object)){
        $value=$Parameters[$key]
        if($value -is [bool] -or $value -is [Management.Automation.SwitchParameter]){
            if($value){$command+=' -'+$key}
        }else{$command+=' -'+$key+" '"+([string]$value).Replace("'","''")+"'"}
    }
    $command+='; exit $LASTEXITCODE'
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $shell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded
    if($LASTEXITCODE -ne 0){throw ('Preparation subprocess failed ({0}): {1}' -f $LASTEXITCODE,$Path)}
}

function Assert-PfPreparationReceipt {
    param($Receipt,$Artifact,$Target)
    if(-not $Receipt.Complete -or -not (Test-PfPreparationIdentity $Receipt.Target $Target) -or
        $Receipt.ImagePath -ine $Artifact.image -or [long]$Receipt.ImageBytes -ne [long]$Artifact.bytes -or
        [long]$Receipt.BytesWritten -ne [long]$Artifact.bytes -or [long]$Receipt.BytesVerified -ne [long]$Artifact.bytes -or
        $Receipt.ExpectedSourceSha256 -ine $Artifact.sha256 -or -not $Receipt.BeforePublicationBodyVerified -or
        $Receipt.VerificationMethod -ne 'DeferredBodyAndBootRegions'){
        throw 'Writer did not return a complete matching full read-back receipt.'
    }
}
