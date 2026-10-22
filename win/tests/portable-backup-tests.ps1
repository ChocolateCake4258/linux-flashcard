# Actual ZIP round trips, corruption and busy-source guards; ordinary files only.
$ErrorActionPreference='Stop'
$win=Split-Path $PSScriptRoot -Parent
. (Join-Path $win 'lib\portable-backup.ps1')
$temp=Join-Path $env:TEMP ('pf-backup-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($temp);$passed=0
function Require($Condition,$Message){if(-not $Condition){throw $Message}}
function Case($Name,[scriptblock]$Body){& $Body;$script:passed++;Write-Host ('PASS '+$Name)}
function Reject([scriptblock]$Body){$failed=$false;try{& $Body|Out-Null}catch{$failed=$true};Require $failed 'Expected rejection'}
function Mutate-Zip([string]$Name,[scriptblock]$Change){
    $path=Join-Path $temp ($Name+'.zip');[IO.File]::Copy($archive,$path,$false)
    $zip=[IO.Compression.ZipFile]::Open($path,[IO.Compression.ZipArchiveMode]::Update)
    try{& $Change $zip}finally{$zip.Dispose()}
    return $path
}
try{
    $root=Join-Path $temp "комплект с пробелами [1]'"
    $null=[IO.Directory]::CreateDirectory($root)
    foreach($name in $script:PfBackupRequired){
        $path=Join-Path $root $name;$null=[IO.Directory]::CreateDirectory((Split-Path $path -Parent))
        [IO.File]::WriteAllText($path,('fixture '+$name),[Text.Encoding]::UTF8)
    }
    $data=New-Object byte[] (256KB);([Random]::new(123)).NextBytes($data)
    [IO.File]::WriteAllBytes((Join-Path $root 'linux.img.vtoy'),$data)
    $example=Join-Path $root 'examples\кириллица [2].txt';$null=[IO.Directory]::CreateDirectory((Split-Path $example -Parent));[IO.File]::WriteAllText($example,'project data')
    $before=(Get-FileHash -LiteralPath (Join-Path $root 'linux.img.vtoy') -Algorithm SHA256).Hash
    $archive=Join-Path $temp 'backup.zip'
    Case 'Snapshot verifies every compressed entry and leaves source bytes unchanged' {
        $receipt=New-PfPortableBackup $root $archive
        $manifest=Test-PfPortableBackup $archive
        Require ($receipt.Complete -and $manifest.Complete -and @($manifest.Files).Count -eq $script:PfBackupRequired.Count+1) 'Incomplete snapshot'
        Require ((Get-FileHash -LiteralPath (Join-Path $root 'linux.img.vtoy') -Algorithm SHA256).Hash -eq $before) 'Source changed'
        Require (-not(Test-Path -LiteralPath ($archive+'.partial'))) 'Published backup left partial output'
    }
    Case 'Restore reconstructs image, firmware, runtime and Unicode paths byte-for-byte' {
        $destination=Join-Path $temp 'restored'
        $receipt=Restore-PfPortableBackup $archive $destination
        Require $receipt.Complete 'Missing restore receipt'
        foreach($file in (Test-PfPortableBackup $archive).Files){
            Require ((Get-FileHash -LiteralPath (Join-Path $destination $file.Path) -Algorithm SHA256).Hash -ieq $file.Sha256) ('Wrong restored bytes: '+$file.Path)
        }
    }
    Case 'Running launcher and external image writer block snapshots before ZIP creation' {
        foreach($kind in @('launcher','image')){
            $path=if($kind -eq 'launcher'){(Join-Path $root 'linux.img.vtoy')+'.launch.lock'}else{Join-Path $root 'linux.img.vtoy'}
            $held=[IO.File]::Open($path,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            $output=Join-Path $temp ($kind+'.zip')
            try{Reject {New-PfPortableBackup $root $output}}finally{$held.Dispose()}
            Require (-not(Test-Path -LiteralPath $output) -and -not(Test-Path -LiteralPath ($output+'.partial'))) 'Busy source reached archive creation'
        }
    }
    Case 'Existing backups, nested outputs and existing restore directories are preserved' {
        Reject {New-PfPortableBackup $root $archive}
        Reject {New-PfPortableBackup $root (Join-Path $root 'nested.zip')}
        $existing=Join-Path $temp 'occupied';$null=[IO.Directory]::CreateDirectory($existing)
        [IO.File]::WriteAllText((Join-Path $existing 'keep.txt'),'keep')
        Reject {Restore-PfPortableBackup $archive $existing}
        Require ([IO.File]::ReadAllText((Join-Path $existing 'keep.txt')) -eq 'keep') 'Restore overwrote existing data'
        Require (Test-Path -LiteralPath ($archive+'.sha256')) 'Existing backup sidecar changed'
    }
    Case 'Traversal, alternate streams, reserved names and Windows aliases are rejected' {
        foreach($name in @('../escape.txt','/absolute.txt','lib\escape.ps1','file:stream','qemu/CON.txt','qemu/file.','qemu/file ')){
            $index=[guid]::NewGuid().ToString('N');$bad=Mutate-Zip $index {param($zip) $null=$zip.CreateEntry($name)}
            $destination=Join-Path $temp ('bad-'+$index)
            Reject {Restore-PfPortableBackup $bad $destination}
            Require (-not(Test-Path -LiteralPath $destination)) 'Unsafe archive created a destination'
        }
        Require (-not(Test-Path -LiteralPath (Join-Path $temp 'escape.txt'))) 'Path escaped restore directory'
    }
    Case 'Duplicate case-insensitive and unlisted entries cannot be restored' {
        foreach($name in @('qemu/QEMU-IMG.EXE','unlisted.txt')){
            $index=[guid]::NewGuid().ToString('N');$bad=Mutate-Zip $index {param($zip) $null=$zip.CreateEntry($name)}
            Reject {Restore-PfPortableBackup $bad (Join-Path $temp ('bad-'+$index))}
        }
    }
    Case 'Payload corruption is detected before any restore destination is created' {
        $bad=Mutate-Zip 'corrupt-data' {param($zip)
            $zip.GetEntry('linux.img.vtoy').Delete();$stream=$zip.CreateEntry('linux.img.vtoy').Open()
            try{$wrong=[byte[]]$data.Clone();$wrong[123]=$wrong[123] -bxor 1;$stream.Write($wrong,0,$wrong.Length)}finally{$stream.Dispose()}
        }
        $destination=Join-Path $temp 'corrupt-destination'
        Reject {Restore-PfPortableBackup $bad $destination}
        Require (-not(Test-Path -LiteralPath $destination)) 'Corrupt archive reached extraction'
    }
    Case 'Outer checksum mismatch and truncated ZIP are rejected' {
        [IO.File]::WriteAllText(($archive+'.sha256'),('0'*64),[Text.Encoding]::ASCII)
        Reject {Test-PfPortableBackup $archive}
        [IO.File]::WriteAllText(($archive+'.sha256'),(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash,[Text.Encoding]::ASCII)
        $truncated=Join-Path $temp 'truncated.zip';$bytes=[IO.File]::ReadAllBytes($archive)
        [IO.File]::WriteAllBytes($truncated,$bytes[0..($bytes.Length-100)])
        Reject {Test-PfPortableBackup $truncated}
    }
    Case 'Real CLI backup and verify work without elevation or interactive prompts' {
        $shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe';$entry=Join-Path $win 'backup-system.ps1';$copy=Join-Path $temp 'cli.zip'
        & $shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $entry -Root $root -Archive $copy -NoPause
        Require ($LASTEXITCODE -eq 0) 'CLI snapshot failed'
        & $shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $entry -Action Verify -Archive $copy -NoPause
        Require ($LASTEXITCODE -eq 0) 'CLI verify failed'
    }
    Write-Host ("Results: $passed portable backup checks passed.")
}finally{Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}
