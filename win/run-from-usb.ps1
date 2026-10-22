# Файловый запуск: записываемый самостоятельный QCOW2/RAW, TCG или WHPX, UEFI.
# По умолчанию TCG без администратора; WHPX выбирается явно, без fallback.
# Образ и UEFI VARS сохраняются между запусками; временный snapshot запрещён.
param(
    [string]$DiskPath = '',
    [string]$QemuExe = '',
    [ValidateSet('qcow2','raw')][string]$DiskFormat = 'qcow2',
    [ValidateSet('utc','localtime')][string]$RtcBase = 'utc',
    [ValidateSet('TCG','WHPX')][string]$Accel = 'TCG',
    $RamMb = 4096,
    $Cores = 2,
    [switch]$Snapshot,
    [switch]$NoPause,
    [string]$LogRoot = ''
)

try { [Console]::OutputEncoding = [Text.Encoding]::UTF8; $OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$ErrorActionPreference = 'Stop'
$exitCode = 1
$stage = 'initialize'
$failure = $null
$logDirectory = $null
$transcriptOn = $false
$imageLock = $null
$qemuProcess = $null
$qemuExitCode = $null
$qemu = $null
$qmpPort = $null
$varsPath = $null
$started = (Get-Date).ToString('o')
$elevated = $null
$whpxStatus = $null
$qemuAliasPaths = [Collections.Generic.List[string]]::new()

function Assert-WritableFile {
    param([string]$Path)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $stream.Dispose()
}

function Start-LoggedProcess {
    param([string]$Exe, [string[]]$NativeArguments, [string]$Stdout, [string]$Stderr, [string]$WorkingDirectory='')
    # PS 5.1 Start-Process трактует [] в путях журналов как wildcard.
    # .NET открывает буквальные пути и непрерывно копирует оба потока без блокировки.
    $output = [IO.File]::Open($Stdout, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    $errorOutput = $null
    $process = [Diagnostics.Process]::new()
    try {
        $errorOutput = [IO.File]::Open($Stderr, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $process.StartInfo.FileName = $Exe
        $process.StartInfo.Arguments = Join-PfArguments $NativeArguments
        $process.StartInfo.WorkingDirectory = if($WorkingDirectory){$WorkingDirectory}else{Split-Path $Exe -Parent}
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.CreateNoWindow = $true
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.RedirectStandardError = $true
        if (-not $process.Start()) { throw "Не удалось запустить $Exe" }
        return [pscustomobject]@{
            Process = $process; Output = $output; ErrorOutput = $errorOutput
            OutputCopy = $process.StandardOutput.BaseStream.CopyToAsync($output)
            ErrorCopy = $process.StandardError.BaseStream.CopyToAsync($errorOutput)
        }
    } catch {
        $output.Dispose()
        if ($errorOutput) { $errorOutput.Dispose() }
        $process.Dispose()
        throw
    }
}

function ConvertTo-QemuFilePath {
    param([string]$Path,[string]$WorkingDirectory)
    # Some Windows QEMU file backends still open ANSI paths. A relative ASCII
    # path works even when the process's native Unicode working directory is not ASCII.
    if($Path -notmatch '[^\x00-\x7f]'){return $Path}
    $base=[Uri]::new($WorkingDirectory.TrimEnd('\')+'\')
    $relative=$base.MakeRelativeUri([Uri]::new($Path))
    if(-not $relative.IsAbsoluteUri){
        $value=[Uri]::UnescapeDataString($relative.ToString()).Replace('/','\')
        if(-not $value){$value='.'}
        if($value -notmatch '[^\x00-\x7f]'){return $value}
    }
    if(-not ('PfQemuShortPath' -as [type])){
        Add-Type -TypeDefinition @'
using System.Text;
using System.Runtime.InteropServices;
public static class PfQemuShortPath {
 [DllImport("kernel32.dll", CharSet=CharSet.Unicode, ExactSpelling=true, SetLastError=true)]
 public static extern uint GetShortPathNameW(string path, StringBuilder output, uint length);
 [DllImport("kernel32.dll", CharSet=CharSet.Unicode, ExactSpelling=true, SetLastError=true)]
 public static extern bool CreateHardLinkW(string alias, string existing, System.IntPtr security);
}
'@
    }
    $buffer=[Text.StringBuilder]::new(32768)
    $length=[PfQemuShortPath]::GetShortPathNameW($Path,$buffer,32768)
    if($length -gt 0 -and $length -lt 32768 -and $buffer.ToString() -notmatch '[^\x00-\x7f]'){return $buffer.ToString()}
    if([IO.File]::Exists($Path) -and [IO.Path]::GetPathRoot($Path) -ieq [IO.Path]::GetPathRoot($WorkingDirectory)){
        $name='.pf-qemu-'+[guid]::NewGuid().ToString('N')+'.file'
        $alias=Join-Path $WorkingDirectory $name
        if([PfQemuShortPath]::CreateHardLinkW($alias,$Path,[IntPtr]::Zero)){
            $script:qemuAliasPaths.Add($alias)
            return $name
        }
    }
    throw 'QEMU cannot open this non-ASCII filename. Keep linux.img.vtoy and its QEMU directory together, or use an ASCII filename.'
}

function Wait-LoggedProcess {
    param($Child)
    $Child.Process.WaitForExit()
    try {
        $null = $Child.OutputCopy.GetAwaiter().GetResult()
        $null = $Child.ErrorCopy.GetAwaiter().GetResult()
    } finally { $Child.Output.Dispose(); $Child.ErrorOutput.Dispose() }
}

try {
    # Журнал начинается до импорта модуля и всех проверок образа.
    if (-not $LogRoot) { $LogRoot = Join-Path $PSScriptRoot 'logs' }
    $null = [IO.Directory]::CreateDirectory($LogRoot)
    $logDirectory = Join-Path $LogRoot ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $logDirectory -ErrorAction Stop
    Start-Transcript -LiteralPath (Join-Path $logDirectory 'launcher.log') -NoClobber -ErrorAction Stop | Out-Null
    $transcriptOn = $true
    Write-Host "Журналы: $logDirectory"
    Write-Host "Начало: $started"
    if ($args.Count) { throw "Неизвестные аргументы: $($args -join ' ')" }
    if ($Snapshot) { throw 'Этот запускатель сохраняет данные. Временный -Snapshot не поддерживается.' }

    $stage = 'import-module'
    . (Join-Path $PSScriptRoot 'lib\pf-storage.ps1')
    Set-PfStorageEnvironment -Root (Join-Path $logDirectory 'environment') -Create
    Import-Module (Join-Path $PSScriptRoot 'lib\pf-tools.psm1') -Force -ErrorAction Stop -WarningAction SilentlyContinue
    $elevated = Test-PfIsAdmin
    Write-Host "Повышенные права текущего процесса: $elevated (повышение не запрашивается)."

    $stage = 'resolve-image'
    if (-not $DiskPath) {
        foreach ($candidate in @((Join-Path $PSScriptRoot 'virtual-disk.qcow2'), (Join-Path (Split-Path $PSScriptRoot -Parent) 'virtual-disk.qcow2'))) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $DiskPath = $candidate; break }
        }
    }
    if (-not $DiskPath) { throw 'Образ не найден. Укажите -DiskPath или положите virtual-disk.qcow2 рядом с запускателем.' }
    $image = Get-Item -LiteralPath $DiskPath -ErrorAction Stop
    $extensions = if ($DiskFormat -eq 'qcow2') { @('.qcow2') } else { @('.raw','.img','.vtoy') }
    if ($image.PSIsContainer -or $image.PSProvider.Name -ne 'FileSystem' -or $image.FullName -notmatch '^[A-Za-z]:\\' -or $image.Extension -notin $extensions) {
        throw "Нужен обычный локальный файл $DiskFormat, доступный пользователю для записи."
    }
    $DiskPath = $image.FullName
    # Блокируется только наш файловый запуск, не физический диск и не том Windows.
    $imageLock = [IO.File]::Open(($DiskPath + '.launch.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    Assert-WritableFile -Path $DiskPath

    $stage = 'resolve-qemu-and-uefi'
    if ($QemuExe -and -not (Test-Path -LiteralPath $QemuExe)) { throw "Указанный QEMU не найден: $QemuExe" }
    # Явный и соседний QEMU ищем буквально: [] допустимы в именах Windows.
    $qemuRoots = if ($QemuExe) { @($QemuExe) } else { @((Join-Path $PSScriptRoot 'qemu'), (Join-Path (Split-Path $PSScriptRoot -Parent) 'qemu')) }
    foreach ($root in $qemuRoots) {
        if (Test-Path -LiteralPath $root -PathType Leaf) { $qemu = $root; break }
        foreach ($name in @('qemu-system-x86_64.exe','qemu-system-x86_64w.exe')) {
            $candidate = Join-Path $root $name
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $qemu = $candidate; break }
        }
        if ($qemu) { break }
    }
    if (-not $qemu -and -not $QemuExe) { $qemu = Find-PfQemu -ScriptDir $PSScriptRoot }
    if (-not $qemu) { throw 'QEMU не найден. Положите папку qemu рядом с запускателем или укажите -QemuExe.' }
    $qemu = (Get-Item -LiteralPath $qemu -ErrorAction Stop).FullName
    $firmware = $null
    foreach ($relative in @('share\edk2-x86_64-code.fd','share\qemu\edk2-x86_64-code.fd')) {
        $candidate = Join-Path (Split-Path $qemu -Parent) $relative
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $firmware = $candidate; break }
    }
    if (-not $firmware -or -not (Test-Path -LiteralPath $firmware -PathType Leaf)) { throw 'UEFI прошивка выбранного QEMU не найдена. Переход на BIOS запрещён.' }
    $firmwareDirectory = Split-Path $firmware -Parent
    $varsTemplate = $null
    foreach ($name in @('edk2-x86_64-vars.fd','edk2-i386-vars.fd')) {
        $candidate = Join-Path (Split-Path $firmware -Parent) $name
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $varsTemplate = $candidate; break }
    }
    if (-not $varsTemplate) { throw 'Не найден шаблон UEFI VARS рядом с выбранной прошивкой.' }

    if ($Accel -eq 'WHPX') {
        $stage = 'prepare-acceleration'
        . (Join-Path $PSScriptRoot 'lib\pf-whpx.ps1')
        $whpxStatus = Get-PfWhpxStatus
        [IO.File]::WriteAllText((Join-Path $logDirectory 'whpx-status.json'), ($whpxStatus | ConvertTo-Json), [Text.Encoding]::UTF8)
        Assert-PfWhpxAvailable -Status $whpxStatus
        $probe = Start-LoggedProcess -Exe $qemu -NativeArguments @('-accel','help') `
            -Stdout (Join-Path $logDirectory 'qemu-accelerators.log') -Stderr (Join-Path $logDirectory 'qemu-accelerators-stderr.log')
        try {
            Wait-LoggedProcess $probe
            if ($probe.Process.ExitCode -ne 0 -or [IO.File]::ReadAllText((Join-Path $logDirectory 'qemu-accelerators.log')) -notmatch '(?im)^\s*whpx\s*$') {
                throw 'Выбранный QEMU не поддерживает WHPX. Нужна Windows-сборка QEMU с этим ускорителем.'
            }
        } finally { $probe.Process.Dispose() }
        Write-Host 'WHPX API доступен; выбран явный аппаратный режим без программного fallback.'
    }

    $stage = 'validate-image'
    $qemuImg = Join-Path (Split-Path $qemu -Parent) 'qemu-img.exe'
    if (-not (Test-Path -LiteralPath $qemuImg -PathType Leaf)) { throw 'qemu-img.exe не найден рядом с выбранным QEMU.' }
    $infoArguments = ConvertTo-PfArgumentList -Arguments @('info','--output=json',$DiskPath)
    $infoProcess = Start-LoggedProcess -Exe $qemuImg -NativeArguments $infoArguments `
        -Stdout (Join-Path $logDirectory 'image-info.json') -Stderr (Join-Path $logDirectory 'image-info-stderr.log')
    try {
        Wait-LoggedProcess $infoProcess
        if ($infoProcess.Process.ExitCode -ne 0) { throw "qemu-img не смог прочитать образ: $([IO.File]::ReadAllText((Join-Path $logDirectory 'image-info-stderr.log')))" }
    } finally { $infoProcess.Process.Dispose() }
    $info = [IO.File]::ReadAllText((Join-Path $logDirectory 'image-info.json')) | ConvertFrom-Json
    if ($info.format -ne $DiskFormat -or $info.'backing-filename') { throw "Нужен самостоятельный образ $DiskFormat без внешнего backing-файла." }
    if ($DiskFormat -eq 'qcow2' -and ($info.'dirty-flag' -or $info.'format-specific'.data.corrupt)) { throw 'QCOW2 отмечен как некорректно закрытый или повреждённый. Автоматический ремонт не выполняется.' }

    $stage = 'prepare-profile'
    if ($Accel -eq 'WHPX') {
        if (-not $PSBoundParameters.ContainsKey('RamMb')) { $RamMb = 0 }
        if (-not $PSBoundParameters.ContainsKey('Cores')) { $Cores = 0 }
    }
    $RamMb = [int]$RamMb
    $Cores = [int]$Cores
    $hostInfo = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    $freeMb = [Math]::Floor((Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).FreePhysicalMemory / 1024)
    $totalMb = [Math]::Floor($hostInfo.TotalPhysicalMemory / 1MB)
    $logical = [int]$hostInfo.NumberOfLogicalProcessors
    if ($logical -lt 1) { throw 'Не удалось определить число CPU компьютера.' }
    if ($RamMb -eq 0) {
        $limit = if ($Accel -eq 'WHPX') { [Math]::Min(6144, [Math]::Floor($totalMb / 2 / 1024) * 1024) } else { 4096 }
        $RamMb = [int][Math]::Min($limit, [Math]::Floor(($freeMb - 2048) / 1024) * 1024)
    }
    if ($Cores -eq 0) {
        $Cores = if ($Accel -eq 'WHPX') { [Math]::Min(4, [Math]::Max(1, [Math]::Floor($logical / 2))) } else { [Math]::Min(2, $logical) }
    }
    if ($Cores -lt 1 -or $Cores -gt $logical) { throw "Число CPU должно быть от 1 до $logical (0 = авто)." }
    if ($RamMb -lt 2048 -or $RamMb -gt ($totalMb - 2048) -or $freeMb -lt ($RamMb + 2048)) {
        throw "Недостаточно памяти: Linux нужно $RamMb МБ и ещё 2048 МБ для Windows; сейчас свободно $freeMb МБ. Закройте лишние приложения и повторите запуск."
    }

    $stage = 'prepare-persistent-uefi'
    $varsPath = $DiskPath + '.uefi-vars.fd'
    if (-not (Test-Path -LiteralPath $varsPath)) { [IO.File]::Copy($varsTemplate, $varsPath, $false) }
    if ((Get-Item -LiteralPath $varsPath).Length -ne (Get-Item -LiteralPath $varsTemplate).Length) { throw "Размер существующего UEFI VARS не подходит: $varsPath. Файл не заменён." }
    Assert-WritableFile -Path $varsPath

    $qemuWorkingDirectory=$image.DirectoryName
    $serialPath=Join-Path $logDirectory 'guest-serial.log'
    $serialFile=[IO.File]::Open($serialPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    $serialFile.Dispose()
    $qemuPaths=[ordered]@{}
    foreach($entry in @(@('Disk',$DiskPath),@('Vars',$varsPath),@('Code',$firmware),@('FirmwareDirectory',$firmwareDirectory),@('Serial',$serialPath))){
        $qemuPaths[$entry[0]]=ConvertTo-QemuFilePath $entry[1] $qemuWorkingDirectory
    }

    $qemuArgs = Get-PfQemuBaseArgs -RamMb $RamMb -Cores $Cores -QemuExe $qemu -ScriptDir $PSScriptRoot
    # Один явный ускоритель и фиксированный 2D экран: вместо динамического VirtIO EDID,
    # который GTK на домашнем ПК передавал как произвольный режим 165 Гц.
    $selectedAccel = if ($Accel -eq 'WHPX') { 'whpx,kernel-irqchip=off' } else { 'tcg,thread=multi' }
    $qemuArgs = @('-accel',$selectedAccel) + @(for ($i = 0; $i -lt $qemuArgs.Count; $i++) {
        if ($qemuArgs[$i] -in @('-accel','-vga')) { $i++ }
        elseif($qemuArgs[$i] -eq '-device' -and $i+1 -lt $qemuArgs.Count -and $qemuArgs[$i+1] -like 'virtio-net-pci,netdev=pfnet*'){
            '-device';'virtio-net-pci,netdev=pfnet,addr=0x3';$i++
        }else { $qemuArgs[$i] }
    })
    $qemuArgs += @('-L',$qemuPaths.FirmwareDirectory,'-rtc',("base="+$RtcBase),'-vga','none','-device','VGA,id=pfgfx,edid=on,xres=1024,yres=768,refresh_rate=60')
    # Передаём проверенный pflash сами: общая функция допускает BIOS fallback.
    $qemuArgs += @('-drive',"if=pflash,format=raw,readonly=on,file=$($qemuPaths.Code.Replace(',', ',,'))",
        '-drive',"if=pflash,format=raw,file=$($qemuPaths.Vars.Replace(',', ',,'))",
        '-drive',"if=none,id=pfroot,file=$($qemuPaths.Disk.Replace(',', ',,')),format=$DiskFormat",
        '-device','virtio-blk-pci,drive=pfroot,addr=0x4,bootindex=1',
        '-boot','order=c','-display','gtk,gl=off',
        '-chardev',"file,id=pfser,path=$($qemuPaths.Serial.Replace(',', ',,')),append=on",'-serial','chardev:pfser')
    # Loopback QMP нужен для фиксации состояния/экрана и штатного выключения.
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    try { $listener.Start(); $qmpPort = $listener.LocalEndpoint.Port } finally { $listener.Stop() }
    $qemuArgs += @('-qmp',"tcp:127.0.0.1:$qmpPort,server=on,wait=off")
    $nativeArguments = ConvertTo-PfArgumentList -Arguments $qemuArgs -What 'файлового QEMU'
    [IO.File]::WriteAllText((Join-Path $logDirectory 'qemu-command.txt'), ('"' + $qemu + '" ' + (Join-PfArguments $nativeArguments)), [Text.Encoding]::UTF8)
    $profile = [ordered]@{ Started = $started; DiskPath = $DiskPath; ImageFormat = $DiskFormat; RtcBase = $RtcBase; Qemu = $qemu; UefiCode = $firmware; UefiVars = $varsPath; Accel = $Accel; CpuModel = 'Westmere'; WhpxStatus = $whpxStatus; RamMb = $RamMb; Cores = $Cores; Video = 'VGA 1024x768 60Hz'; Elevated = $elevated; Snapshot = $false; QmpPort = $qmpPort }
    $profile.QemuWorkingDirectory=$qemuWorkingDirectory;$profile.QemuFilePaths=$qemuPaths
    $profile.StorageDevice='virtio-blk-pci,drive=pfroot,addr=0x4,bootindex=1';$profile.NetworkPciAddress='0x3'
    [IO.File]::WriteAllText((Join-Path $logDirectory 'launch-profile.json'), ($profile | ConvertTo-Json), [Text.Encoding]::UTF8)
    Write-PfHeader "Linux из файла: постоянная запись, $Accel, UEFI"
    Write-Host "Образ: $DiskPath"
    Write-Host "QEMU: $qemu"
    Write-Host "RAM: $RamMb МБ; CPU: $Cores; ускоритель: $Accel; UEFI VARS: $varsPath"
    Write-Host 'Видео: стандартный 2D VGA, предпочтительный режим 1024x768 / 60 Гц.'
    Write-Host "Завершайте Linux через «Выключить» внутри рабочего стола. Изменения записываются в этот $DiskFormat."

    $stage = 'start-qemu'
    $qemuProcess = Start-LoggedProcess -Exe $qemu -NativeArguments $nativeArguments `
        -Stdout (Join-Path $logDirectory 'qemu-stdout.log') -Stderr (Join-Path $logDirectory 'qemu-stderr.log') -WorkingDirectory $qemuWorkingDirectory
    Write-Host "QEMU PID: $($qemuProcess.Process.Id)"
    Wait-LoggedProcess $qemuProcess
    $qemuExitCode = $qemuProcess.Process.ExitCode
    if ($qemuExitCode -ne 0) {
        $exitCode = $qemuExitCode
        throw "QEMU завершился с кодом $qemuExitCode.`n$([IO.File]::ReadAllText((Join-Path $logDirectory 'qemu-stderr.log')))"
    }
    $bootText=[IO.File]::ReadAllText($serialPath)
    if($bootText -match 'UEFI Interactive Shell|Shell>' -and $bootText -notmatch 'Linux version|systemd\['){
        $stage='uefi-boot'
        throw 'VM entered UEFI Shell before Linux boot. Check the boot device path/EFI loader; the image and persistent VARS were not reset.'
    }
    $stage = 'qemu-exited'
    $exitCode = 0
    Write-Host 'QEMU завершён без ошибки. Использовалась постоянная запись в образ.' -ForegroundColor Green
    Write-Host 'Сохранение конкретного файла проверяется внутри Linux после повторного запуска.'
} catch {
    $failure = ($_ | Out-String)
    Write-Host '[ОШИБКА ЗАПУСКА]' -ForegroundColor Red
    Write-Host $failure -ForegroundColor Red
    Write-Host "Этап: $stage; журналы: $logDirectory" -ForegroundColor Yellow
} finally {
    # Не освобождаем наш запускательный lock, пока дочерний QEMU жив.
    if ($qemuProcess) { Wait-LoggedProcess $qemuProcess; $qemuProcess.Process.Dispose() }
    if ($imageLock) { $imageLock.Dispose() }
    foreach($alias in $qemuAliasPaths){try{[IO.File]::Delete($alias)}catch{Write-Host ('Не удалось удалить временный путь QEMU: '+$alias) -ForegroundColor Yellow}}
    if ($logDirectory) {
        try {
            $result = [ordered]@{ ExitCode = $exitCode; QemuExitCode = $qemuExitCode; Stage = $stage; Error = $failure; DiskPath = $DiskPath; Elevated = $elevated; LogDirectory = $logDirectory; Started = $started; Finished = (Get-Date).ToString('o') }
            [IO.File]::WriteAllText((Join-Path $logDirectory 'launcher-result.json'), ($result | ConvertTo-Json), [Text.Encoding]::UTF8)
        } catch { Write-Host "Не удалось сохранить результат: $_" -ForegroundColor Red }
    }
    if ($transcriptOn) { try { Stop-Transcript | Out-Null } catch { } }
}
if ($exitCode -ne 0 -and -not $NoPause -and $env:PF_FILE_FROM_BAT -ne '1') { $null = Read-Host 'Ошибка сохранена в журнал. Enter — закрыть' }
exit $exitCode
