param()
$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$path = Join-Path $PSScriptRoot 'usb-root-export.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors -join '; ') }
$passed = 0
function Assert-Test($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:passed++
}
function Assert-Throws([scriptblock]$Body, [string]$Pattern) {
    $caught = $null
    try { & $Body | Out-Null } catch { $caught = $_ }
    Assert-Test ($null -ne $caught -and $caught.Exception.Message -match $Pattern) "Expected $Pattern; got $caught"
}
$parameter = @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Layout' })
Assert-Test ($parameter.Count -eq 1) 'Expected one Layout parameter.'
$bind = [scriptblock]::Create('param(' + $parameter[0].Extent.Text + ') $Layout')
Assert-Test ((& $bind) -eq 'Legacy') 'Legacy must remain the default.'
foreach ($invalid in @('Unknown', '', '22545432576')) {
    Assert-Throws { & $bind -Layout $invalid } 'ValidateSet|does not belong'
}
# Evaluate only profile/path assignments and the fingerprint function, never the disk/export body.
$names = @('$ExpectedSerialNumber', '$ExpectedSize', '$rootOffset', '$rootSize', '$slice', '$linuxGuid', '$work', '$backup', '$metadataPath', '$stopPath', '$identity')
$assignments = @($ast.EndBlock.Statements | Where-Object {
    $_ -is [Management.Automation.Language.AssignmentStatementAst] -and
    ($_.Left.Extent.Text -replace '^\[UInt64\]', '') -in $names
})
Assert-Test ($assignments.Count -eq $names.Count) 'Cannot locate profile/path assignments.'
$fingerprint = $ast.Find({ param($n)
    $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-SourceFingerprint'
}, $true)
. ([scriptblock]::Create($fingerprint.Extent.Text))
function Assert-PfUsbDisk {
    param($Number, $Identity)
    Assert-Test ($Number -eq 2 -and $Identity.Path -eq 'mock-device' -and
        $Identity.SerialNumber -eq '0E7113C55070' -and $Identity.Size -eq 31042043904) 'Device identity changed.'
    [pscustomobject]@{ Path = $Identity.Path; SerialNumber = $Identity.SerialNumber; Size = $Identity.Size; Number = $Number; Guid = 'disk-guid'; PartitionStyle = 'GPT' }
}
function Get-PfDiskPartitions { param($Number) $script:partition }
function Get-Volume { param([Parameter(ValueFromPipeline)]$Partition) }
function Get-PfGuidVolumePath { param($Partition) 'mock-volume' }
$repo = '/mock-host'; $DiskNumber = 2; $ExpectedDevicePath = 'mock-device'
$paths = @{}
foreach ($Layout in @('Legacy', 'Esp2GiB')) {
    foreach ($assignment in $assignments) { . ([scriptblock]::Create($assignment.Extent.Text)) }
    $expectedOffset = if ($Layout -eq 'Legacy') { 7518289920 } else { 2149580800 }
    $expectedSize = if ($Layout -eq 'Legacy') { 22545432576 } else { 28891414528 }
    Assert-Test ($rootOffset -eq $expectedOffset -and $rootSize -eq $expectedSize) "$Layout geometry"
    Assert-Test ($slice -eq "driver=raw,offset=$expectedOffset,size=$expectedSize,file.driver=host_device,file.filename=\\.\PhysicalDrive2") "$Layout bounded slice"
    $paths[$Layout] = @($work, $backup, $metadataPath, $stopPath)
    $partition = [pscustomobject]@{ Offset = $expectedOffset; Size = $expectedSize; GptType = $linuxGuid; PartitionNumber = 3; Guid = 'root-guid' }
    $source = Get-SourceFingerprint
    Assert-Test ($source.Offset -eq $expectedOffset -and $source.Size -eq $expectedSize -and
        $source.Layout.Count -eq 1 -and $source.VolumePath -eq 'mock-volume') "$Layout fingerprint"
    $partition.Offset++
    Assert-Throws { Get-SourceFingerprint } 'geometry differs'
    $partition.Offset = $expectedOffset; $partition.Size++
    Assert-Throws { Get-SourceFingerprint } 'geometry differs'
    $partition.Offset = if ($Layout -eq 'Legacy') { 2149580800 } else { 7518289920 }
    $partition.Size = if ($Layout -eq 'Legacy') { 28891414528 } else { 22545432576 }
    Assert-Throws { Get-SourceFingerprint } 'geometry differs'
}
Assert-Test ($paths.Legacy[0] -eq (Join-Path $repo 'diagnostics/usb-before-firstboot-fix')) 'Legacy work directory changed.'
Assert-Test ($paths.Esp2GiB[0] -eq (Join-Path $repo 'diagnostics/usb-before-firstboot-fix-esp2gib')) 'Esp2GiB work directory'
for ($i = 0; $i -lt 4; $i++) {
    Assert-Test ($paths.Legacy[$i] -ne $paths.Esp2GiB[$i]) 'Profiles must not share work/backup/metadata/stop paths.'
}
$bytes = [IO.File]::ReadAllBytes($path)
Assert-Test ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191 -and -not ($bytes -contains 13)) 'Helper must remain UTF-8 BOM/LF.'
Write-Host "PASS: $passed layout assertions; AST/mocks only, no disk operations or QEMU."
