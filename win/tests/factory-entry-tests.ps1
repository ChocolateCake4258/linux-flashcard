# Non-destructive entrypoint contracts; no downloads, VM or physical disk.
$ErrorActionPreference='Stop'
$entry=Join-Path (Split-Path $PSScriptRoot -Parent) 'build-debian.ps1'
$shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$candidate=Join-Path $env:TEMP ('pf-factory-plan-'+[guid]::NewGuid().ToString('N'))
& $shell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $entry -Workspace $candidate -Plan -NoPause
if($LASTEXITCODE -ne 0 -or (Test-Path -LiteralPath $candidate)){throw 'Plan must succeed without creating artifacts.'}
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
& $shell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $entry -Workspace $repo -Plan -NoPause 2>&1|Out-Null
if($LASTEXITCODE -eq 0){throw 'Source directory was accepted as a factory workspace.'}
& $shell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $entry -Workspace $candidate -Plan -WriteUsb -DiskNumber 2 -NoPause 2>&1|Out-Null
if($LASTEXITCODE -eq 0 -or (Test-Path -LiteralPath $candidate)){throw 'Physical write without explicit serial/size was accepted.'}
Write-Host 'PASS factory entry: read-only plan, source isolation, explicit physical identity.'
