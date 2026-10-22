# File-only factory entry; no physical target is selected or written.
param([string]$Workspace='',[switch]$NewBuild,[switch]$Plan,[switch]$Status,[switch]$NoPause,[switch]$KeepIntermediates,
      [ValidateSet('Auto','WHPX','TCG')][string]$Accel='Auto',[int]$RamMb=0,[int]$Cores=0,
      [ValidateRange(10,720)][int]$TimeoutMin=240)
$ErrorActionPreference='Stop';$code=1
try{
 . (Join-Path $PSScriptRoot 'lib\pf-storage.ps1')
 . (Join-Path $PSScriptRoot 'factory\usb.ps1')
 $storage=Get-PfStorageRoot (Split-Path $PSScriptRoot -Parent)
 $pointer=Join-Path $storage 'last-image-build.json'
 if($Workspace -and $NewBuild){throw 'Use -Workspace for a chosen directory or -NewBuild for a new automatic directory.'}
 if(-not $Workspace -and -not $NewBuild -and (Test-Path -LiteralPath $pointer)){$Workspace=(Get-Content -LiteralPath $pointer -Raw -Encoding UTF8|ConvertFrom-Json).Workspace}
 if(-not $Workspace){$Workspace=Join-Path $storage ('builds\image-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))}
 $Workspace=[IO.Path]::GetFullPath($Workspace)
 $parameters=@{Workspace=$Workspace;Accel=$Accel;RamMb=$RamMb;Cores=$Cores;TimeoutMin=$TimeoutMin;NoPause=$true}
 if($KeepIntermediates){$parameters.KeepIntermediates=$true}
 if($Plan){$parameters.Plan=$true}elseif($Status){$parameters.Status=$true}else{
  Set-PfStorageEnvironment -Root (Join-Path $storage 'environment') -Create
  if(Test-Path -LiteralPath (Join-Path $Workspace 'factory-state.json')){$parameters.Resume=$true}
  $null=[IO.Directory]::CreateDirectory($storage)
  Write-PfPreparationJson $pointer @{Schema=1;Workspace=$Workspace}
 }
 Write-Host ('Рабочий каталог: '+$Workspace)
 Invoke-PfPreparationScript (Join-Path $PSScriptRoot 'build-debian.ps1') $parameters
 $code=0
}catch{Write-Host ($_|Out-String) -ForegroundColor Red}
if(-not($NoPause -or $Plan -or $Status)){$null=Read-Host 'Enter — закрыть'}
exit $code
