# Backup/verify/restore the stopped portable Linux file kit, without UAC.
param(
    [ValidateSet('Backup','Verify','Restore')][string]$Action='Backup',
    [string]$Root=$PSScriptRoot,
    [string]$Archive='',
    [string]$Destination='',
    [switch]$NoPause
)
$ErrorActionPreference='Stop';$code=1
try{[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)}catch{}
try{
    . (Join-Path $PSScriptRoot 'lib\pf-storage.ps1')
    . (Join-Path $PSScriptRoot 'lib\portable-backup.ps1')
    if(-not $Archive){$Archive=Read-Host 'Путь ZIP-копии на другом диске компьютера'}
    if(-not $Archive){throw 'Укажите путь ZIP-копии.'}
    $storage=if($env:PF_STORAGE_ROOT){$env:PF_STORAGE_ROOT}else{Split-Path ([IO.Path]::GetFullPath($Archive)) -Parent}
    Set-PfStorageEnvironment -Root (Join-Path $storage 'backup-environment') -Create
    if($Action -eq 'Backup'){
        if(-not(Test-Path -LiteralPath (Join-Path $Root 'linux.img.vtoy'))){$Root=Read-Host 'Каталог Linux-комплекта, например V:\'}
        Write-Host 'Linux должен быть штатно выключен. Образ и VARS блокируются на время копирования.'
        $result=New-PfPortableBackup $Root $Archive
        Write-Host 'ГОТОВО: резервная копия создана и полностью проверена.' -ForegroundColor Green
    }elseif($Action -eq 'Verify'){
        $manifest=Test-PfPortableBackup $Archive
        $result=[pscustomobject]@{Complete=$true;Archive=$Archive;Files=@($manifest.Files).Count}
        Write-Host 'ГОТОВО: все файлы резервной копии совпадают с SHA256.' -ForegroundColor Green
    }else{
        if(-not $Destination){$Destination=Read-Host 'Новый каталог для восстановленного комплекта'}
        if(-not $Destination){throw 'Укажите новый каталог восстановления.'}
        $result=Restore-PfPortableBackup $Archive $Destination
        Write-Host 'ГОТОВО: комплект восстановлен в новый каталог и проверен.' -ForegroundColor Green
    }
    $result|ConvertTo-Json -Depth 4;$code=0
}catch{Write-Host ($_|Out-String) -ForegroundColor Red}
if(-not $NoPause){$null=Read-Host 'Enter — закрыть'}
exit $code
