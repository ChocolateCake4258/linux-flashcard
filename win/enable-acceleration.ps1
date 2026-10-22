# Explicit, one-time Windows WHPX setup. No Linux image is opened by this script.
param([switch]$Elevated, [switch]$NoPause)
$ErrorActionPreference='Stop'
try{[Console]::OutputEncoding=[Text.Encoding]::UTF8}catch{}
$exitCode=1;$transcript=$false;$result=$null
$base=if($env:PF_STORAGE_ROOT){$env:PF_STORAGE_ROOT}else{$PSScriptRoot}
$logs=Join-Path $base ('logs\acceleration-setup\'+[guid]::NewGuid().ToString('N'))
try{
    $null=[IO.Directory]::CreateDirectory($logs)
    Start-Transcript -LiteralPath (Join-Path $logs 'setup.log') -NoClobber|Out-Null
    $transcript=$true
    . (Join-Path $PSScriptRoot 'lib\pf-storage.ps1')
    Set-PfStorageEnvironment -Root (Join-Path $logs 'environment') -Create
    . (Join-Path $PSScriptRoot 'lib\pf-whpx.ps1')
    $before=Get-PfWhpxStatus
    if($before.Available){
        Write-Host 'WHPX уже доступен. Можно запускать run-linux-accelerated.bat; настройка Windows не требуется.'
        $exitCode=0
        $result=[ordered]@{Available=$true;WindowsChanged=$false;RestartRequired=$false}
    }else{
        $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
        try{$admin=([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)}finally{$identity.Dispose()}
        if(-not $admin){
            if($Elevated){throw 'Настройка WHPX требует администратора Windows.'}
            Write-Host 'Для включения Windows Hypervisor Platform будет запрошен UAC.'
            $command="& '"+$PSCommandPath.Replace("'","''")+"' -Elevated -NoPause"
            $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
            $child=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
                -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) -Verb RunAs -Wait -PassThru
            try{
                if($null -eq $child.ExitCode){throw 'Не удалось получить код завершения настройки с UAC.'}
                $exitCode=$child.ExitCode
            }finally{$child.Dispose()}
            $result=[ordered]@{ElevatedChild=$true;ExitCode=$exitCode;RestartRequired=($exitCode -eq 3010)}
        }else{
            $feature=Get-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform
            $restart=$false
            if([string]$feature.State -ne 'Enabled'){
                Write-Host 'Включение компонента Windows Hypervisor Platform...'
                $enabled=Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -All -NoRestart
                $restart=[bool]$enabled.RestartNeeded
            }
            & (Join-Path $env:SystemRoot 'System32\bcdedit.exe') /set '{current}' hypervisorlaunchtype auto
            if($LASTEXITCODE -ne 0){throw 'Не удалось включить запуск гипервизора Windows в BCD.'}
            $after=Get-PfWhpxStatus
            $restart=$restart -or -not $after.Available
            $exitCode=if($restart){3010}else{0}
            $result=[ordered]@{Available=$after.Available;WindowsChanged=$true;RestartRequired=[bool]$restart;Status=$after}
            if($restart){
                Write-Host 'Сохраните работу и перезагрузите Windows самостоятельно, затем запустите run-linux-accelerated.bat.'
                Write-Host 'Виртуализация AMD-V/SVM или Intel VT-x должна быть включена в UEFI/BIOS.'
            }else{Write-Host 'WHPX доступен. Запускайте run-linux-accelerated.bat.'}
        }
    }
}catch{
    Write-Host ('Ошибка настройки WHPX: '+($_|Out-String)) -ForegroundColor Red
    $result=[ordered]@{Error=($_|Out-String);ExitCode=1};$exitCode=1
}finally{
    if(Test-Path -LiteralPath $logs){[IO.File]::WriteAllText((Join-Path $logs 'result.json'),($result|ConvertTo-Json -Depth 4),[Text.Encoding]::UTF8)}
    if($transcript){Stop-Transcript|Out-Null}
    Write-Host "Журналы настройки: $logs"
}
if(-not $NoPause){$null=Read-Host 'Enter — закрыть'}
exit $exitCode
