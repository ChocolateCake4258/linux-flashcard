# Exercise actual file-launcher parameter/resource code and WHPX readiness guard.
$ErrorActionPreference='Stop'
$win=Split-Path $PSScriptRoot -Parent
. (Join-Path $win 'lib\pf-whpx.ps1')
function Assert-Test($Condition,[string]$Message){if(-not $Condition){throw $Message}}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $win 'run-from-usb.ps1'),[ref]$tokens,[ref]$errors)
Assert-Test ($errors.Count -eq 0) 'File launcher parse failed.'
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
$profile=[scriptblock]::Create('param('+($declarations -join ',')+")`n"+$text.Substring($start[0].Extent.StartOffset,$end[0].Extent.StartOffset-$start[0].Extent.StartOffset)+"`n[pscustomobject]@{Ram=`$RamMb;Cpu=`$Cores}")
function Get-CimInstance {
    param($ClassName)
    if($ClassName -eq 'Win32_ComputerSystem'){return [pscustomobject]@{TotalPhysicalMemory=16GB;NumberOfLogicalProcessors=12}}
    if($ClassName -eq 'Win32_OperatingSystem'){return [pscustomobject]@{FreePhysicalMemory=$script:freeMiB*1024}}
    throw 'Unexpected CIM query.'
}
function Test-Profile($Mode,$Free,$ExpectedRam,$ExpectedCpu,$Bound=@{}){
    $script:freeMiB=$Free
    $selected=& $profile -Accel $Mode @Bound
    Assert-Test ($selected.Ram -eq $ExpectedRam -and $selected.Cpu -eq $ExpectedCpu) "Wrong resources for $Mode / $Free MiB: actual $($selected.Ram)/$($selected.Cpu), expected $ExpectedRam/$ExpectedCpu."
}
Test-Profile WHPX 10000 6144 4
Test-Profile WHPX 7000 4096 4
Test-Profile WHPX 5000 2048 4
Test-Profile WHPX 10000 4096 2 @{RamMb=4096;Cores=2}
Test-Profile TCG 10000 4096 2 @{RamMb=0;Cores=0}
$caught=$false;try{Test-Profile WHPX 3000 0 0}catch{$caught=$_.Exception.Message -match 'Недостаточно памяти'}
Assert-Test $caught 'Insufficient memory must reject even when WHPX is available.'
Write-Host 'PASS WHPX explicit/default selection, unavailable API guidance, auto/explicit resources and memory reserve.'
