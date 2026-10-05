param()
$ErrorActionPreference = 'Stop'
$launcher = Join-Path (Split-Path $PSScriptRoot -Parent) 'usb-launcher/run-qemu.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors -join '; ') }
function Assert-Test($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Throws([scriptblock]$Body, [string]$Pattern) {
    $caught = $null
    try { & $Body | Out-Null } catch { $caught = $_ }
    Assert-Test ($caught -and $caught.Exception.Message -match $Pattern) "Expected error matching $Pattern; got $caught"
}
function Find-Assignment([string]$Name) {
    $nodes = @($ast.FindAll({ param($n)
        $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq $Name
    }, $true))
    Assert-Test ($nodes.Count -eq 1) "Expected unique assignment $Name"
    $nodes[0]
}
$profileFunction = $ast.Find({ param($n)
    $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-LauncherProfile'
}, $true)
. ([scriptblock]::Create($profileFunction.Extent.Text))
function Get-CimInstance {
    param($ClassName, $ErrorAction)
    switch ($ClassName) {
        Win32_ComputerSystem { [pscustomobject]@{ TotalPhysicalMemory = $script:totalMb * 1MB; NumberOfLogicalProcessors = $script:logical } }
        Win32_OperatingSystem { [pscustomobject]@{ FreePhysicalMemory = $script:freeMb * 1024 } }
        default { throw "Unexpected CIM class $ClassName" }
    }
}
$totalMb = 16384; $freeMb = 12000; $logical = 12
$profile = Get-LauncherProfile 0 0
Assert-Test ($profile.RamMb -eq 6144 -and $profile.Cores -eq 4) '16 GB / Ryzen 12-thread auto profile'
$totalMb = 10240; $logical = 6
$profile = Get-LauncherProfile 0 0
Assert-Test ($profile.RamMb -eq 5120 -and $profile.Cores -eq 3) 'Half-total RAM and half-logical CPU'
$totalMb = 16384; $freeMb = 7000; $logical = 1
$profile = Get-LauncherProfile 0 0
Assert-Test ($profile.RamMb -eq 4096 -and $profile.Cores -eq 1) 'Whole-GB free-memory reduction and CPU minimum'
$freeMb = 4096
Assert-Test ((Get-LauncherProfile 0 0).RamMb -eq 2048) 'Exact minimum free RAM'
$freeMb = 4095
Assert-Throws { Get-LauncherProfile 0 0 } 'Insufficient host memory'
$freeMb = 12000; $totalMb = 4095
Assert-Throws { Get-LauncherProfile 0 0 } 'Insufficient host memory'
$totalMb = 16384; $freeMb = 14336; $logical = 12
$profile = Get-LauncherProfile 12288 12
Assert-Test ($profile.RamMb -eq 12288 -and $profile.Cores -eq 12) 'Explicit RAM above half total and full CPU override'
foreach ($ram in @(-1, 2047, 12289)) { Assert-Throws { Get-LauncherProfile $ram 0 } 'RamMb must' }
foreach ($cpu in @(-1, 13)) { Assert-Throws { Get-LauncherProfile 0 $cpu } 'Cores must' }
$freeMb = 8191
Assert-Throws { Get-LauncherProfile 6144 4 } 'Insufficient available memory'
$freeMb = 8192
Assert-Test ((Get-LauncherProfile 6144 4).RamMb -eq 6144) 'Exact explicit reserve'
Write-Host 'PASS resource branches (mocked CIM only)'

$paramProbe = [scriptblock]::Create($ast.ParamBlock.Extent.Text + "`n[pscustomobject]@{ RamMb = `$RamMb; Cores = `$Cores; Accel = `$Accel }")
$defaults = & $paramProbe
Assert-Test ($defaults.RamMb -eq 0 -and $defaults.Cores -eq 0 -and $defaults.Accel -eq 'Auto') 'Public defaults'
Assert-Throws { & $paramProbe -Accel KVM } 'ValidateSet|does not belong'
$hostScript = "C:\host space\it's runtime\run-qemu.ps1"
$RamMb = 5120; $Cores = 6; $Accel = 'TCG'
foreach ($serial in @('', "serial ' quoted \")) {
    $identity = [pscustomobject]@{ Path = "device ' path \"; SerialNumber = $serial; Size = 123456789L }
    $command = & ([scriptblock]::Create((Find-Assignment '$command').Right.Extent.Text))
    $encoded = & ([scriptblock]::Create((Find-Assignment '$encoded').Right.Extent.Text))
    $decoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))
    Assert-Test ($decoded -ceq $command) 'Encoded command roundtrip'
    $parsed = [Management.Automation.Language.Parser]::ParseInput($decoded, [ref]$tokens, [ref]$errors)
    Assert-Test ($errors.Count -eq 0) 'Bootstrap parse'
    $call = $parsed.Find({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true)
    $elements = $call.CommandElements
    Assert-Test ($elements[0].Value -ceq $hostScript) 'Host script literal'
    foreach ($pair in @(@('DevicePath', $identity.Path), @('SerialNumber', $serial), @('DeviceSize', '123456789'), @('RamMb', '5120'), @('Cores', '6'), @('Accel', 'TCG'))) {
        $found = $false
        for ($i = 1; $i -lt $elements.Count - 1; $i++) {
            if ($elements[$i] -is [Management.Automation.Language.CommandParameterAst] -and $elements[$i].ParameterName -eq $pair[0]) {
                Assert-Test ([string]$elements[$i + 1].SafeGetValue() -ceq $pair[1]) "Bootstrap value $($pair[0])"
                $found = $true
            }
        }
        Assert-Test $found "Missing bootstrap parameter $($pair[0])"
    }
}
Write-Host 'PASS bootstrap identity/resource literals and encoded propagation'

# Extract only pure argument helpers; never import or execute disk/SSH workflows.
$modulePath = Join-Path (Split-Path $launcher -Parent) 'lib/pf-tools.psm1'
$moduleAst = [Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$errors)
foreach ($name in @('Get-PfQemuBaseArgs', 'ConvertTo-PfArgumentList')) {
    $definition = $moduleAst.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Find-PfQemu { param($ScriptDir, $Exe) $Exe }
function Find-PfOvmf { param($QemuExe) 'C:\host space\firmware.fd' }
$accelFilter = $ast.Find({ param($n)
    $n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq "$" + "Accel -ne 'Auto'"
}, $true)
Assert-Test ($null -ne $accelFilter) 'Accelerator filter AST'
foreach ($Accel in @('Auto', 'WHPX', 'TCG')) {
    $qemuArgs = Get-PfQemuBaseArgs -RamMb 6144 -Cores 4 -Uefi -QemuExe 'C:\host space\qemu.exe'
    . ([scriptblock]::Create($accelFilter.Extent.Text))
    $accelerators = @(for ($i = 0; $i -lt $qemuArgs.Count; $i++) { if ($qemuArgs[$i] -eq '-accel') { $qemuArgs[$i + 1] } })
    $expected = switch ($Accel) { Auto { 'whpx,kernel-irqchip=off|tcg' } WHPX { 'whpx,kernel-irqchip=off' } TCG { 'tcg,thread=multi' } }
    Assert-Test (($accelerators -join '|') -ceq $expected) "Accelerators $Accel"
    Assert-Test ($qemuArgs -contains 'Westmere' -and $qemuArgs -contains '6144M' -and $qemuArgs -contains '4') 'Known CPU/RAM/vCPU arguments'
    $nativeArgs = ConvertTo-PfArgumentList -Arguments $qemuArgs
    $roundtrip = @([regex]::Matches(($nativeArgs -join ' '), '"[^"]*"|\S+') | ForEach-Object { $_.Value.Trim('"') })
    Assert-Test (($roundtrip -join '|') -ceq ($qemuArgs -join '|')) 'Known native command arguments roundtrip including spaced firmware path'
}
$start = $ast.Find({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Start-Process' }, $true)
Assert-Test ($start.Extent.Text -match '-PassThru' -and $start.Extent.Text -match '-ArgumentList \$nativeArgs' -and $start.Extent.Text -match '-RedirectStandardOutput' -and $start.Extent.Text -match '-RedirectStandardError' -and $start.Extent.Text -notmatch 'WindowStyle|NoNewWindow') 'Visible child and redirected host logs'
$cleanup = $ast.EndBlock.Statements[-2].Finally.Extent.Text
Assert-Test ($cleanup.IndexOf('$qemuProcess.WaitForExit()') -lt $cleanup.IndexOf('Release-PfVolumeLocks')) 'Child wait precedes unlock'
Assert-Test ($cleanup -match '\$qemuProcess.Kill\(\)' -and $ast.Extent.Text -notmatch 'Stop-Process') 'Only owned process is terminated'
$cleanupProbe = [scriptblock]::Create($cleanup.Substring(1, $cleanup.Length - 2))
$Runtime = $true; $runtimeDir = $null; $stderrLog = $null; $locks = @('mock lock')
function Release-PfVolumeLocks { param($Locks) $script:events.Add('unlock') }
foreach ($alreadyExited in @($true, $false)) {
    $events = [Collections.Generic.List[string]]::new()
    $qemuProcess = [pscustomobject]@{ HasExited = $alreadyExited }
    $qemuProcess | Add-Member ScriptMethod Kill { $script:events.Add('kill'); $this.HasExited = $true }
    $qemuProcess | Add-Member ScriptMethod WaitForExit { $script:events.Add('wait'); if (-not $this.HasExited) { throw 'Still running' } }
    $qemuProcess | Add-Member ScriptMethod Dispose { $script:events.Add('dispose') }
    . $cleanupProbe
    $expected = if ($alreadyExited) { 'wait|dispose|unlock' } else { 'kill|wait|dispose|unlock' }
    Assert-Test (($events -join '|') -ceq $expected) 'Mocked normal/exception child cleanup ordering'
}
$events.Clear()
$qemuProcess = [pscustomobject]@{ HasExited = $false }
$qemuProcess | Add-Member ScriptMethod Kill { throw 'Mock termination failure' }
Assert-Throws { . $cleanupProbe } 'Mock termination failure'
Assert-Test (-not $events.Contains('unlock')) 'Do not unlock when child termination fails'
$text = $ast.Extent.Text
$promptOffset = $text.IndexOf("Read-Host 'Enter to lock")
$profileOffset = $text.IndexOf('$profile = Get-LauncherProfile', $promptOffset)
$lockOffset = $text.IndexOf('Lock-PfDiskVolumes -Number')
Assert-Test ($profileOffset -gt $promptOffset -and $profileOffset -lt $lockOffset) 'Post-prompt resource check before locks'
Assert-Test ($text.IndexOf('Available memory changed before QEMU launch') -lt $text.IndexOf('Start-Process -FilePath $qemu')) 'Final available-memory check before QEMU'
$freeMb = 8192
Assert-Test ((Get-LauncherProfile 0 0).RamMb -eq 6144) 'Initial auto RAM'
$freeMb = 6144
Assert-Test ((Get-LauncherProfile 0 0).RamMb -eq 4096) 'Auto RAM shrinks on post-prompt recheck'
$bytes = [IO.File]::ReadAllBytes($launcher)
Assert-Test ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191 -and -not ($bytes -contains 13)) 'Launcher BOM / LF preservation'
Write-Host 'PASS accelerator policies, known command arguments, mocked cleanup, recheck ordering, BOM/LF'
Write-Host 'Launcher tests passed; no physical drive, SSH, or real QEMU launched.'
