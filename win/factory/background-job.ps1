# A triggerless, build-scoped runner survives coordinator/console disconnection.
param([Parameter(Mandatory=$true)][string]$Job,
      [ValidateSet('Start','Status','Cleanup')][string]$Action='Start')
$ErrorActionPreference='Stop'
$config=Get-Content -LiteralPath $Job -Raw -Encoding UTF8|ConvertFrom-Json
if($config.BuildId -notmatch '^[0-9a-f-]{36}$' -or $config.JobId -notmatch '^[0-9a-f]{32}$'){throw 'Invalid factory job identity.'}
$name='PF-Factory-'+$config.BuildId+'-'+$config.JobId
$runner=[string]$config.RunnerScript
if(-not(Test-Path -LiteralPath $runner -PathType Leaf)){throw 'Owned factory runner source missing.'}
$environment=Join-Path (Split-Path (Split-Path (Split-Path $Job -Parent) -Parent) -Parent) 'bootstrap\environment'
$storageScript=Join-Path (Split-Path (Split-Path $runner -Parent) -Parent) 'lib\pf-storage.ps1'
$command=". '"+$storageScript.Replace("'","''")+"'; Set-PfStorageEnvironment -Root '"+$environment.Replace("'","''")+"' -Create; & '"+$runner.Replace("'","''")+"' -Job '"+$Job.Replace("'","''")+"'"
$encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
$exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand '+$encoded
$task=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
if($task){
 $actions=@($task.Actions)
 if(@($task.Triggers|Where-Object{$null -ne $_}).Count -or $actions.Count -ne 1 -or $actions[0].Execute -ine $exe -or $actions[0].Arguments -cne $arguments){throw 'Factory background task identity changed.'}
}
if($Action -eq 'Status'){
 $info=if($task){Get-ScheduledTaskInfo -TaskName $name}else{$null}
 [ordered]@{task_name=$name;exists=[bool]$task;state=$(if($task){[string]$task.State}else{'Missing'});last_result=$info.LastTaskResult}|ConvertTo-Json
 return
}
if($Action -eq 'Cleanup'){
 if($task){
  if([string]$task.State -in 'Running','Queued'){throw 'Factory runner still active.'}
  if(-not(Test-Path -LiteralPath (Join-Path (Split-Path $Job -Parent) 'exit.json'))){throw 'No runner exit receipt; preserve background task for diagnosis.'}
  $export=Join-Path (Split-Path $Job -Parent) 'runner-task.xml'
  if(-not(Test-Path -LiteralPath $export)){[IO.File]::WriteAllText($export,(Export-ScheduledTask -TaskName $name),[Text.Encoding]::Unicode)}
  Unregister-ScheduledTask -TaskName $name -Confirm:$false
 }
 return
}
if($task){throw 'Factory background task already exists.'}
$principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero)
$start=New-ScheduledTaskAction -Execute $exe -Argument $arguments -WorkingDirectory (Split-Path $Job -Parent)
$task=New-ScheduledTask -Action $start -Principal $principal -Settings $settings
$null=Register-ScheduledTask -TaskName $name -InputObject $task
Start-ScheduledTask -TaskName $name
[ordered]@{task_name=$name;started=$true}|ConvertTo-Json
