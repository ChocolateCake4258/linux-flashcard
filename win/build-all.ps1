# One-button Debian/XFCE factory -> confirmed physical USB -> verified receipt.
param(
    [string]$Workspace='',
    [int]$DiskNumber=-1,
    [string]$ExpectedDevicePath='',
    [string]$ExpectedSerialNumber='',
    [long]$ExpectedSize=0,
    [switch]$Yes,
    [switch]$NewBuild,
    [switch]$Rewrite,
    [switch]$KeepIntermediates,
    [ValidateSet('Auto','WHPX','TCG')][string]$Accel='Auto',
    [int]$RamMb=0,
    [int]$Cores=0,
    [ValidateRange(10,720)][int]$TimeoutMin=240,
    [switch]$Plan,
    [switch]$Status,
    [switch]$NoPause,
    [switch]$Elevated
)
$ErrorActionPreference='Stop'
try{[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)}catch{}
. (Join-Path $PSScriptRoot 'lib\pf-storage.ps1')
$repo=Split-Path $PSScriptRoot -Parent
$storage=Get-PfStorageRoot $repo
Set-PfStorageEnvironment -Root (Join-Path $storage 'environment') -Create:(-not($Plan -or $Status))
Import-Module (Join-Path $PSScriptRoot 'lib\pf-tools.psm1') -Force -WarningAction SilentlyContinue
. (Join-Path $PSScriptRoot 'factory\usb.ps1')
$exitCode=1;$session=$null;$sessionPath=$null;$sessionLock=$null;$transcript=$false
try{
    $repo=Split-Path $PSScriptRoot -Parent
    $settings=Get-PfPreparationSettingsPath $repo
    $config=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'factory\inputs.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $minimum=[long]$config.linux_bytes+2GB
    if($Yes -and ($DiskNumber -lt 0 -or -not $ExpectedDevicePath -or $ExpectedSize -le 0)){
        throw '-Yes requires -DiskNumber, -ExpectedDevicePath and -ExpectedSize from an explicitly selected USB.'
    }
    if($Plan){
        Write-Host 'Debian 13/XFCE: выбор USB и подтверждение yes -> автоматический рабочий каталог -> сборка/возобновление -> запись -> полное чтение и проверка -> готовая флешка.'
        Write-Host 'Повторный запуск продолжает сохранённую сборку. -NewBuild создаёт новую; -Workspace задаёт каталог вручную.'
        Write-Host 'Система: один 26-GiB linux.img.vtoy на NTFS, Ventoy/UEFI и запускатели TCG/WHPX. Первый пароль задаётся внутри Linux.'
        $exitCode=0
    }elseif($Status){
        if(-not $Workspace){$Workspace=(Get-Content -LiteralPath $settings -Raw -Encoding UTF8|ConvertFrom-Json).Workspace}
        foreach($name in @('bootstrap\usb-preparation.json','factory-state.json')){
            $path=Join-Path $Workspace $name
            if(Test-Path -LiteralPath $path){Write-Host $path;Get-Content -LiteralPath $path -Raw -Encoding UTF8}
        }
        $exitCode=0
    }else{
        $disks=@(Get-PfPreparationDisks $minimum|Sort-Object Size,Number)
        if(-not $disks.Count){throw 'Нет подходящей USB-флешки (32 ГБ и больше, доступной на запись). Подключите её и повторите запуск.'}
        if($DiskNumber -ge 0){
            $selected=@($disks|Where-Object{$_.Number -eq $DiskNumber})
            if($selected.Count -ne 1){throw 'The requested disk is not an eligible USB target.'}
            $target=$selected[0]
        }else{
            Write-Host 'Выберите флешку для новой Linux-системы:' -ForegroundColor Cyan
            for($i=0;$i -lt $disks.Count;$i++){
                Write-Host ('  [{0}] Disk {1}: {2}; {3:N1} GB; serial {4}' -f $i,$disks[$i].Number,$disks[$i].Model,($disks[$i].Size/1e9),$disks[$i].SerialNumber)
            }
            $answer=Read-Host 'Номер в [скобках], Q — отмена'
            if($answer -match '^[Qq]$'){$exitCode=0;return}
            $index=0
            if(-not [int]::TryParse($answer,[ref]$index) -or $index -lt 0 -or $index -ge $disks.Count){throw 'Неверный номер флешки.'}
            $target=$disks[$index]
        }
        if(($ExpectedDevicePath -and $ExpectedDevicePath -ne $target.Path) -or
            ($ExpectedSerialNumber -and $ExpectedSerialNumber.Trim() -ne $target.SerialNumber) -or
            ($ExpectedSize -and $ExpectedSize -ne $target.Size)){throw 'USB target identity differs from the requested identity.'}
        $null=Assert-PfPreparationLocation $repo $target.Number
        $null=Assert-PfPreparationLocation $settings $target.Number
        $copies=if($KeepIntermediates){2}else{1}
        $required=[long]$config.linux_bytes+$copies*$target.Size+6GB
        $Workspace=Resolve-PfPreparationWorkspace -Requested $Workspace -Source $repo -Target $target -SettingsPath $settings -NewBuild:$NewBuild -RequiredBytes $required
        $sessionPath=Join-Path $Workspace 'bootstrap\usb-preparation.json'
        if(Test-Path -LiteralPath $sessionPath){
            $session=Get-Content -LiteralPath $sessionPath -Raw -Encoding UTF8|ConvertFrom-Json
            if($session.Schema -ne 1 -or $session.Workspace -ine $Workspace){throw 'USB preparation ownership mismatch.'}
            if(-not (Test-PfPreparationIdentity $session.Target $target) -and -not $Rewrite){throw 'This workspace is bound to another USB. Use a new build or explicitly select -Rewrite to clone its artifact.'}
            if($session.Stage -eq 'ready' -and -not $Rewrite){
                Write-Host ('Подготовка этого носителя уже завершена: {0}. Повторная запись: -Rewrite.' -f $session.Completed) -ForegroundColor Green
                $exitCode=0
                return
            }
        }
        Write-Host ('Флешка: Disk {0}, {1}, serial {2}, {3} байт' -f $target.Number,$target.Model,$target.SerialNumber,$target.Size) -ForegroundColor Cyan
        Write-Host ('Рабочий каталог: '+$Workspace)
        Write-Host 'ВСЕ ДАННЫЕ НА ВЫБРАННОЙ ФЛЕШКЕ БУДУТ СТЁРТЫ после завершения сборки.' -ForegroundColor Yellow
        if(-not $Yes -and (Read-Host 'Введите yes для сборки и записи') -cne 'yes'){$exitCode=0;return}
        $null=Find-PfPreparationTarget $target $minimum
        $settingsParent=Split-Path $settings -Parent
        $null=[IO.Directory]::CreateDirectory($settingsParent)
        Set-PfStorageEnvironment -Root (Join-Path $storage 'environment') -Create
        Write-PfPreparationJson $settings ([ordered]@{Schema=1;Workspace=$Workspace;MediaBytes=$target.Size})
        if(-not (Test-PfIsAdmin)){
            if($Elevated){throw 'USB preparation requires an administrator token.'}
            $command="& '"+$PSCommandPath.Replace("'","''")+"' -Elevated -NoPause -Yes -Workspace '"+$Workspace.Replace("'","''")+"' -DiskNumber "+$target.Number+" -ExpectedDevicePath '"+$target.Path.Replace("'","''")+"' -ExpectedSerialNumber '"+$target.SerialNumber.Replace("'","''")+"' -ExpectedSize "+$target.Size+" -Accel '"+$Accel+"' -RamMb "+$RamMb+' -Cores '+$Cores+' -TimeoutMin '+$TimeoutMin
            if($Rewrite){$command+=' -Rewrite'}
            if($KeepIntermediates){$command+=' -KeepIntermediates'}
            $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
            $shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $child=Start-Process -FilePath $shell -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) -Verb RunAs -PassThru
            try{$null=$child.Handle;$child.WaitForExit();if($null -eq $child.ExitCode){throw 'Missing elevated preparation exit code.'};$exitCode=$child.ExitCode}finally{$child.Dispose()}
            if($exitCode -eq 0){Write-Host ('Подготовка завершена. Отчёт: '+$sessionPath) -ForegroundColor Green}
            else{Write-Host ('Подготовка завершилась с ошибкой. Рабочий каталог и логи: '+$Workspace+'\bootstrap') -ForegroundColor Red}
        }else{
            $bootstrap=Join-Path $Workspace 'bootstrap';$null=[IO.Directory]::CreateDirectory($bootstrap)
            $sessionLock=[IO.File]::Open((Join-Path $bootstrap 'usb-preparation.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            if($session -and $Rewrite){
                Copy-Item -LiteralPath $sessionPath -Destination (Join-Path $bootstrap ('usb-preparation-before-'+[guid]::NewGuid().ToString('N')+'.json')) -ErrorAction Stop
            }
            $session=[pscustomobject][ordered]@{Schema=1;Workspace=$Workspace;Target=$target;Stage='building';Confirmed=(Get-Date).ToString('o');Completed=$null;Receipt=$null;Error=$null}
            Write-PfPreparationJson $sessionPath $session
            $log=Join-Path $bootstrap ('prepare-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)+'.log')
            Start-Transcript -LiteralPath $log -NoClobber|Out-Null;$transcript=$true
            $parameters=@{Workspace=$Workspace;Accel=$Accel;RamMb=$RamMb;Cores=$Cores;UsbBytes=$target.Size;TimeoutMin=$TimeoutMin;NoPause=$true}
            if($KeepIntermediates){$parameters.KeepIntermediates=$true}
            if(Test-Path -LiteralPath (Join-Path $Workspace 'factory-state.json')){$parameters.Resume=$true}
            Invoke-PfPreparationScript (Join-Path $PSScriptRoot 'build-debian.ps1') $parameters
            $artifact=Get-Content -LiteralPath (Join-Path $Workspace 'artifacts\build-result.json') -Raw -Encoding UTF8|ConvertFrom-Json
            $expectedImage=Join-Path $Workspace 'artifacts\linux-flashcard-usb.img'
            if(-not $artifact.complete -or $artifact.image -ine $expectedImage -or [long]$artifact.bytes -ne $target.Size -or $artifact.sha256 -notmatch '^[a-fA-F0-9]{64}$'){
                throw 'Factory did not publish a verified image for the selected USB capacity.'
            }
            $sidecar=(Get-Content -LiteralPath ($artifact.image+'.sha256') -Raw -Encoding UTF8).Trim()
            if($sidecar -ine $artifact.sha256 -or (Get-Item -LiteralPath $artifact.image).Length -ne $target.Size){throw 'Published artifact length or checksum sidecar changed.'}
            $target=Find-PfPreparationTarget $session.Target $minimum
            $null=Assert-PfPreparationLocation $artifact.image $target.Number
            $receiptPath=Join-Path $bootstrap ('usb-write-'+[guid]::NewGuid().ToString('N')+'.json')
            $session.Stage='writing';$session.Receipt=$receiptPath;Write-PfPreparationJson $sessionPath $session
            Invoke-PfPreparationScript (Join-Path $PSScriptRoot 'write-image.ps1') @{
                ImagePath=$artifact.image;DiskNumber=$target.Number;ExpectedDevicePath=$target.Path;ExpectedSerialNumber=$target.SerialNumber;ExpectedSize=$target.Size
                Yes=$true;VerifyFull=$true;DeferPartitionTable=$true;VerifyBeforePublish=$true;ResultPath=$receiptPath
            }
            $receipt=Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8|ConvertFrom-Json
            Assert-PfPreparationReceipt $receipt $artifact $target
            $session.Stage='ready';$session.Completed=(Get-Date).ToString('o');Write-PfPreparationJson $sessionPath $session
            Write-Host 'ГОТОВО: флешка записана и полностью проверена чтением.' -ForegroundColor Green
            Write-Host 'На флешке: run-linux.bat (TCG), run-linux-accelerated.bat (WHPX); нативная загрузка — через UEFI boot-меню.'
            Write-Host ('Результат: '+$receiptPath)
            $exitCode=0
        }
    }
}catch{
    if($sessionLock -and $session){$session.Stage='failed';$session.Error=($_|Out-String);try{Write-PfPreparationJson $sessionPath $session}catch{}}
    Write-Host ($_|Out-String) -ForegroundColor Red
    Write-Host 'Повторите build-all.bat: сохранённая сборка продолжится, незавершённая запись начнётся заново.' -ForegroundColor Yellow
    $exitCode=1
}finally{
    if($transcript){try{Stop-Transcript|Out-Null}catch{}}
    if($sessionLock){$sessionLock.Dispose()}
    if(-not ($NoPause -or $Plan -or $Status)){$null=Read-Host 'Enter — закрыть'}
}
exit $exitCode
