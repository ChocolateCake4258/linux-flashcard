# Portable file-kit backups. No physical-disk access or administrator requirement.
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$script:PfBackupRequired=@('linux.img.vtoy','linux.img.vtoy.uefi-vars.fd','run-linux.bat','run-from-usb.ps1','lib/pf-tools.psm1','qemu/qemu-system-x86_64.exe','qemu/qemu-img.exe','qemu/share/qemu/edk2-x86_64-code.fd')

function Assert-PfBackupPath {
    param([string]$Path)
    $full=[IO.Path]::GetFullPath($Path)
    if($full -notmatch '^[A-Za-z]:\\'){throw 'Use an ordinary local filesystem path.'}
    for($current=$full;$current;$current=Split-Path $current -Parent){
        if(Test-Path -LiteralPath $current){if((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Redirected backup paths are not supported.'}}
        if((Split-Path $current -Parent) -eq $current){break}
    }
    return $full
}

function Assert-PfBackupRelativePath {
    param([string]$Path)
    if(-not $Path -or $Path -match '[:\\\x00-\x1f]' -or $Path.StartsWith('/')){throw 'Unsafe backup entry path.'}
    foreach($part in $Path.Split('/')){
        if(-not $part -or $part -in '.','..' -or $part -match '[. ]$|[<>"|?*]' -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)'){throw 'Unsafe backup entry path.'}
    }
}

function Copy-PfBackupStream {
    param([IO.Stream]$Source,[IO.Stream]$Destination,[long]$ExpectedBytes,[string]$Label='')
    $sha=[Security.Cryptography.SHA256]::Create();$buffer=New-Object byte[] (4MB);$total=0L;$report=2GB
    try{
        while(($read=$Source.Read($buffer,0,$buffer.Length)) -gt 0){
            $total+=[long]$read
            if($total -gt $ExpectedBytes){throw 'Backup entry exceeds its declared length.'}
            if($Destination){$Destination.Write($buffer,0,$read)}
            $null=$sha.TransformBlock($buffer,0,$read,$buffer,0)
            if($Label -and $total -ge $report){Write-Host ('  {0}: {1:N1} / {2:N1} GiB' -f $Label,($total/1GB),($ExpectedBytes/1GB));$report=$total+2GB}
        }
        if($total -ne $ExpectedBytes){throw 'Truncated backup entry or changed source length.'}
        $null=$sha.TransformFinalBlock($buffer,0,0)
        [pscustomobject]@{Bytes=$total;Sha256=[BitConverter]::ToString($sha.Hash).Replace('-','').ToLowerInvariant()}
    }finally{$sha.Dispose()}
}

function Get-PfBackupFiles {
    param([string]$Root)
    $base=$Root.TrimEnd('\')+'\'
    $files=[Collections.Generic.List[object]]::new()
    foreach($file in @(Get-ChildItem -LiteralPath $Root -File -Force)){
        if($file.Name -in 'linux.img.vtoy','linux.img.vtoy.uefi-vars.fd' -or ($file.Extension -in '.bat','.ps1','.txt','.md','.json' -and $file.Name -notin 'backup-manifest.json','restore-result.json')){$files.Add($file)}
    }
    $pending=[Collections.Generic.Stack[string]]::new()
    foreach($name in @('qemu','lib','ventoy','examples')){if(Test-Path -LiteralPath (Join-Path $Root $name)){$pending.Push((Join-Path $Root $name))}}
    while($pending.Count){
        $directory=Get-Item -LiteralPath $pending.Pop() -Force
        if(-not $directory.PSIsContainer -or $directory.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Backup runtime directories must be regular directories.'}
        foreach($item in @(Get-ChildItem -LiteralPath $directory.FullName -Force)){
            if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Backup runtime must not contain redirected files.'}
            if($item.PSIsContainer){$pending.Push($item.FullName)}else{$files.Add($item)}
        }
    }
    $names=@($files|ForEach-Object{$_.FullName.Substring($base.Length).Replace('\','/')})
    foreach($name in $script:PfBackupRequired){if($names -notcontains $name){throw ('Incomplete portable kit; missing '+$name)}}
    foreach($file in @($files|Sort-Object FullName)){
        if($file.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Backup files must not be redirected.'}
        $relative=$file.FullName.Substring($base.Length).Replace('\','/');Assert-PfBackupRelativePath $relative
        [pscustomobject]@{Path=$relative;FullName=$file.FullName;Bytes=[long]$file.Length}
    }
}

function Read-PfBackupManifest {
    param([IO.Compression.ZipArchive]$Zip)
    $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($entry in $Zip.Entries){Assert-PfBackupRelativePath $entry.FullName;if(-not $names.Add($entry.FullName)){throw 'Duplicate backup entry.'}}
    $entry=$Zip.GetEntry('backup-manifest.json')
    if(-not $entry -or $entry.Length -gt 16MB){throw 'Missing or oversized backup manifest.'}
    $reader=[IO.StreamReader]::new($entry.Open(),[Text.Encoding]::UTF8)
    try{$manifest=$reader.ReadToEnd()|ConvertFrom-Json}finally{$reader.Dispose()}
    if($manifest.Schema -ne 1 -or $manifest.Format -ne 'LinuxFlashcardPortableBackup' -or -not $manifest.Complete){throw 'Unsupported or incomplete backup manifest.'}
    $listed=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($file in $manifest.Files){
        Assert-PfBackupRelativePath $file.Path
        if($file.Path -eq 'backup-manifest.json' -or -not $listed.Add($file.Path) -or $file.Sha256 -notmatch '^[0-9a-fA-F]{64}$' -or $null -eq $file.Bytes -or [long]$file.Bytes -lt 0){throw 'Invalid backup manifest entry.'}
        $item=$Zip.GetEntry($file.Path)
        if(-not $item -or $item.Length -ne [long]$file.Bytes){throw 'Backup entry length or name differs from manifest.'}
    }
    if($listed.Count+1 -ne $Zip.Entries.Count){throw 'Unlisted or missing backup entries.'}
    foreach($required in $script:PfBackupRequired){if(-not $listed.Contains($required)){throw ('Incomplete backup; missing '+$required)}}
    return $manifest
}

function Test-PfPortableBackup {
    param([string]$Archive,[switch]$SkipSidecar)
    $Archive=Assert-PfBackupPath $Archive
    $input=[IO.File]::Open($Archive,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{
        if(-not $SkipSidecar -and (Test-Path -LiteralPath ($Archive+'.sha256'))){
            $expected=(Get-Content -LiteralPath ($Archive+'.sha256') -Raw -Encoding ASCII).Trim()
            $sha=[Security.Cryptography.SHA256]::Create()
            try{$actual=[BitConverter]::ToString($sha.ComputeHash($input)).Replace('-','')}finally{$sha.Dispose()}
            if($expected -notmatch '^[a-fA-F0-9]{64}$' -or $actual -ine $expected){throw 'Backup archive SHA256 mismatch.'}
            $input.Position=0
        }
        $zip=[IO.Compression.ZipArchive]::new($input,[IO.Compression.ZipArchiveMode]::Read,$true)
        try{
            $manifest=Read-PfBackupManifest $zip
            foreach($file in $manifest.Files){
                $stream=$zip.GetEntry($file.Path).Open()
                try{$result=Copy-PfBackupStream -Source $stream -ExpectedBytes $file.Bytes -Label ('verify '+$file.Path)}finally{$stream.Dispose()}
                if($result.Sha256 -ine $file.Sha256){throw ('Backup entry SHA256 mismatch: '+$file.Path)}
            }
            return $manifest
        }finally{$zip.Dispose()}
    }finally{$input.Dispose()}
}

function New-PfPortableBackup {
    param([string]$Root,[string]$Archive)
    $Root=Assert-PfBackupPath $Root;$Archive=Assert-PfBackupPath $Archive
    $base=$Root.TrimEnd('\')+'\'
    if($Archive.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)){throw 'Keep the backup outside the source kit.'}
    if([IO.Path]::GetExtension($Archive) -ine '.zip'){throw 'Backup archive must have the .zip extension.'}
    foreach($path in @($Archive,($Archive+'.partial'),($Archive+'.sha256'))){if(Test-Path -LiteralPath $path){throw 'Backup output already exists; choose a new filename.'}}
    $files=@(Get-PfBackupFiles $Root)
    $parent=Split-Path $Archive -Parent
    if(-not(Test-Path -LiteralPath $parent -PathType Container)){throw 'Create the backup destination directory first.'}
    $bytes=[long]($files|Measure-Object Bytes -Sum).Sum
    if(([IO.DriveInfo]::new([IO.Path]::GetPathRoot($Archive))).AvailableFreeSpace -lt $bytes+64MB){throw 'Insufficient space for a worst-case uncompressed backup.'}
    $image=Join-Path $Root 'linux.img.vtoy';$held=[Collections.Generic.List[IO.Stream]]::new();$lock=$null;$output=$null;$zip=$null
    try{
        $lock=[IO.File]::Open(($image+'.launch.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        # Hold image and firmware read-only for the entire snapshot and verification.
        $streams=@{}
        foreach($name in @('linux.img.vtoy','linux.img.vtoy.uefi-vars.fd')){
            $stream=[IO.File]::Open((Join-Path $Root $name),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
            $held.Add($stream);$streams[$name]=$stream
        }
        $output=[IO.File]::Open(($Archive+'.partial'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $zip=[IO.Compression.ZipArchive]::new($output,[IO.Compression.ZipArchiveMode]::Create,$true)
        $records=[Collections.Generic.List[object]]::new()
        foreach($file in $files){
            $source=$null;$target=$null;$owned=-not $streams.ContainsKey($file.Path)
            try{
                $source=if($owned){[IO.File]::Open($file.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)}else{$streams[$file.Path]}
                $source.Position=0
                $target=$zip.CreateEntry($file.Path,[IO.Compression.CompressionLevel]::Fastest).Open()
                $result=Copy-PfBackupStream $source $target $file.Bytes $file.Path
                $records.Add([ordered]@{Path=$file.Path;Bytes=$result.Bytes;Sha256=$result.Sha256})
            }finally{if($target){$target.Dispose()};if($owned -and $source){$source.Dispose()}}
        }
        $manifest=[ordered]@{Schema=1;Format='LinuxFlashcardPortableBackup';Complete=$true;Created=(Get-Date).ToUniversalTime().ToString('o');SourceRoot=$Root;Files=@($records.ToArray())}
        $writer=[IO.StreamWriter]::new($zip.CreateEntry('backup-manifest.json').Open(),[Text.UTF8Encoding]::new($false))
        try{$writer.Write(($manifest|ConvertTo-Json -Depth 6))}finally{$writer.Dispose()}
        $zip.Dispose();$zip=$null;$output.Flush($true);$output.Dispose();$output=$null
        $null=Test-PfPortableBackup ($Archive+'.partial') -SkipSidecar
        [IO.File]::Move(($Archive+'.partial'),$Archive)
        $digest=(Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash
        [IO.File]::WriteAllText(($Archive+'.sha256'),$digest+"`n",[Text.Encoding]::ASCII)
        return [pscustomobject]@{Complete=$true;Archive=$Archive;Sha256=$digest;Files=$files.Count;SourceBytes=$bytes;ArchiveBytes=(Get-Item -LiteralPath $Archive).Length}
    }finally{if($zip){$zip.Dispose()};if($output){$output.Dispose()};foreach($stream in $held){$stream.Dispose()};if($lock){$lock.Dispose()}}
}

function Restore-PfPortableBackup {
    param([string]$Archive,[string]$Destination)
    $Archive=Assert-PfBackupPath $Archive;$Destination=(Assert-PfBackupPath $Destination).TrimEnd('\')
    if($Destination -notmatch '^[A-Za-z]:\\.+'){throw 'Restore to a new directory, not a volume root.'}
    if(Test-Path -LiteralPath $Destination){throw 'Restore destination already exists; existing data is never overwritten.'}
    $parent=Split-Path $Destination -Parent
    if(-not(Test-Path -LiteralPath $parent -PathType Container)){throw 'Restore parent directory does not exist.'}
    # Validate the complete archive before creating the destination or any staging data.
    $input=[IO.File]::Open($Archive,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{
        $manifest=Test-PfPortableBackup $Archive
        $bytes=[long]($manifest.Files|Measure-Object Bytes -Sum).Sum
        if(([IO.DriveInfo]::new([IO.Path]::GetPathRoot($Destination))).AvailableFreeSpace -lt $bytes+64MB){throw 'Insufficient restore space.'}
        $staging=$Destination+'.partial-'+[guid]::NewGuid().ToString('N')
        $null=[IO.Directory]::CreateDirectory($staging)
        $zip=[IO.Compression.ZipArchive]::new($input,[IO.Compression.ZipArchiveMode]::Read,$true)
        try{
            foreach($file in $manifest.Files){
                $path=Join-Path $staging $file.Path
                $null=[IO.Directory]::CreateDirectory((Split-Path $path -Parent))
                $target=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);$source=$null
                try{$source=$zip.GetEntry($file.Path).Open();$result=Copy-PfBackupStream $source $target $file.Bytes ('restore '+$file.Path);$target.Flush($true)}finally{if($source){$source.Dispose()};$target.Dispose()}
                if($result.Sha256 -ine $file.Sha256 -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $file.Sha256){throw ('Restored file SHA256 mismatch: '+$file.Path)}
            }
        }finally{$zip.Dispose()}
        $receipt=[ordered]@{Complete=$true;Archive=$Archive;Files=@($manifest.Files).Count;Bytes=$bytes;Restored=(Get-Date).ToUniversalTime().ToString('o')}
        [IO.File]::WriteAllText((Join-Path $staging 'restore-result.json'),($receipt|ConvertTo-Json),[Text.Encoding]::UTF8)
        [IO.Directory]::Move($staging,$Destination)
        return [pscustomobject]$receipt
    }finally{$input.Dispose()}
}
