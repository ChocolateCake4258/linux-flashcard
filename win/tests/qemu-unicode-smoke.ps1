# Real QEMU backend, paused/no guest execution, read-only disposable firmware copy.
param([Parameter(Mandatory=$true)][string]$QemuExe)
$ErrorActionPreference='Stop'
$win=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $win 'lib\pf-tools.psm1') -WarningAction SilentlyContinue
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $win 'run-from-usb.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Consumer parse failed.'}
$function=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'ConvertTo-QemuFilePath'},$true)
if(-not $function){throw 'Missing production backend path resolver.'}
. ([scriptblock]::Create($function.Extent.Text))
$qemuAliasPaths=[Collections.Generic.List[string]]::new()
$root=Join-Path $env:TEMP ('pf-native кириллица [1] '+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($root)
$firmware=Join-Path (Split-Path $QemuExe -Parent) 'share\qemu\edk2-x86_64-code.fd'
if(-not(Test-Path -LiteralPath $firmware)){$firmware=Join-Path (Split-Path $QemuExe -Parent) 'share\edk2-x86_64-code.fd'}
$copy=Join-Path $root 'прошивка [2].fd';$process=$null;$client=$null;$listener=$null
try{
    [IO.File]::Copy($firmware,$copy,$false)
    $before=(Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash
    $path=ConvertTo-QemuFilePath $copy $root
    if($path -match '[^\x00-\x7f]'){throw 'Non-ASCII path reached the real file backend.'}
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    $listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop();$listener=$null
    $arguments=@('-machine','none','-nodefaults','-display','none','-S','-qmp',('tcp:127.0.0.1:'+$port+',server=on,wait=off'),'-drive',('if=none,id=probe,format=raw,readonly=on,file='+$path.Replace(',',',,')))
    $process=[Diagnostics.Process]::new();$process.StartInfo.FileName=$QemuExe;$process.StartInfo.WorkingDirectory=$root
    $process.StartInfo.Arguments=Join-PfArguments (ConvertTo-PfArgumentList $arguments)
    $process.StartInfo.UseShellExecute=$false;$process.StartInfo.CreateNoWindow=$true
    $process.StartInfo.RedirectStandardOutput=$true;$process.StartInfo.RedirectStandardError=$true
    $null=$process.Start();$null=$process.Handle
    $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
    for($attempt=0;$attempt -lt 100;$attempt++){
        if($process.HasExited){throw ('QEMU could not open Unicode fixture: '+$stderr.GetAwaiter().GetResult())}
        try{$client=[Net.Sockets.TcpClient]::new('127.0.0.1',$port);break}catch{Start-Sleep -Milliseconds 100}
    }
    if(-not $client){throw 'Native backend QMP timeout.'}
    $stream=$client.GetStream();$stream.ReadTimeout=10000
    $reader=[IO.StreamReader]::new($stream);$writer=[IO.StreamWriter]::new($stream,[Text.UTF8Encoding]::new($false));$writer.AutoFlush=$true
    $null=$reader.ReadLine()
    foreach($command in @('qmp_capabilities','query-status','quit')){
        $writer.WriteLine((@{execute=$command;id=$command}|ConvertTo-Json -Compress))
        do{$line=$reader.ReadLine();if(-not $line){throw 'Probe QMP closed early.'};$reply=$line|ConvertFrom-Json}while($reply.id -ne $command)
        if($reply.error){throw $line}
    }
    if(-not $process.WaitForExit(10000) -or $process.ExitCode -ne 0){throw 'Paused native probe did not exit cleanly.'}
    if((Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash -ne $before){throw 'Read-only backend modified fixture.'}
    Write-Host 'PASS real QEMU: Unicode directory/filename, ASCII backend path, read-only input, no guest execution, clean exit0.'
}finally{
    if($client){$client.Dispose()};if($listener){$listener.Stop()}
    if($process){if(-not $process.HasExited){$process.Kill();$process.WaitForExit()};$process.Dispose()}
    foreach($alias in $qemuAliasPaths){[IO.File]::Delete($alias)}
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
