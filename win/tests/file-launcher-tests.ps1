# Native Windows failure-path tests. This does not test a Linux desktop.
param([string]$LauncherDirectory = '')
$ErrorActionPreference = 'Stop'
if (-not $LauncherDirectory) { $LauncherDirectory = Split-Path $PSScriptRoot -Parent }
Import-Module (Join-Path $LauncherDirectory 'lib\pf-tools.psm1') -Force
function Assert-Test($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$fixture = Join-Path $env:TEMP ('pf-file ' + [guid]::NewGuid().ToString('N').Substring(0,12) + ", it's [1]")
$null = New-Item -ItemType Directory -Path $fixture
$capture = Join-Path $env:TEMP ('pf-file-capture-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $capture
$shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
try {
    foreach ($name in @('run-from-usb.ps1','run-from-usb.bat')) { Copy-Item -LiteralPath (Join-Path $LauncherDirectory $name) -Destination (Join-Path $fixture $name) }
    Copy-Item -LiteralPath (Join-Path $LauncherDirectory 'full-suite\run-linux-accelerated.bat') -Destination (Join-Path $fixture 'run-linux-accelerated.bat')
    $tokens = $null; $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile((Join-Path $fixture 'run-from-usb.ps1'), [ref]$tokens, [ref]$errors)
    Assert-Test ($errors.Count -eq 0) 'Launcher parse failed.'
    $bytes = [IO.File]::ReadAllBytes((Join-Path $fixture 'run-from-usb.ps1'))
    Assert-Test ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191 -and -not ($bytes -contains 13)) 'PowerShell must retain UTF-8 BOM / LF.'
    $bytes = [IO.File]::ReadAllBytes((Join-Path $fixture 'run-from-usb.bat'))
    Assert-Test (@($bytes | Where-Object { $_ -gt 127 }).Count -eq 0 -and [Text.Encoding]::ASCII.GetString($bytes) -notmatch '(?<!\r)\n|\r(?!\n)') 'BAT must retain ASCII / CRLF.'

    # A native argv stub allocates no guest RAM. Keep host resource inputs
    # deterministic in this private copy, including an explicit low-memory case.
    $launcher=Join-Path $fixture 'run-from-usb.ps1'
    $text=[IO.File]::ReadAllText($launcher)
    $ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
    $resources=@'

function Get-CimInstance {
    param([string]$ClassName)
    switch($ClassName){
        'Win32_ComputerSystem' { [pscustomobject]@{TotalPhysicalMemory=16GB;NumberOfLogicalProcessors=8} }
        'Win32_OperatingSystem' {
            $free=if([IO.File]::Exists((Join-Path $PSScriptRoot 'low-memory.flag'))){512MB}else{8GB}
            [pscustomobject]@{FreePhysicalMemory=($free/1KB)}
        }
        default { throw ('Unexpected fixture CIM query: '+$ClassName) }
    }
}

'@
    [IO.File]::WriteAllText($launcher,$text.Insert($ast.ParamBlock.Extent.EndOffset,$resources),[Text.Encoding]::UTF8)

    $script:caseIndex=0
    function Invoke-FailureCase([string]$Name, [string[]]$Arguments, [int]$ExpectedExit, [string]$ExpectedStage, [switch]$Batch, [switch]$Accelerated) {
        # CodeDom/Add-Type also uses the nested launcher TEMP. Keep private
        # fixture paths below Win32 MAX_PATH while retaining special characters.
        $script:caseIndex++
        $logs = Join-Path $fixture ('case-'+$script:caseIndex)
        $arguments = @('-NoPause','-LogRoot',$logs) + $Arguments
        $stdout = Join-Path $capture ($Name + '-stdout.log')
        $stderr = Join-Path $capture ($Name + '-stderr.log')
        if ($Batch) {
            $batchName = if ($Accelerated) { 'run-linux-accelerated.bat' } else { 'run-from-usb.bat' }
            $command = (ConvertTo-PfArgumentList -Arguments (@((Join-Path $fixture $batchName)) + $arguments)) -join ' '
            $process = Start-Process -FilePath $env:ComSpec -ArgumentList ('/d /s /c "' + $command + '"') -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        } else {
            $native = ConvertTo-PfArgumentList -Arguments (@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $fixture 'run-from-usb.ps1')) + $arguments)
            $process = Start-Process -FilePath $shell -ArgumentList $native -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        }
        try {
            $null = $process.Handle
            if (-not $process.WaitForExit(60000)) { throw "Failure test timed out: $Name (PID $($process.Id))." }
            $process.WaitForExit()
            Assert-Test ($process.ExitCode -eq $ExpectedExit) "Wrong exit for $Name : $($process.ExitCode); $([IO.File]::ReadAllText($stdout)); $([IO.File]::ReadAllText($stderr))"
        } finally { $process.Dispose() }
        $directories = @(Get-ChildItem -LiteralPath $logs -Directory)
        Assert-Test ($directories.Count -eq 1) "Missing unique log directory: $Name"
        $result = [IO.File]::ReadAllText((Join-Path $directories[0].FullName 'launcher-result.json')) | ConvertFrom-Json
        Assert-Test ($result.ExitCode -eq $ExpectedExit -and $result.Stage -eq $ExpectedStage -and $result.Error) ("Wrong saved failure: $Name; " + ($result|ConvertTo-Json -Compress))
        Assert-Test ([IO.File]::ReadAllText((Join-Path $directories[0].FullName 'launcher.log')) -match '\[ОШИБКА ЗАПУСКА\]') "Failure not in transcript: $Name"
        Write-Host "PASS $Name"
        return $directories[0].FullName
    }
    $null = Invoke-FailureCase 'missing-module' @() 1 'import-module'
    Copy-Item -LiteralPath (Join-Path $LauncherDirectory 'lib') -Destination (Join-Path $fixture 'lib') -Recurse
    $null = Invoke-FailureCase 'missing-image-bat' @('-DiskPath',(Join-Path $fixture 'missing.qcow2')) 1 'resolve-image' -Batch
    $null = Invoke-FailureCase 'snapshot-rejected' @('-Snapshot') 1 'initialize'

    # Native stub accepts no guest data: record actual argv and exit 42.
    $qemuDirectory = Join-Path $fixture 'qemu'
    $null = New-Item -ItemType Directory -Path (Join-Path $qemuDirectory 'share')
    $source = @'
using System;
using System.IO;
using System.Reflection;
public static class FileLauncherStub {
     public static int Main(string[] args) {
         Console.OutputEncoding = new System.Text.UTF8Encoding(false);
         if (args.Length == 2 && args[0] == "-accel" && args[1] == "help") {
             Console.WriteLine("Accelerators supported in QEMU binary:\ntcg");
             if (!File.Exists(Path.Combine(Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location), "no-whpx.flag"))) Console.WriteLine("whpx");
             return 0;
         }
        if (Path.GetFileName(Assembly.GetExecutingAssembly().Location) == "qemu-img.exe") {
            string format = args[args.Length - 1].EndsWith(".vtoy", StringComparison.OrdinalIgnoreCase) ? "raw" : "qcow2";
            Console.WriteLine("{\"format\":\"" + format + "\",\"virtual-size\":1048576,\"dirty-flag\":false}");
            return 0;
        }
         foreach (string arg in args) Console.WriteLine(arg);
         foreach (string arg in args) {
              if (arg.StartsWith("if=none,id=pfroot,file=")) {
                  int first = arg.IndexOf("file=") + 5;
                  string file = arg.Substring(first, arg.IndexOf(",format=") - first).Replace(",,", ",");
                 if (!File.Exists(file) || new FileInfo(file).Length > 1024) return 88;
                 Console.WriteLine("PF_DISK_BYTES:" + BitConverter.ToString(File.ReadAllBytes(file)));
             }
         }
         if (File.Exists(Path.Combine(Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location), "uefi-shell.flag"))) {
             foreach (string arg in args) if (arg.StartsWith("file,id=pfser,path=")) {
                 int first = arg.IndexOf("path=") + 5;
                 string path = arg.Substring(first, arg.LastIndexOf(",append=on") - first).Replace(",,", ",");
                 File.WriteAllText(path, "UEFI Interactive Shell v2.2\nShell> ");
             }
             return 0;
         }
        Console.Error.WriteLine("PF_EXPECTED_QEMU_FAILURE");
        return 42;
    }
}
'@
    $stub = Join-Path $qemuDirectory 'qemu-system-x86_64.exe'
    $compiled = Join-Path $capture 'stub.exe'
    Add-Type -TypeDefinition $source -OutputAssembly $compiled -OutputType ConsoleApplication
    [IO.File]::Copy($compiled, $stub, $false)
    [IO.File]::Copy($stub, (Join-Path $qemuDirectory 'qemu-img.exe'), $false)
    foreach ($name in @('edk2-x86_64-code.fd','edk2-i386-vars.fd')) { [IO.File]::WriteAllBytes((Join-Path $qemuDirectory ('share\' + $name)), [byte[]](1,2,3,4)) }
    $disk = Join-Path $fixture 'данные, [1].qcow2'
    [IO.File]::WriteAllBytes($disk, [byte[]](9,8,7,6))
    $hash = (Get-FileHash -LiteralPath $disk).Hash
    $logs = Invoke-FailureCase 'native-exit-bat' @('-DiskPath',$disk,'-QemuExe',$stub,'-RamMb','2048','-Cores','1') 42 'start-qemu' -Batch
    $result = [IO.File]::ReadAllText((Join-Path $logs 'launcher-result.json')) | ConvertFrom-Json
    Assert-Test ($result.QemuExitCode -eq 42) 'Native QEMU failure not retained.'
    Assert-Test ([IO.File]::ReadAllText((Join-Path $logs 'qemu-stderr.log')) -match 'PF_EXPECTED_QEMU_FAILURE') 'Native stderr not retained.'
    $argv = [IO.File]::ReadAllLines((Join-Path $logs 'qemu-stdout.log'))
    Assert-Test ($argv -contains 'tcg,thread=multi' -and $argv -notcontains '-snapshot' -and -not ($argv -match 'whpx|PhysicalDrive')) 'File launch must use only persistent TCG.'
    Assert-Test ($argv -contains 'VGA,id=pfgfx,edid=on,xres=1024,yres=768,refresh_rate=60' -and $argv -notcontains 'virtio') 'File launch must use the fixed 2D display profile.'
    Assert-Test ($argv -contains '-L' -and $argv -contains (Join-Path $qemuDirectory 'share')) 'Portable QEMU must receive its verified firmware search directory.'
    $profile=[IO.File]::ReadAllText((Join-Path $logs 'launch-profile.json'))|ConvertFrom-Json
    Assert-Test ($profile.QemuFilePaths.Disk -notmatch '[^\x00-\x7f]' -and $argv -contains ("if=none,id=pfroot,file=$($profile.QemuFilePaths.Disk.Replace(',', ',,')),format=qcow2")) 'Native disk argv did not use a backend-compatible literal path.'
    Assert-Test ($argv -contains 'virtio-blk-pci,drive=pfroot,addr=0x4,bootindex=1' -and $argv -contains 'virtio-net-pci,netdev=pfnet,addr=0x3') 'Consumer PCI/boot path differs from the factory topology.'
    $resolved=if([IO.Path]::IsPathRooted($profile.QemuFilePaths.Disk)){$profile.QemuFilePaths.Disk}else{Join-Path $profile.QemuWorkingDirectory $profile.QemuFilePaths.Disk}
    if(Test-Path -LiteralPath $resolved){Assert-Test ((Get-FileHash -LiteralPath $resolved).Hash -eq $hash) 'Backend-compatible disk path names another file.'}
    else{Assert-Test ([IO.Path]::GetFileName($resolved) -match '^\.pf-qemu-[0-9a-f]{32}\.file$') 'A non-temporary backend path disappeared.'}
    Assert-Test ($argv -contains 'PF_DISK_BYTES:09-08-07-06') 'Native child did not read the actual source bytes while its alias was held.'
    Assert-Test ((Get-FileHash -LiteralPath $disk).Hash -eq $hash) 'Failure test changed its disk.'
    $stream = [IO.File]::Open(($disk + '.launch.lock'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $stream.Dispose()
    $varsHash = (Get-FileHash -LiteralPath ($disk + '.uefi-vars.fd')).Hash
    $null = Invoke-FailureCase 'native-relaunch' @('-DiskPath',$disk,'-QemuExe',$stub,'-RamMb','2048','-Cores','1') 42 'start-qemu'
    Assert-Test ((Get-FileHash -LiteralPath ($disk + '.uefi-vars.fd')).Hash -eq $varsHash) 'Existing UEFI VARS was replaced on relaunch.'

    $raw = Join-Path $fixture 'общая система, [2].img.vtoy'
    [IO.File]::WriteAllBytes($raw, [byte[]](1,2,3,4))
    $null = Invoke-FailureCase 'raw-requires-explicit-format' @('-DiskPath',$raw,'-QemuExe',$stub) 1 'resolve-image'
    $mismatch = Join-Path $fixture 'wrong-format.img'
    [IO.File]::WriteAllBytes($mismatch, [byte[]](1,2,3,4))
    $null = Invoke-FailureCase 'raw-format-mismatch' @('-DiskPath',$mismatch,'-DiskFormat','raw','-QemuExe',$stub) 1 'validate-image'
    $rawHash = (Get-FileHash -LiteralPath $raw).Hash
    $logs = Invoke-FailureCase 'raw-native-exit' @('-DiskPath',$raw,'-DiskFormat','raw','-RtcBase','localtime','-QemuExe',$stub,'-RamMb','2048','-Cores','1') 42 'start-qemu' -Batch
    $argv = [IO.File]::ReadAllLines((Join-Path $logs 'qemu-stdout.log'))
    $profile=[IO.File]::ReadAllText((Join-Path $logs 'launch-profile.json'))|ConvertFrom-Json
    Assert-Test ($argv -contains ("if=none,id=pfroot,file=$($profile.QemuFilePaths.Disk.Replace(',', ',,')),format=raw") -and $profile.QemuFilePaths.Disk -notmatch '[^\x00-\x7f]') 'RAW file parameters lost the backend-compatible literal path/format.'
    Assert-Test ($argv -notcontains '-snapshot' -and -not ($argv -match 'PhysicalDrive|whpx')) 'RAW mode must retain file-only persistent TCG.'
    Assert-Test ($argv -contains '-rtc' -and $argv -contains 'base=localtime') 'Shared-image RTC base was not forwarded.'
    Assert-Test ((Get-FileHash -LiteralPath $raw).Hash -eq $rawHash) 'RAW native failure changed its image.'
    Assert-Test ($argv -contains 'PF_DISK_BYTES:01-02-03-04') 'Native child did not read the actual RAW source bytes.'
    $lowMemory=Join-Path $fixture 'low-memory.flag';[IO.File]::WriteAllText($lowMemory,'test')
    $null=Invoke-FailureCase 'memory-reserve-rejected' @('-DiskPath',$raw,'-DiskFormat','raw','-QemuExe',$stub,'-RamMb','2048','-Cores','1') 1 'prepare-profile'
    Remove-Item -LiteralPath $lowMemory
    $profile = [IO.File]::ReadAllText((Join-Path $logs 'launch-profile.json')) | ConvertFrom-Json
    Assert-Test ($profile.ImageFormat -eq 'raw' -and $profile.RtcBase -eq 'localtime' -and -not $profile.Snapshot) 'RAW profile metadata is incorrect.'
    . (Join-Path $LauncherDirectory 'lib\pf-whpx.ps1')
    $status=Get-PfWhpxStatus
    if($status.Available){
        $shortcutImage=Join-Path $fixture 'linux.img.vtoy'
        [IO.File]::WriteAllBytes($shortcutImage,[byte[]](1,2,3,4))
        $hash=(Get-FileHash -LiteralPath $shortcutImage).Hash
        $logs=Invoke-FailureCase 'whpx-shortcut-native-exit' @('-RamMb','2048','-Cores','1') 42 'start-qemu' -Batch -Accelerated
        $argv=[IO.File]::ReadAllLines((Join-Path $logs 'qemu-stdout.log'))
        Assert-Test ($argv -contains 'whpx,kernel-irqchip=off' -and -not ($argv -match '^tcg') -and @($argv|Where-Object{$_ -eq '-accel'}).Count -eq 1) 'WHPX must select exactly one accelerator without TCG fallback.'
        Assert-Test ($argv -contains "if=none,id=pfroot,file=$($shortcutImage.Replace(',', ',,')),format=raw" -and $argv -notcontains '-snapshot') 'WHPX lost the same persistent file target.'
        $profile=[IO.File]::ReadAllText((Join-Path $logs 'launch-profile.json'))|ConvertFrom-Json
        Assert-Test ($profile.Accel -eq 'WHPX' -and $profile.WhpxStatus.Available -and $profile.RamMb -eq 2048 -and $profile.Cores -eq 1 -and $profile.RtcBase -eq 'localtime') 'WHPX metadata or resource overrides are incorrect.'
        Assert-Test ((Get-FileHash -LiteralPath $shortcutImage).Hash -eq $hash) 'WHPX failure changed the shared image.'
        $sharedLock=[IO.File]::Open(($shortcutImage+'.launch.lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try{$null=Invoke-FailureCase 'whpx-shared-image-locked' @('-RamMb','2048','-Cores','1') 1 'resolve-image' -Batch -Accelerated}finally{$sharedLock.Dispose()}
        $flag=Join-Path $qemuDirectory 'no-whpx.flag';[IO.File]::WriteAllBytes($flag,[byte[]]@())
        $null=Invoke-FailureCase 'whpx-missing-qemu-backend' @('-RamMb','2048','-Cores','1') 1 'prepare-acceleration' -Batch -Accelerated
        Assert-Test ((Get-FileHash -LiteralPath $shortcutImage).Hash -eq $hash) 'Unsupported WHPX backend changed the image.'
    }else{Write-Host 'SKIP hardware-dependent WHPX native cases: API unavailable on this test host.'}
    $shellFlag=Join-Path $qemuDirectory 'uefi-shell.flag';[IO.File]::WriteAllText($shellFlag,'test')
    $beforeShellVars=(Get-FileHash -LiteralPath ($raw+'.uefi-vars.fd')).Hash
    $null=Invoke-FailureCase 'uefi-shell-is-not-linux-success' @('-DiskPath',$raw,'-DiskFormat','raw','-QemuExe',$stub,'-RamMb','2048','-Cores','1') 1 'uefi-boot'
    Assert-Test ((Get-FileHash -LiteralPath ($raw+'.uefi-vars.fd')).Hash -eq $beforeShellVars) 'UEFI shell detection reset persistent firmware.'
    Remove-Item -LiteralPath $shellFlag
    Assert-Test (@(Get-ChildItem -LiteralPath $fixture -File -Force|Where-Object{$_.Name -like '.pf-qemu-*'}).Count -eq 0) 'Temporary backend aliases leaked after QEMU exited.'
    Write-Host 'File launcher failure-path tests passed; Linux login/persistence require the real VM.'
} finally { Remove-Item -LiteralPath $fixture,$capture -Recurse -Force }
