# Compile real metadata ABI without opening any physical device.
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\pf-deferred-write.ps1')
Add-PfDeferredGptNative
$bytes=[PfDeferredGpt]::Encode([guid]'00112233-4455-6677-8899-aabbccddeeff')
$expected='01-00-00-00-33-22-11-00-55-44-77-66-88-99-AA-BB-CC-DD-EE-FF-80-00-00-00'
if([BitConverter]::ToString($bytes) -cne $expected){throw 'CREATE_DISK_GPT bytes differ from the Windows ABI vector.'}
if([Runtime.InteropServices.Marshal]::SizeOf([type][PfDeferredGpt+Request]) -ne 24){throw 'CREATE_DISK_GPT size differs.'}
foreach($entry in @(@('Style',0),@('DiskId',4),@('MaximumPartitionCount',20))){
 if([Runtime.InteropServices.Marshal]::OffsetOf([type][PfDeferredGpt+Request],$entry[0]).ToInt32() -ne $entry[1]){throw 'CREATE_DISK_GPT field offset differs.'}
}
Write-Host 'PASS real CREATE_DISK_GPT ABI: size24, offsets0/4/20, independent byte vector; no native I/O.'
