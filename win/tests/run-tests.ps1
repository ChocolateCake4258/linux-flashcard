param()
$ErrorActionPreference = 'Stop'
$win = Split-Path $PSScriptRoot -Parent
$repo = Split-Path $win -Parent
$failures = 0
$passed = 0
function Assert-Test($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:passed++; Write-Host "PASS $Name" }
    catch { $script:failures++; Write-Host "FAIL ${Name}: $($_.Exception.Message)" }
}
function Assert-Throws([scriptblock]$Body, [string]$Pattern) {
    $caught = $null
    try { & $Body | Out-Null } catch { $caught = $_ }
    Assert-Test ($null -ne $caught) 'Expected an exception.'
    Assert-Test ($caught.Exception.Message -match $Pattern) "Unexpected exception: $caught"
}

Test-Case 'Parse every repository PowerShell script and module' {
    $files = @(Get-ChildItem -LiteralPath $repo -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' })
    Assert-Test ($files.Count -gt 0) 'No scripts found.'
    foreach ($file in $files) {
        $tokens = $null; $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
        Assert-Test ($errors.Count -eq 0) "$($file.FullName): $($errors -join '; ')"
    }
    Write-Host "  Parsed $($files.Count) files"
}
Import-Module (Join-Path $win 'lib/pf-tools.psm1') -Force -WarningAction SilentlyContinue
$module = Get-Module pf-tools
Test-Case 'Windows script encodings are preserved' {
    foreach ($file in @(Get-ChildItem -LiteralPath $win -Recurse -File)) {
        if ($file.Extension -notin '.ps1', '.psm1', '.bat') { continue }
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        if ($file.Extension -eq '.bat') {
            Assert-Test (@($bytes | Where-Object { $_ -gt 127 }).Count -eq 0) "Non-ASCII batch: $file"
            $text = [Text.Encoding]::ASCII.GetString($bytes)
            Assert-Test ($text -notmatch '(?<!\r)\n|\r(?!\n)') "Batch line endings: $file"
        } else {
            Assert-Test ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) "Missing UTF-8 BOM: $file"
            Assert-Test (-not ($bytes -contains 13)) "Non-LF PowerShell: $file"
            $null = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        }
    }
}
Test-Case 'Real CRC32 matches standard known vector' {
    $actual = Get-PfCrc32 -Bytes ([Text.Encoding]::ASCII.GetBytes('123456789'))
    Assert-Test ($actual -eq [Convert]::ToUInt32('CBF43926', 16)) "Incorrect CRC32: $actual"
}
Test-Case 'Real relocated GPT helper clones without mutating original headers' {
    foreach ($backup in @($false, $true)) {
        $header = New-Object byte[] 512
        [BitConverter]::GetBytes([uint32]92).CopyTo($header, 12)
        [BitConverter]::GetBytes([uint64]$(if ($backup) { 16384 } else { 1 })).CopyTo($header, 24)
        [BitConverter]::GetBytes([uint64]$(if ($backup) { 1 } else { 16384 })).CopyTo($header, 32)
        [BitConverter]::GetBytes([uint64]16382).CopyTo($header, 48)
        [BitConverter]::GetBytes([uint64]$(if ($backup) { 16383 } else { 2 })).CopyTo($header, 72)
        $header[100] = 0x73
        $original = [Convert]::ToBase64String($header)
        $relocated = Get-PfRelocatedGptHeader -Header $header -ImageBytes (8MB + 512) -DiskBytes 16MB -Backup:$backup
        Assert-Test ($relocated -is [byte[]] -and $relocated.Length -eq 512) 'Helper did not return a byte array.'
        Assert-Test (-not [object]::ReferenceEquals($header, $relocated)) 'Helper returned the original array.'
        Assert-Test ([Convert]::ToBase64String($header) -ceq $original) 'Helper mutated the original header.'
        Assert-Test ([BitConverter]::ToUInt64($relocated, 48) -eq 32765 -and $relocated[100] -eq 0x73) 'Last usable LBA or unrelated data changed incorrectly.'
        if ($backup) {
            Assert-Test ([BitConverter]::ToUInt64($relocated, 24) -eq 32767 -and [BitConverter]::ToUInt64($relocated, 72) -eq 32766 -and [BitConverter]::ToUInt64($relocated, 32) -eq 1) 'Incorrect backup relocation.'
        } else {
            Assert-Test ([BitConverter]::ToUInt64($relocated, 32) -eq 32767 -and [BitConverter]::ToUInt64($relocated, 24) -eq 1 -and [BitConverter]::ToUInt64($relocated, 72) -eq 2) 'Incorrect primary relocation.'
        }
        $relocated[100] = 0
        Assert-Test ($header[100] -eq 0x73) 'Returned array aliases the source.'
    }
}
Test-Case 'Writer SHA256 streams large bounded blocks and preserves exact validation' {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $win 'write-image.ps1'), [ref]$tokens, [ref]$errors)
    Assert-Test ($errors.Count -eq 0) 'Writer parse failed.'
    $hashTry = @($ast.FindAll({ param($n)
        $n -is [Management.Automation.Language.TryStatementAst] -and
        $n.Body.Extent.Text -match '\$hash\.TransformFinalBlock' -and
        $n.Finally.Extent.Text -eq '{ $hash.Dispose() }'
    }, $true))
    Assert-Test ($hashTry.Count -eq 1) 'Cannot uniquely locate streaming hash validation.'
    $body = $hashTry[0].Body.Extent.Text
    Assert-Test ($body -match 'New-Object byte\[\] \(4MB\)') 'Hash buffer must be bounded to 4 MiB.'
    Assert-Test ($body -match 'while \(\(\$hashRead = \$src\.Read\(\$hashBuffer, 0, \$hashBuffer\.Length\)\) -gt 0\)') 'Missing large-buffer read loop.'
    Assert-Test ($body -match '\$hash\.TransformBlock\(\$hashBuffer, 0, \$hashRead, \$hashBuffer, 0\)') 'Hash must consume exactly the bytes read.'
    Assert-Test ($body -notmatch 'ComputeHash') 'Small-read ComputeHash stream path remains.'
    $sidecar = $hashTry[0].Parent.Parent
    $statements = @($sidecar.Parent.Statements)
    $reset = $statements[[array]::IndexOf($statements, $sidecar) + 1]
    Assert-Test ($reset.Extent.Text -eq '$src.Position = 0') 'Source reset after sidecar validation changed.'
    $validate = [scriptblock]::Create($hashTry[0].Extent.Text + "`n" + $reset.Extent.Text)
    foreach ($length in @(0, 4MB, (8MB + 513))) {
        $bytes = New-Object byte[] $length
        $random = New-Object Random 123
        $random.NextBytes($bytes)
        $reference = [Security.Cryptography.SHA256]::Create()
        try { $expectedHash = [BitConverter]::ToString($reference.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant() }
        finally { $reference.Dispose() }
        $src = [IO.MemoryStream]::new($bytes, $false)
        try {
            $src.Position = $src.Length
            $hash = [Security.Cryptography.SHA256]::Create()
            . $validate
            Assert-Test ($actualHash -eq $expectedHash) "Incorrect digest for $length bytes."
            Assert-Test ($src.Position -eq 0) 'Source was not rewound.'
            Assert-Test ($hashBuffer.Length -eq 4MB) 'Buffer grew with source length.'
            $expectedHash = '0' * 64
            $hash = [Security.Cryptography.SHA256]::Create()
            Assert-Throws { . $validate } 'RAW image SHA256 does not match. USB has not been modified.'
        } finally { $src.Dispose() }
    }
}
Test-Case 'Writer verification chunk arithmetic handles 30 GB without allocation' {
    $tokens = $null; $errors = $null
    $writerAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $win 'write-image.ps1'), [ref]$tokens, [ref]$errors)
    Assert-Test ($errors.Count -eq 0) 'Writer parse failed.'
    $assignments = @($writerAst.FindAll({ param($n)
        $n -is [Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left.Extent.Text -eq '$count' -and $n.Right.Extent.Text -match '\[Math\]::Min'
    }, $true))
    Assert-Test ($assignments.Count -eq 1) 'Cannot uniquely locate verification chunk assignment.'
    $min = $assignments[0].Right.Find({ param($n)
        $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Extent.Text -eq 'Min'
    }, $true)
    Assert-Test ($min.Arguments.Count -eq 2) 'Unexpected Math.Min argument count.'
    foreach ($argument in $min.Arguments) {
        Assert-Test ($argument -is [Management.Automation.Language.ConvertExpressionAst] -and
            $argument.Type.TypeName.FullName -in 'long', 'System.Int64') 'Math.Min arguments must explicitly use Int64 for Windows PowerShell 5.1.'
    }
    $rhs = [scriptblock]::Create($assignments[0].Right.Extent.Text)
    $probe = 4MB; $imageSize = 30GB; $off = 0L
    $first = & $rhs
    Assert-Test ($first -is [int] -and $first -eq 4MB) "Wrong first chunk: $first"
    $off = $imageSize - 512
    $last = & $rhs
    Assert-Test ($last -is [int] -and $last -eq 512) "Wrong last chunk: $last"
}
Test-Case 'Writer current image chunk arithmetic handles 30 GB without allocation' {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $win 'write-image.ps1'), [ref]$tokens, [ref]$errors)
    $assignment = $ast.Find({ param($n)
        $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$currentCount'
    }, $true)
    Assert-Test ($null -ne $assignment) 'Current image chunk assignment missing.'
    $min = $assignment.Right.Find({ param($n)
        $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Extent.Text -eq 'Min'
    }, $true)
    foreach ($argument in $min.Arguments) {
        Assert-Test ($argument -is [Management.Automation.Language.ConvertExpressionAst] -and
            $argument.Type.TypeName.FullName -in 'long', 'System.Int64') 'Current image Math.Min arguments must use Int64.'
    }
    $rhs = [scriptblock]::Create($assignment.Right.Extent.Text)
    $identity = [pscustomobject]@{ Size = 30GB + 512 }; $currentOffset = 0L
    $first = & $rhs
    Assert-Test ($first -is [int] -and $first -eq 4MB) 'Wrong current image first chunk.'
    $currentOffset = 30GB
    $last = & $rhs
    Assert-Test ($last -is [int] -and $last -eq 512) 'Wrong current image final partial chunk.'
}
Test-Case 'Compile real native definitions and reflect control codes' {
    Add-PfRawDiskNative
    Add-PfVolumeNative
    $flags = [Reflection.BindingFlags]'Static,NonPublic,Public'
    $constants = @{
        IOCTL_DISK_DELETE_DRIVE_LAYOUT = @([PfRawDisk], 0x7c100)
        IOCTL_DISK_UPDATE_PROPERTIES = @([PfRawDisk], 0x70140)
        FSCTL_LOCK_VOLUME = @([PfVolume], 0x90018)
        FSCTL_UNLOCK_VOLUME = @([PfVolume], 0x9001c)
        FSCTL_DISMOUNT_VOLUME = @([PfVolume], 0x90020)
        FSCTL_IS_VOLUME_MOUNTED = @([PfVolume], 0x90028)
    }
    foreach ($name in $constants.Keys) {
        $field = $constants[$name][0].GetField($name, $flags)
        Assert-Test ($null -ne $field) "Missing $name"
        Assert-Test ($field.GetRawConstantValue() -eq $constants[$name][1]) "Incorrect $name"
    }
    Assert-Test ($null -eq [PfRawDisk].GetMethod('CreateUnallocated', $flags)) 'Unsafe CreateUnallocated API remains.'
    foreach ($type in @([PfRawDisk], [PfVolume])) {
        Assert-Test (@($type.GetNestedTypes($flags) | Where-Object IsEnum).Count -eq 0) 'Unexpected native layout enum.'
    }
}
# Mocks live in the real module's session state, not a copied implementation.
& $module {
    $script:testDisk = [pscustomobject]@{
        Path = 'test-device'; SerialNumber = 'serial'; Size = 16MB; BusType = 'USB'
        IsBoot = $false; IsSystem = $false; NumberOfPartitions = 1
    }
    $script:testParts = @([pscustomobject]@{ DiskNumber = 7; PartitionNumber = 1; AccessPaths = @('\\?\Volume{12345678-1234-1234-1234-123456789abc}\') })
    $script:partitionFailure = $false
    $script:partitionCalls = 0
    function script:Get-Disk { param($Number) $script:testDisk }
    function script:Get-Partition {
        param($DiskNumber, $PartitionNumber, $DriveLetter)
        $script:partitionCalls++
        if ($script:partitionFailure) { throw 'Enumeration unavailable' }
        $script:testParts
    }
}
Test-Case 'Real volume path normalizes GUID root and drive letter' {
    Assert-Test ((Get-PfVolumePath -DiskNumber 7 -PartitionNumber 1) -ceq '\\?\Volume{12345678-1234-1234-1234-123456789abc}') 'GUID trailing slash was not removed.'
    Assert-Test ((Get-PfVolumePath -Letter D) -ceq '\\.\D:') 'Incorrect drive-letter device path.'
    Assert-Test ((Get-PfVolumePath -Letter ([string][char]0) -DiskNumber 7 -PartitionNumber 1) -ceq '\\?\Volume{12345678-1234-1234-1234-123456789abc}') 'Windows NUL drive letter was treated as an actual letter.'
}
$identity = [pscustomobject]@{ Path = 'test-device'; SerialNumber = 'serial'; Size = 16MB }
Test-Case 'USB identity accepts unchanged target and trimmed serial' {
    & $module { $script:testDisk.SerialNumber = ' serial ' }
    $null = Assert-PfUsbDisk -Number 7 -Identity $identity
    & $module { $script:testDisk.SerialNumber = 'serial' }
}
foreach ($field in @('Path', 'SerialNumber', 'Size', 'IsBoot', 'IsSystem', 'BusType')) {
    Test-Case "USB guard rejects changed $field" {
        & $module { param($field) $script:saved = $script:testDisk.$field; $script:testDisk.$field = switch ($field) { Size { 32MB } IsBoot { $true } IsSystem { $true } default { 'changed' } } } $field
        try { Assert-Throws { Assert-PfUsbDisk -Number 7 -Identity $identity } 'identity changed|boot/system or non-USB' }
        finally { & $module { param($field) $script:testDisk.$field = $script:saved } $field }
    }
}
Test-Case 'Partitions fail closed on enumeration error' {
    & $module { $script:partitionFailure = $true }
    try { Assert-Throws { Get-PfDiskPartitions -Number 7 } 'Enumeration unavailable' }
    finally { & $module { $script:partitionFailure = $false } }
}
Test-Case 'Partitions fail closed on incomplete or unknown count' {
    & $module { $script:testDisk.NumberOfPartitions = 2 }
    Assert-Throws { Get-PfDiskPartitions -Number 7 } 'incomplete'
    & $module { $script:testDisk.NumberOfPartitions = $null }
    Assert-Throws { Get-PfDiskPartitions -Number 7 } 'Cannot determine'
}
Test-Case 'Unpartitioned disk needs no enumeration' {
    & $module { $script:testDisk.NumberOfPartitions = 0; $script:partitionFailure = $true; $script:partitionCalls = 0 }
    Assert-Test (@(Get-PfDiskPartitions -Number 7).Count -eq 0) 'Expected no partitions.'
    Assert-Test ((& $module { $script:partitionCalls }) -eq 0) 'Enumerated an explicitly empty disk.'
}

$pwsh = (Get-Process -Id $PID).Path
foreach ($scenario in @('success', 'full', 'valid-checksum', 'verify-only', 'verify-only-corrupt', 'gpt-relocation', 'gpt-relocation-primary-corrupt', 'gpt-relocation-backup-corrupt', 'gpt-relocation-table-corrupt', 'gpt-relocation-data-corrupt', 'windows-volume-selection', 'linux-driver-volume', 'bad-mbr', 'bad-gpt', 'truncated-gpt', 'missing-backup', 'primary-header-crc', 'backup-header-crc', 'table-crc', 'backup-table-crc', 'table-bounds', 'small', 'unaligned', 'checksum', 'bad-sidecar', 'missing-identity', 'boot', 'source-target', 'identity-changed', 'lock-failure', 'write-failure', 'short-write', 'short-read', 'corrupt-read', 'refresh-failure', 'baseline-match', 'baseline-mismatch', 'baseline-wronglength', 'baseline-lock-failure', 'baseline-short-read', 'baseline-read-failure', 'baseline-source-target', 'deferred', 'deferred-final-rescan', 'deferred-body-failure', 'deferred-guard-rejected', 'deferred-verify-rejected')) {
    Test-Case "Writer integration: $scenario" {
        $output = @(& $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'writer-harness.ps1') -Scenario $scenario 2>&1)
        $exit = $LASTEXITCODE
        $result = $output[-1] | ConvertFrom-Json
        Assert-Test ($result.HarnessPassed) "Harness failed: $($output -join [Environment]::NewLine)"
        $expected = if ($scenario -in 'success', 'full', 'valid-checksum', 'verify-only', 'gpt-relocation', 'lock-failure', 'windows-volume-selection', 'linux-driver-volume', 'baseline-match', 'deferred', 'deferred-final-rescan') { 0 } else { 1 }
        Assert-Test ($exit -eq $expected -and $result.WriterExit -eq $expected) "Wrong exit code: process=$exit writer=$($result.WriterExit)"
        Write-Host "  exit=$exit bytes=$($result.Bytes) verified=$($result.Verified) reads=$($result.Reads) deletes=$($result.Deletes) refreshes=$($result.Refreshes) volumes=$($result.Volumes) unlocks=$($result.Unlocks)"
    }
}
Test-Case 'Writer integration: successful IOCTL with remaining partitions uses clean fallback' {
    $output = @(& $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'writer-harness.ps1') -Scenario deferred-clean-fallback 2>&1)
    $exit = $LASTEXITCODE
    $result = $output[-1] | ConvertFrom-Json
    Assert-Test ($exit -eq 0 -and $result.HarnessPassed -and $result.WriterExit -eq 0) "Clean fallback failed: $($output -join ' ')"
}
foreach($scenario in @('deferred-publish','deferred-publish-mounted','deferred-publish-body-corrupt','deferred-publish-boot-corrupt','deferred-publish-short-read','deferred-publish-size-mismatch','deferred-publish-identity-changed','deferred-publish-refresh-failure')){
    Test-Case "Writer integration: $scenario" {
        $output=@(& $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'writer-harness.ps1') -Scenario $scenario 2>&1)
        $exit=$LASTEXITCODE;$result=$output[-1]|ConvertFrom-Json
        $expected=if($scenario -in 'deferred-publish','deferred-publish-mounted'){0}else{1}
        Assert-Test ($result.HarnessPassed -and $exit -eq $expected) "Harness failed: $($output -join ' ')"
    }
}
Write-Host "Results: $passed passed, $failures failed"
if ($failures) { exit 1 }
exit 0
