# Exercise actual file-launcher parameter/resource code and WHPX readiness guard.
$ErrorActionPreference='Stop'
$win=Split-Path $PSScriptRoot -Parent
. (Join-Path $win 'lib\pf-whpx.ps1')
function Assert-Test($Condition,[string]$Message){if(-not $Condition){throw $Message}}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $win 'run-from-usb.ps1'),[ref]$tokens,[ref]$errors)
Assert-Test ($errors.Count -eq 0) 'File launcher parse failed.'
$candidateFunction=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-DefaultDiskCandidates'},$true))
Assert-Test ($candidateFunction.Count -eq 1) 'Cannot locate actual default-image lookup.'
. ([scriptblock]::Create($candidateFunction[0].Extent.Text))
$root=[IO.Path]::GetPathRoot($win)
$candidates=@(Get-DefaultDiskCandidates -Directory $root)
Assert-Test ($candidates.Count -eq 1 -and $candidates[0] -eq (Join-Path $root 'virtual-disk.qcow2')) 'A launcher at a volume root must not pass an empty parent to Join-Path.'
$candidates=@(Get-DefaultDiskCandidates -Directory $win)
Assert-Test ($candidates.Count -eq 2 -and $candidates[0] -eq (Join-Path $win 'virtual-disk.qcow2') -and $candidates[1] -eq (Join-Path (Split-Path $win -Parent) 'virtual-disk.qcow2')) 'Nested default-image lookup lost its adjacent/parent order.'
$parameter=@($ast.ParamBlock.Parameters|Where-Object{$_.Name.VariablePath.UserPath -eq 'Accel'})
Assert-Test ($parameter.Count -eq 1) 'Acceleration parameter missing.'
$bind=[scriptblock]::Create('param('+$parameter[0].Extent.Text+') $Accel')
Assert-Test ((& $bind) -ceq 'TCG') 'Ordinary launcher must default to TCG.'
$caught=$false;try{& $bind -Accel Auto|Out-Null}catch{$caught=$true}
Assert-Test $caught 'Implicit WHPX/TCG fallback policy must not be accepted.'
foreach($reason in @('API not installed','HypervisorPresent=false','WHvGetCapability failed')){
    $caught=$false
    try{Assert-PfWhpxAvailable -Status ([pscustomobject]@{Available=$false;Detail=$reason})}catch{
        $caught=$_.Exception.Message.Contains($reason) -and $_.Exception.Message.Contains('enable-acceleration.bat')
    }
    Assert-Test $caught 'Unavailable WHPX must fail with actionable setup guidance.'
}
Assert-PfWhpxAvailable -Status ([pscustomobject]@{Available=$true;Detail='ready'})
$start=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$stage' -and $n.Right.Extent.Text -eq "'prepare-profile'"},$true))
$end=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$stage' -and $n.Right.Extent.Text -eq "'prepare-persistent-uefi'"},$true))
Assert-Test ($start.Count -eq 1 -and $end.Count -eq 1) 'Cannot locate actual resource selection block.'
$text=[IO.File]::ReadAllText((Join-Path $win 'run-from-usb.ps1'))
$declarations=@($ast.ParamBlock.Parameters|Where-Object{$_.Name.VariablePath.UserPath -in 'Accel','RamMb','Cores'}|ForEach-Object{$_.Extent.Text})
$profile=[scriptblock]::Create('param('+($declarations -join ',')+")`n"+$text.Substring($start[0].Extent.StartOffset,$end[0].Extent.StartOffset-$start[0].Extent.StartOffset)+"`n[pscustomobject]@{Ram=`$RamMb;Cpu=`$Cores;Budget=`$ramBudgetMb;Auto=`$autoRam;Minimum=`$minimumRamMb;Reserve=`$windowsReserveMb}")
function Get-CimInstance {
    param($ClassName)
    if($ClassName -eq 'Win32_ComputerSystem'){return [pscustomobject]@{TotalPhysicalMemory=($script:totalMiB*1MB);NumberOfLogicalProcessors=12}}
    if($ClassName -eq 'Win32_OperatingSystem'){return [pscustomobject]@{FreePhysicalMemory=$script:freeMiB*1024}}
    throw 'Unexpected CIM query.'
}
function Test-Profile($Mode,$Free,$ExpectedRam,$ExpectedCpu,$Bound=@{},$Total=16384){
    $script:freeMiB=$Free;$script:totalMiB=$Total
    $selected=& $profile -Accel $Mode @Bound
    Assert-Test ($selected.Ram -eq $ExpectedRam -and $selected.Cpu -eq $ExpectedCpu) "Wrong resources for $Mode / $Free MiB: actual $($selected.Ram)/$($selected.Cpu), expected $ExpectedRam/$ExpectedCpu."
    Assert-Test ($selected.Minimum -eq 320 -and $selected.Reserve -eq 2048 -and $selected.Ram -le $selected.Budget) 'The tested guest minimum or host reserve was lost.'
    if(-not $Bound.ContainsKey('RamMb') -or $Bound.RamMb -eq 0){Assert-Test ($selected.Auto -and $selected.Ram -eq $selected.Budget) 'Auto RAM must use the complete whole-MiB budget.'}
    else{Assert-Test (-not $selected.Auto -and $selected.Ram -eq $Bound.RamMb) 'Explicit RAM was replaced by an automatic choice.'}
}
Test-Profile WHPX 10000 7952 4
Test-Profile WHPX 7000 4952 4
Test-Profile WHPX 5000 2952 4
Test-Profile WHPX 10000 4096 2 @{RamMb=4096;Cores=2}
Test-Profile TCG 10000 7952 2
Test-Profile TCG 6000 3952 2
Test-Profile TCG 5000 2952 2
Test-Profile TCG 4096 2048 2
Test-Profile TCG 5000 2048 1 @{RamMb=2048;Cores=1}
Test-Profile TCG 10000 7952 2 @{RamMb=0;Cores=0}
foreach($mode in @('TCG','WHPX')){
    $cpu=if($mode -eq 'TCG'){2}else{4}
    Test-Profile $mode 3030 982 $cpu
    Test-Profile $mode 2442 394 $cpu
    Test-Profile $mode 2429 381 $cpu
    Test-Profile $mode 2383 335 $cpu
    Test-Profile $mode 2368 320 $cpu
    Test-Profile $mode 2368 320 $cpu @{RamMb=320}
    Test-Profile $mode 3030 512 $cpu @{RamMb=512}
    Test-Profile $mode 10000 6144 $cpu @{} 8192
    foreach($free in @(2367,2048,512)){
        $caught=$false;try{Test-Profile $mode $free 0 0}catch{$caught=$_.Exception.Message -match 'минимум 320 МБ'}
        Assert-Test $caught 'Insufficient RAM must retain the real minimum instead of clamping upward or reporting a negative requirement.'
    }
    $caught=$false;try{Test-Profile $mode 5000 0 0 @{RamMb=319}}catch{$caught=$_.Exception.Message -match 'минимум 320 МБ'}
    Assert-Test $caught 'Untested sub-minimum guest RAM must be rejected.'
}
$caught=$false;try{Test-Profile TCG 5000 0 0 @{RamMb=4096;Cores=2}}catch{$caught=$_.Exception.Message -match 'Недостаточно памяти'}
Assert-Test $caught 'An explicit RAM request must not be silently reduced.'
Write-Host 'PASS volume-root lookup, explicit accelerator, maximum whole-MiB auto budget, 320-MiB floor, manual RAM and host reserve.'
