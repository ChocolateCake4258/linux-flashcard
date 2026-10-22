# Real file-backed metadata reset and fail-closed layout classification. No P/Invoke.
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\pf-deferred-write.ps1')
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\pf-tools.psm1') -WarningAction SilentlyContinue
$root=Join-Path $env:TEMP ('pf-layout-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($root)
$global:LayoutFile=Join-Path $root 'disk.bin'
$global:LayoutIdentity=[pscustomobject]@{Path='test-device';SerialNumber='serial';Size=8MB}
$passed=0
function Require($Condition,$Message){if(-not $Condition){throw $Message}}
function Reject([scriptblock]$Body){$failed=$false;try{& $Body|Out-Null}catch{$failed=$true};Require $failed 'Expected fail-closed rejection'}
function Case($Name,[scriptblock]$Body){& $Body;$script:passed++;Write-Host ('PASS '+$Name)}
Add-Type -TypeDefinition @'
using System;using System.IO;
public static class LayoutFixture {
 public static int Writes, Removes, Parts=1, Refreshes, Initializations;
 public static string Mode="";
 public static string File;
 public static bool Changed,Gpt;
}
public static class PfRawDisk {
 public static void WriteAt(FileStream stream,byte[] bytes,int count,long offset) {
  LayoutFixture.Writes++;
  if(LayoutFixture.Mode.StartsWith("native-"))throw new System.ComponentModel.Win32Exception(21,"Injected Windows synthetic-view NOT_READY");
  if(LayoutFixture.Mode=="write-failure")throw new IOException("Injected metadata write failure");
  stream.Position=offset;stream.Write(bytes,0,count);
 }
 public static void Refresh(string drive) {
  LayoutFixture.Refreshes++;
  if(LayoutFixture.Mode!="stale-partition")LayoutFixture.Parts=0;
 }
}
public static class PfDeferredGpt {
 static uint Crc(byte[] bytes){uint crc=0xffffffff;foreach(byte b in bytes){crc^=b;for(int bit=0;bit<8;bit++)crc=(crc>>1)^((crc&1)!=0?0xedb88320u:0u);}return ~crc;}
 public static int Initialize(string path,Guid id){
  if(path!=@"\\.\PhysicalDrive7")throw new Exception("Unexpected native init path");
  LayoutFixture.Initializations++;
  if(LayoutFixture.Mode=="native-failure")return 21;
  using(var stream=new FileStream(LayoutFixture.File,FileMode.Open,FileAccess.Write,FileShare.ReadWrite)){
   long last=stream.Length/512-1;byte[] table=new byte[16384];
   if(LayoutFixture.Mode=="native-not-empty")table[0]=1;
   foreach(long lba in new long[]{1,last}){
    long tableLba=lba==1?2:last-32;byte[] header=new byte[512];System.Text.Encoding.ASCII.GetBytes("EFI PART").CopyTo(header,0);
    BitConverter.GetBytes(0x10000u).CopyTo(header,8);BitConverter.GetBytes(92u).CopyTo(header,12);
    BitConverter.GetBytes((ulong)lba).CopyTo(header,24);BitConverter.GetBytes((ulong)(lba==1?last:1)).CopyTo(header,32);
    id.ToByteArray().CopyTo(header,56);BitConverter.GetBytes((ulong)tableLba).CopyTo(header,72);
    BitConverter.GetBytes(128u).CopyTo(header,80);BitConverter.GetBytes(128u).CopyTo(header,84);BitConverter.GetBytes(Crc(table)).CopyTo(header,88);
    byte[] significant=new byte[92];Array.Copy(header,significant,92);BitConverter.GetBytes(Crc(significant)).CopyTo(header,16);
    if(LayoutFixture.Mode=="native-corrupt")header[16]^=1;
    stream.Position=lba*512;stream.Write(header,0,512);stream.Position=tableLba*512;stream.Write(table,0,table.Length);
   }
   stream.Flush();
  }
  LayoutFixture.Gpt=true;LayoutFixture.Parts=LayoutFixture.Mode=="native-stale"?1:0;
  if(LayoutFixture.Mode=="native-identity")LayoutFixture.Changed=true;
  return 0;
 }
}
'@
[LayoutFixture]::File=$global:LayoutFile
function Reset-Layout($Mode=''){
 [LayoutFixture]::Mode=$Mode;[LayoutFixture]::Writes=0;[LayoutFixture]::Removes=0;[LayoutFixture]::Parts=1;[LayoutFixture]::Refreshes=0;[LayoutFixture]::Changed=$false;[LayoutFixture]::Initializations=0;[LayoutFixture]::Gpt=$false
 $bytes=New-Object byte[] (8MB);$bytes[510]=0x55;$bytes[511]=0xaa;$bytes[2MB+17]=0x63
 if($Mode -eq 'partition-entry'){$bytes[450]=7}
 if($Mode -eq 'primary-gpt'){[Text.Encoding]::ASCII.GetBytes('EFI PART').CopyTo($bytes,512)}
 if($Mode -eq 'backup-gpt'){[Text.Encoding]::ASCII.GetBytes('EFI PART').CopyTo($bytes,($bytes.Length-512))}
 [IO.File]::WriteAllBytes($global:LayoutFile,$bytes)
}
function Assert-PfUsbDisk {
 param($Number,$Identity)
 if($Number -ne 7 -or $Identity.Path -ne 'test-device' -or [LayoutFixture]::Changed){throw 'Target identity changed'}
 [pscustomobject]@{PartitionStyle=$(if([LayoutFixture]::Mode -eq 'style-gpt' -or [LayoutFixture]::Gpt){'GPT'}else{'MBR'});Size=8MB}
}
function Get-PfDiskPartitions {
 param($Number)
 if([LayoutFixture]::Mode -eq 'enumeration'){throw 'Partition enumeration failed'}
 if([LayoutFixture]::Parts -eq 2){foreach($offset in @(1MB,4MB)){[pscustomobject]@{Offset=$offset;Size=3MB;DriveLetter='';AccessPaths=@()}};return}
 if([LayoutFixture]::Parts){[pscustomobject]@{Offset=$(if([LayoutFixture]::Mode -eq 'real-partition'){1MB}else{0});Size=$(if([LayoutFixture]::Mode -eq 'wrong-size'){7MB}else{8MB});DriveLetter=$(if([LayoutFixture]::Mode -eq 'letter'){'X'}else{''});AccessPaths=$(if([LayoutFixture]::Mode -eq 'access-path'){@('volume-path')}else{@()})}}
}
function Get-Volume {
 [CmdletBinding()]param([Parameter(ValueFromPipeline=$true)]$Partition)
 process{
  if([LayoutFixture]::Mode -eq 'volume-error'){throw 'Volume enumeration failed'}
  if([LayoutFixture]::Mode -eq 'mounted'){[pscustomobject]@{FileSystem='NTFS'}}
 }
}
function Open-PfRawDisk {
 param($Drive,$Access)
 if($Drive -ne '\\.\PhysicalDrive7'){throw 'Unexpected physical path'}
 if($Access -eq 'Write' -and [LayoutFixture]::Mode -eq 'identity') {[LayoutFixture]::Changed=$true}
 $mode=if($Access -eq 'Write'){[IO.FileAccess]::Write}else{[IO.FileAccess]::Read}
 [IO.File]::Open($global:LayoutFile,[IO.FileMode]::Open,$mode,[IO.FileShare]::ReadWrite)
}
function Read-PfRawBytes {
 param($Handle,[byte[]]$Bytes,[long]$Offset)
 if([LayoutFixture]::Mode -eq 'not-ready'){throw 'Injected ERROR_NOT_READY'}
 $Handle.Position=$Offset;$count=$Handle.Read($Bytes,0,$Bytes.Length)
 if([LayoutFixture]::Mode -eq 'short-read'){return ($count-1)}
 if([LayoutFixture]::Mode -eq 'corrupt-readback' -and [LayoutFixture]::Writes){$Bytes[123]=$Bytes[123] -bxor 1}
 return $count
}
function Flush-PfRawDisk {param($Handle) $Handle.Flush($true)}
function Remove-PfDiskLayout {
 param($Number,$Identity)
 [LayoutFixture]::Removes++
 if([LayoutFixture]::Mode -eq 'ordinary-empty'){[LayoutFixture]::Parts=0;return}
 if([LayoutFixture]::Mode -eq 'fallback'){[LayoutFixture]::Parts=1}
 throw 'Injected VDS zero-sectors/NOT_READY clean failure'
}
function Update-HostStorageCache {}
try{
 Case 'Synthetic empty view clears only verified boot/GPT regions' {
  Reset-Layout
  $method=Initialize-PfDeferredDiskLayout 7 $global:LayoutIdentity
  Require ($method -eq 'VerifiedWholeDeviceMetadataClear' -and [LayoutFixture]::Writes -eq 2 -and [LayoutFixture]::Removes -eq 0) 'Wrong normalization method'
  $actual=[IO.File]::ReadAllBytes($global:LayoutFile)
  Require ($actual[2MB+17] -eq 0x63 -and $actual[510] -eq 0) 'Metadata clear touched middle data or retained MBR signature'
  Require ([LayoutFixture]::Parts -eq 0 -and [LayoutFixture]::Refreshes -eq 1) 'Unpartitioned state not verified'
 }
 Case 'Ordinary layout removal does not zero metadata separately' {
  Reset-Layout 'ordinary-empty';[LayoutFixture]::Parts=0
  $method=Initialize-PfDeferredDiskLayout 7 $global:LayoutIdentity
  Require ($method -eq 'VerifiedUnpartitionedMedia' -and [LayoutFixture]::Writes -eq 0 -and [LayoutFixture]::Removes -eq 0) 'Already unpartitioned media was unnecessarily changed'
 }
 Case 'VDS failure is recoverable only after a proved empty whole-device view' {
  Reset-Layout 'fallback';[LayoutFixture]::Parts=2
  $method=Initialize-PfDeferredDiskLayout 7 $global:LayoutIdentity
  Require ($method -eq 'VerifiedWholeDeviceMetadataClear' -and [LayoutFixture]::Removes -eq 1 -and [LayoutFixture]::Writes -eq 2) 'VDS fallback was not verified'
 }
 Case 'Real entries, GPT, geometry, paths and mounted volumes reject normalization' {
  foreach($mode in @('partition-entry','primary-gpt','backup-gpt','style-gpt','real-partition','wrong-size','letter','access-path','mounted','volume-error','enumeration')){
   Reset-Layout $mode;Reject {Initialize-PfDeferredDiskLayout 7 $global:LayoutIdentity}
   Require ([LayoutFixture]::Writes -eq 0) ('Unsafe metadata write for '+$mode)
  }
 }
 Case 'Not-ready and short reads stop before deleting the old layout' {
  foreach($mode in @('not-ready','short-read')){
   Reset-Layout $mode;Reject {Initialize-PfDeferredDiskLayout 7 $global:LayoutIdentity}
   Require ([LayoutFixture]::Writes -eq 0 -and [LayoutFixture]::Removes -eq 0) 'Readiness error reached destructive preparation'
  }
 }
 Case 'Write failure, corrupt read-back, changed identity and stale view cannot pass' {
  foreach($mode in @('write-failure','corrupt-readback','identity','stale-partition')){
   Reset-Layout $mode;Reject {Initialize-PfDeferredDiskLayout 7 $global:LayoutIdentity}
  }
 }
 Case 'Native recovery validates both GPT headers/tables after synthetic write NOT_READY' {
  Reset-Layout 'native-success'
  $method=Initialize-PfDeferredDiskLayout 7 $global:LayoutIdentity
  Require ($method -eq 'VerifiedNativeEmptyGpt' -and [LayoutFixture]::Initializations -eq 1 -and [LayoutFixture]::Parts -eq 0) 'Native empty GPT recovery did not pass'
  Require (([IO.File]::ReadAllBytes($global:LayoutFile))[2MB+17] -eq 0x63) 'Native recovery changed middle data'
 }
 Case 'Native initialization errors, CRC/data/identity changes and nonempty results reject success' {
  foreach($mode in @('native-failure','native-corrupt','native-not-empty','native-identity','native-stale')){
   Reset-Layout $mode;Reject {Initialize-PfDeferredDiskLayout 7 $global:LayoutIdentity}
  }
 }
 Write-Host ("Results: $passed deferred layout checks passed; no physical device opened.")
}finally{Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
