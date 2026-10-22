# Current Debian/XFCE/Ventoy factory entrypoint. Outputs stay in a new workspace.
param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [switch]$Resume,
    [switch]$RefreshSources,
    [ValidateSet('Auto','WHPX','TCG')][string]$Accel='Auto',
    [int]$RamMb=0,
    [int]$Cores=0,
    [long]$UsbBytes=0,
    [switch]$KeepIntermediates,
    [ValidateSet('inputs','seed','images','provision','layout','assemble','direct1','ventoy2','direct3','finalize')][string]$ToStage='finalize',
    [ValidateRange(10,720)][int]$TimeoutMin=240,
    [switch]$Status,
    [switch]$Stop,
    [switch]$ForceStop,
    [switch]$WriteUsb,
    [int]$DiskNumber=-1,
    [string]$ExpectedSerialNumber='',
    [long]$ExpectedSize=0,
    [switch]$Plan,
    [switch]$Elevated,
    [switch]$NoPause
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
try{[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)}catch{}
. (Join-Path $PSScriptRoot 'lib\pf-storage.ps1')
if($Workspace){Set-PfStorageEnvironment -Root (Join-Path ([IO.Path]::GetFullPath($Workspace)) 'bootstrap\environment')}
$exitCode=1
try{
 $repo=Split-Path $PSScriptRoot -Parent
 if($ForceStop -and -not $Stop){throw '-ForceStop requires -Stop.'}
 if($WriteUsb -and ($DiskNumber -lt 0 -or -not $ExpectedSerialNumber -or $ExpectedSize -le 0 -or $ToStage -ne 'finalize')){throw '-WriteUsb requires DiskNumber, ExpectedSerialNumber, ExpectedSize and finalization.'}
 if($WriteUsb -and $UsbBytes -eq 0){$UsbBytes=$ExpectedSize}
 $Workspace=[IO.Path]::GetFullPath($Workspace).TrimEnd('\')
 if($Workspace -notmatch '^[A-Za-z]:\\' -or $Workspace -ieq $repo -or $Workspace.StartsWith($repo.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or $repo.StartsWith($Workspace+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Choose a dedicated local workspace outside the source tree.'}
 for($p=$Workspace;$p -and (Split-Path $p -Parent) -ne $p;$p=Split-Path $p -Parent){
  if(Test-Path -LiteralPath $p){if((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Factory workspace cannot use redirected directories.'}}
 }
 $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
 try{$admin=([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)}finally{$identity.Dispose()}
 if(-not($Plan -or $Status) -and -not $admin){
  if($Elevated){throw 'Factory image mounting requires an administrator token.'}
  $command="& '"+$PSCommandPath.Replace("'","''")+"' -Workspace '"+$Workspace.Replace("'","''")+"' -Elevated -NoPause -Accel '"+$Accel+"' -RamMb "+$RamMb+' -Cores '+$Cores+' -UsbBytes '+$UsbBytes+" -ToStage '"+$ToStage+"' -TimeoutMin "+$TimeoutMin
  if($Resume -or $Stop){$command+=' -Resume'};if($Stop){$command+=' -Stop'};if($RefreshSources){$command+=' -RefreshSources'}
  if($ForceStop){$command+=' -ForceStop'}
  if($KeepIntermediates){$command+=' -KeepIntermediates'}
  if($WriteUsb){$command+=' -WriteUsb -DiskNumber '+$DiskNumber+" -ExpectedSerialNumber '"+$ExpectedSerialNumber.Replace("'","''")+"' -ExpectedSize "+$ExpectedSize}
  $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
  $child=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) -Verb RunAs -Wait -PassThru
  try{if($null -eq $child.ExitCode){throw 'Missing elevated factory exit code.'};$exitCode=$child.ExitCode}finally{$child.Dispose()}
 }else{
  if(Test-Path -LiteralPath $Workspace){
   $state=Join-Path $Workspace 'factory-state.json'
   if(-not(Test-Path -LiteralPath $state) -and @(Get-ChildItem -LiteralPath $Workspace -Force|Where-Object{$_.Name -ne 'bootstrap'}).Count){throw 'Existing workspace is not owned by the Debian factory.'}
   if((Test-Path -LiteralPath $state) -and -not($Resume -or $Status -or $Plan -or $Stop)){throw 'Existing build: use -Resume.'}
  }
  if($Plan){
   Write-Output 'Debian 13 generic -> desktop/languages/full profile -> vtoyboot -> functional checks -> NTFS/Ventoy layout -> direct/Ventoy/direct proof -> verified 32-GB USB image.'
   Write-Output 'The factory writes ordinary files in its dedicated workspace. It does not select a physical USB disk.'
   $exitCode=0
  }elseif($Status){
   Get-Content -LiteralPath (Join-Path $Workspace 'factory-state.json') -Raw -Encoding UTF8
   $exitCode=0
  }else{
   $null=[IO.Directory]::CreateDirectory($Workspace)
   $bootstrap=Join-Path $Workspace 'bootstrap';$null=[IO.Directory]::CreateDirectory($bootstrap)
   Set-PfStorageEnvironment -Root (Join-Path $bootstrap 'environment') -Create
   $config=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'factory\inputs.json') -Raw -Encoding UTF8|ConvertFrom-Json
   $zip=Join-Path $bootstrap $config.python.name
    if(-not(Test-Path -LiteralPath $zip)){
     $partial=$zip+'.partial'
     $bundled=if($env:PF_INPUT_CACHE){Join-Path $env:PF_INPUT_CACHE $config.python.name}else{''}
     if($bundled -and (Test-Path -LiteralPath $bundled -PathType Leaf)){
      if((Get-FileHash -LiteralPath $bundled -Algorithm SHA256).Hash -ne $config.python.sha256){throw 'Bundled Python bootstrap checksum mismatch.'}
      [IO.File]::Copy($bundled,$partial,$true)
     }else{
      if($env:PF_OFFLINE -eq '1'){throw 'Offline pipeline Python bootstrap is missing.'}
      [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
      $client=[Net.WebClient]::new();try{$client.DownloadFile($config.python.url,$partial)}finally{$client.Dispose()}
     }
    if((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ne $config.python.sha256){throw 'Python bootstrap checksum mismatch.'}
    [IO.File]::Move($partial,$zip)
   }
   if((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $config.python.sha256){throw 'Stored Python bootstrap changed.'}
   $python=Join-Path $bootstrap 'python\python.exe'
   if(-not(Test-Path -LiteralPath $python)){
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $directory=Join-Path $bootstrap 'python.partial'
    if(Test-Path -LiteralPath $directory){Remove-Item -LiteralPath $directory -Recurse -Force}
    [IO.Compression.ZipFile]::ExtractToDirectory($zip,$directory)
    [IO.Directory]::Move($directory,(Join-Path $bootstrap 'python'))
   }
   $arguments=@((Join-Path $PSScriptRoot 'factory\build.py'),'--workspace',$Workspace,'--accelerator',$Accel,'--ram-mb',[string]$RamMb,'--cores',[string]$Cores,'--to-stage',$ToStage,'--timeout-min',[string]$TimeoutMin)
    if($UsbBytes){$arguments+=@('--usb-bytes',[string]$UsbBytes)}
    if($KeepIntermediates){$arguments+='--keep-intermediates'}
   if($Resume -or $Stop){$arguments+='--resume'};if($Stop){$arguments+='--stop'};if($RefreshSources){$arguments+='--refresh-sources'};if($Status){$arguments+='--status'}
   if($ForceStop){$arguments+='--force-stop'}
   $env:PYTHONUTF8='1';$env:PYTHONIOENCODING='utf-8'
   & $python @arguments
   $exitCode=$LASTEXITCODE
   if($exitCode -eq 0 -and $WriteUsb){
    $result=Get-Content -LiteralPath (Join-Path $Workspace 'artifacts\build-result.json') -Raw -Encoding UTF8|ConvertFrom-Json
    if(-not $result.complete){throw 'No verified final factory artifact.'}
    $disk=Get-Disk -Number $DiskNumber
    if($disk.SerialNumber.Trim() -ne $ExpectedSerialNumber.Trim() -or $disk.Size -ne $ExpectedSize -or $disk.IsSystem -or $disk.IsBoot -or $disk.BusType -ne 'USB'){throw 'Explicit USB target identity mismatch.'}
    & (Join-Path $PSScriptRoot 'write-image.ps1') -ImagePath $result.image -DiskNumber $DiskNumber -ExpectedDevicePath $disk.Path -ExpectedSerialNumber $ExpectedSerialNumber -ExpectedSize $ExpectedSize -Yes -VerifyFull -DeferPartitionTable -VerifyBeforePublish
    $exitCode=$LASTEXITCODE
   }
  }
 }
}catch{Write-Host ($_|Out-String) -ForegroundColor Red;$exitCode=1}
if($exitCode -ne 0 -and -not $NoPause){$null=Read-Host 'Ошибка сохранена в рабочем каталоге. Enter — закрыть'}
exit $exitCode
