# Persistent owned runner: survives a closed coordinator and records the real exit.
param([Parameter(Mandatory=$true)][string]$Job)
$ErrorActionPreference='Stop'
$config=Get-Content -LiteralPath $Job -Raw -Encoding UTF8|ConvertFrom-Json
$dir=Split-Path $Job -Parent
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\pf-storage.ps1')
$workspace=Split-Path (Split-Path $dir -Parent) -Parent
Set-PfStorageEnvironment -Root (Join-Path $workspace 'bootstrap\environment') -Create
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\pf-tools.psm1') -Force -WarningAction SilentlyContinue
$p=[Diagnostics.Process]::new();$out=$null;$err=$null;$guard=$null
$code=1;$errorText=$null;$started=$false
try{
 $guard=[IO.File]::Open($config.Guard,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 $arguments=ConvertTo-PfArgumentList -Arguments @($config.Arguments|ForEach-Object{[string]$_})
 $p.StartInfo.FileName=$config.Qemu;$p.StartInfo.Arguments=Join-PfArguments $arguments
 $p.StartInfo.WorkingDirectory=Split-Path $config.Qemu -Parent
 $p.StartInfo.UseShellExecute=$false;$p.StartInfo.CreateNoWindow=$true
 $p.StartInfo.RedirectStandardOutput=$true;$p.StartInfo.RedirectStandardError=$true
 $out=[IO.File]::Open((Join-Path $dir 'stdout.log'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
 $err=[IO.File]::Open((Join-Path $dir 'stderr.log'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
 if(-not $p.Start()){throw 'QEMU did not start.'}
 $started=$true
 $a=$p.StandardOutput.BaseStream.CopyToAsync($out);$b=$p.StandardError.BaseStream.CopyToAsync($err)
 $data=@{Pid=$p.Id;RunnerPid=$PID;Started=$p.StartTime.ToUniversalTime().ToString('o');JobId=$config.JobId;BuildId=$config.BuildId;Arguments=$arguments;Qemu=$config.Qemu;RuntimeEnvironment=@{TEMP=$env:TEMP;TMP=$env:TMP;LOCALAPPDATA=$env:LOCALAPPDATA;ModuleCache=$env:PSModuleAnalysisCachePath}}|ConvertTo-Json -Depth 3
 [IO.File]::WriteAllText((Join-Path $dir 'process.json.new'),$data,[Text.Encoding]::UTF8)
 [IO.File]::Move((Join-Path $dir 'process.json.new'),(Join-Path $dir 'process.json'))
 $p.WaitForExit();$null=$a.GetAwaiter().GetResult();$null=$b.GetAwaiter().GetResult();$code=$p.ExitCode
}catch{$errorText=($_|Out-String)}
finally{
 if($started -and -not $p.HasExited){$p.WaitForExit()}
 foreach($object in @($out,$err,$guard,$p)){if($object){$object.Dispose()}}
 $data=@{ExitCode=$code;Error=$errorText;Finished=(Get-Date).ToString('o');JobId=$config.JobId;BuildId=$config.BuildId}|ConvertTo-Json
 [IO.File]::WriteAllText((Join-Path $dir 'exit.json.new'),$data,[Text.Encoding]::UTF8)
 [IO.File]::Move((Join-Path $dir 'exit.json.new'),(Join-Path $dir 'exit.json'))
}
exit $code
