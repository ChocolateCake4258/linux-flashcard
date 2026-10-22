# Run the sealed, offline pipeline capsule from its current extracted location.
param(
 [ValidateSet('Image','Usb','Check')][string]$Mode='Image',
 [string]$Workspace='', [switch]$NewBuild, [switch]$Plan, [switch]$Status,
 [ValidateSet('Auto','WHPX','TCG')][string]$Accel='Auto', [int]$RamMb=0, [int]$Cores=0,
 [ValidateRange(10,720)][int]$TimeoutMin=240, [switch]$NoPause, [switch]$Elevated
)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';$code=1
try{
 $source=Split-Path $PSScriptRoot -Parent;$capsule=Split-Path $source -Parent
 $manifest=Get-Content -LiteralPath (Join-Path $capsule 'PIPELINE-MANIFEST.json') -Raw -Encoding UTF8|ConvertFrom-Json
 if($manifest.schema -ne 1 -or $manifest.format -ne 'LinuxFlashcardPipelineCapsule' -or $manifest.version -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,60}$'){throw 'Unsupported pipeline capsule.'}
 . (Join-Path $PSScriptRoot 'lib\pf-storage.ps1')
 $env:PF_STORAGE_ROOT=Join-Path (Split-Path $capsule -Parent) ('work-'+$manifest.version)
 Set-PfStorageEnvironment -Root (Join-Path $env:PF_STORAGE_ROOT 'environment') -Create
 $env:PF_INPUT_CACHE=Join-Path $capsule 'inputs';$env:PF_OFFLINE='1'
 $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
 try{$admin=([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)}finally{$identity.Dispose()}
 if($Mode -ne 'Check' -and -not($Plan -or $Status) -and -not $admin){
  if($Elevated){throw 'Pipeline image preparation requires an administrator token.'}
  $command=''
  foreach($name in @('TEMP','TMP','LOCALAPPDATA','APPDATA','USERPROFILE','HOME','XDG_CACHE_HOME','PSModuleAnalysisCachePath')){
   $value=[Environment]::GetEnvironmentVariable($name,'Process')
   if($value){$command+='$env:'+ $name +"='"+$value.Replace("'","''")+"';"}
  }
  $command+="& '"+$PSCommandPath.Replace("'","''")+"' -Mode '"+$Mode+"' -Workspace '"+$Workspace.Replace("'","''")+"' -Accel '"+$Accel+"' -RamMb "+$RamMb+' -Cores '+$Cores+' -TimeoutMin '+$TimeoutMin+' -Elevated -NoPause'
  if($NewBuild){$command+=' -NewBuild'}
  $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
  $child=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) -Verb RunAs -PassThru
  try{$null=$child.Handle;$child.WaitForExit();if($null -eq $child.ExitCode){throw 'Missing elevated pipeline exit code.'};$code=$child.ExitCode}finally{$child.Dispose()}
 }else{
  $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach($entry in $manifest.files){
   if($entry.path -match '(^|/)\.\.?(/|$)|^[\\/]|:|\\' -or -not $seen.Add([string]$entry.path)){throw 'Unsafe/duplicate pipeline manifest path.'}
   $file=Join-Path $capsule $entry.path;$item=Get-Item -LiteralPath $file -Force
   if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -ne $entry.bytes -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ine $entry.sha256){throw ('Pipeline file differs: '+$entry.path)}
  }
  & (Join-Path $PSScriptRoot 'check-package.ps1') -NoPause
  if($LASTEXITCODE){throw 'Bundled source package failed verification.'}
  Write-Host ('Конвейер '+$manifest.version+': '+$seen.Count+' файлов проверены. Входы закреплены, режим сборки автономный.') -ForegroundColor Green
  if($Mode -eq 'Check'){$code=0}else{
   $parameters=@{Accel=$Accel;RamMb=$RamMb;Cores=$Cores;TimeoutMin=$TimeoutMin;NoPause=$true}
   if($Workspace){$parameters.Workspace=$Workspace};if($NewBuild){$parameters.NewBuild=$true}
   if($Plan){$parameters.Plan=$true};if($Status){$parameters.Status=$true}
   $entry=if($Mode -eq 'Image'){'build-image.ps1'}else{'build-all.ps1'}
   & (Join-Path $PSScriptRoot $entry) @parameters
   $code=$LASTEXITCODE
  }
 }
}catch{Write-Host ($_|Out-String) -ForegroundColor Red}
if(-not($NoPause -or $Plan -or $Status)){$null=Read-Host 'Enter — закрыть'}
exit $code
