# Offline verification of the exact downloaded public package.
param([switch]$NoPause)
$ErrorActionPreference='Stop';$code=1
try{
 $root=Split-Path $PSScriptRoot -Parent
 . (Join-Path $PSScriptRoot 'lib\pf-storage.ps1')
 Set-PfStorageEnvironment -Root (Join-Path (Get-PfStorageRoot $root) 'check-environment') -Create
 $manifest=Get-Content -LiteralPath (Join-Path $root 'RELEASE-MANIFEST.json') -Raw -Encoding UTF8|ConvertFrom-Json
 if($manifest.schema -ne 1 -or $manifest.format -ne 'LinuxFlashcardSourceRelease'){throw 'Unsupported package manifest.'}
 foreach($entry in $manifest.files){
  if($entry.path -match '(^|/)\.\.(/|$)|^[\\/]|:|\\'){throw 'Unsafe package manifest path.'}
  $file=Join-Path $root $entry.path
  if((Get-Item -LiteralPath $file -Force).Length -ne $entry.bytes -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ine $entry.sha256){throw ('Package file differs: '+$entry.path)}
  if([IO.Path]::GetExtension($file) -in '.ps1','.psm1'){
   $tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$errors)
   if($errors.Count){throw ('PowerShell syntax error: '+$entry.path)}
  }
 }
 Write-Host ('Пакет '+$manifest.version+': '+@($manifest.files).Count+' файлов, SHA256 и PowerShell проверены.') -ForegroundColor Green
 $code=0
}catch{Write-Host ($_|Out-String) -ForegroundColor Red}
if(-not $NoPause){$null=Read-Host 'Enter — закрыть'}
exit $code
