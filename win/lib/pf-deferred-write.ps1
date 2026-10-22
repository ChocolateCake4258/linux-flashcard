# Verified normalization of a Windows synthetic whole-device USB partition.
# Never treats a partition-enumeration failure or a real/mounted volume as empty.
function Assert-PfDeferredDiskReady {
    param([int]$Number,$Identity)
    $null=Assert-PfUsbDisk -Number $Number -Identity $Identity
    $handle=$null
    try{
        $handle=Open-PfRawDisk -Drive ("\\.\PhysicalDrive"+$Number) -Access Read
        foreach($offset in @(0L,([long]$Identity.Size-512))){
            $bytes=New-Object byte[] 512
            if((Read-PfRawBytes -Handle $handle -Bytes $bytes -Offset $offset) -ne 512){throw 'Short physical USB readiness read.'}
        }
    }finally{if($handle){$handle.Dispose()}}
}

function Test-PfEmptyWholeDeviceView {
    param([int]$Number,$Identity)
    $disk=Assert-PfUsbDisk -Number $Number -Identity $Identity
    $parts=@(Get-PfDiskPartitions -Number $Number)
    if($parts.Count -ne 1 -or $disk.PartitionStyle -eq 'GPT'){return $false}
    $part=$parts[0]
    if($null -eq $part.Offset -or $null -eq $part.Size -or [long]$part.Offset -ne 0 -or [long]$part.Size -ne [long]$Identity.Size){return $false}
    if(([string]$part.DriveLetter).Trim([char]0) -or @($part.AccessPaths|Where-Object{$_}).Count){return $false}
    if(@($part|Get-Volume -ErrorAction Stop).Count){return $false}
    $handle=$null
    try{
        $handle=Open-PfRawDisk -Drive ("\\.\PhysicalDrive"+$Number) -Access Read
        foreach($offset in @(0L,512L,([long]$Identity.Size-512))){
            $bytes=New-Object byte[] 512
            if((Read-PfRawBytes -Handle $handle -Bytes $bytes -Offset $offset) -ne 512){throw 'Short empty-layout metadata read.'}
            if($offset -eq 0 -and @($bytes[446..509]|Where-Object{$_ -ne 0}).Count){return $false}
            if($offset -ne 0 -and [Text.Encoding]::ASCII.GetString($bytes,0,8) -eq 'EFI PART'){return $false}
        }
    }finally{if($handle){$handle.Dispose()}}
    return $true
}

function Add-PfDeferredGptNative {
    if('PfDeferredGpt' -as [type]){return}
    Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;using Microsoft.Win32.SafeHandles;
public static class PfDeferredGpt {
 [StructLayout(LayoutKind.Sequential)]public struct Request {public uint Style;public Guid DiskId;public uint MaximumPartitionCount;}
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,ExactSpelling=true,SetLastError=true)]static extern SafeFileHandle CreateFileW(string p,uint a,uint s,IntPtr se,uint c,uint f,IntPtr t);
 [DllImport("kernel32.dll",SetLastError=true)]static extern bool DeviceIoControl(SafeFileHandle h,uint c,IntPtr i,uint il,IntPtr o,uint ol,out uint got,IntPtr ov);
 public static byte[] Encode(Guid id){
  int size=Marshal.SizeOf(typeof(Request));if(size!=24)throw new InvalidOperationException("Unexpected CREATE_DISK_GPT ABI");
  var data=new Request{Style=1,DiskId=id,MaximumPartitionCount=128};IntPtr p=Marshal.AllocHGlobal(size);
  try{Marshal.StructureToPtr(data,p,false);byte[] bytes=new byte[size];Marshal.Copy(p,bytes,0,size);return bytes;}finally{Marshal.FreeHGlobal(p);}
 }
 public static int Initialize(string path,Guid id){
  byte[] bytes=Encode(id);IntPtr p=Marshal.AllocHGlobal(bytes.Length);
  try{Marshal.Copy(bytes,0,p,bytes.Length);using(var h=CreateFileW(path,0xc0000000,3,IntPtr.Zero,3,0x80,IntPtr.Zero)){
   if(h.IsInvalid)return Marshal.GetLastWin32Error();uint got;
   if(!DeviceIoControl(h,0x0007c058,p,(uint)bytes.Length,IntPtr.Zero,0,out got,IntPtr.Zero))return Marshal.GetLastWin32Error();
   if(!DeviceIoControl(h,0x00070140,IntPtr.Zero,0,IntPtr.Zero,0,out got,IntPtr.Zero))return Marshal.GetLastWin32Error();return 0;
  }}finally{Marshal.FreeHGlobal(p);}
 }
}
'@
}

function Initialize-PfEmptyGptLayout {
    param([int]$Number,$Identity)
    if(-not(Test-PfEmptyWholeDeviceView $Number $Identity)){throw 'Empty GPT recovery requires an exact empty whole-device view.'}
    Add-PfDeferredGptNative
    $null=Assert-PfUsbDisk -Number $Number -Identity $Identity
    $guid=[guid]::NewGuid();$drive="\\.\PhysicalDrive"+$Number
    $code=[PfDeferredGpt]::Initialize($drive,$guid)
    if($code -ne 0){throw [ComponentModel.Win32Exception]::new($code,'Empty GPT initialization failed')}
    Update-HostStorageCache -ErrorAction Stop
    $disk=Assert-PfUsbDisk -Number $Number -Identity $Identity
    if($disk.PartitionStyle -ne 'GPT' -or @(Get-PfDiskPartitions -Number $Number).Count){throw 'Empty GPT recovery did not produce a partition-free disk.'}
    $handle=$null
    try{
        $handle=Open-PfRawDisk -Drive $drive -Access Read
        $last=[long]$Identity.Size/512-1
        foreach($lba in @(1L,$last)){
            $header=New-Object byte[] 512
            if((Read-PfRawBytes -Handle $handle -Bytes $header -Offset ($lba*512)) -ne 512 -or [Text.Encoding]::ASCII.GetString($header,0,8) -ne 'EFI PART'){throw 'Empty GPT header read-back failed.'}
            $width=[BitConverter]::ToUInt32($header,12);$expected=[BitConverter]::ToUInt32($header,16)
            if($width -lt 92 -or $width -gt 512 -or [BitConverter]::ToUInt64($header,24) -ne $lba -or [BitConverter]::ToUInt64($header,32) -ne $(if($lba -eq 1){$last}else{1})){throw 'Empty GPT header geometry differs.'}
            $header[16]=0;$header[17]=0;$header[18]=0;$header[19]=0
            if((Get-PfCrc32 -Bytes $header[0..($width-1)]) -ne $expected){throw 'Empty GPT header CRC mismatch.'}
            if([Convert]::ToBase64String($header,56,16) -cne [Convert]::ToBase64String($guid.ToByteArray())){throw 'Empty GPT disk identity mismatch.'}
            $count=[BitConverter]::ToUInt32($header,80);$entryWidth=[BitConverter]::ToUInt32($header,84);$tableLba=[BitConverter]::ToUInt64($header,72)
            if($count -ne 128 -or $entryWidth -ne 128 -or $tableLba -lt 2 -or $tableLba -gt ($last-32)){throw 'Empty GPT table bounds differ.'}
            $table=New-Object byte[] (16KB)
            if((Read-PfRawBytes -Handle $handle -Bytes $table -Offset ([long]$tableLba*512)) -ne $table.Length -or @($table|Where-Object{$_ -ne 0}).Count -or (Get-PfCrc32 -Bytes $table) -ne [BitConverter]::ToUInt32($header,88)){throw 'Empty GPT table is not verified empty.'}
        }
    }finally{if($handle){$handle.Dispose()}}
    Write-Host '[OK] Native empty GPT verified: no partitions, both headers/tables and CRC valid.' -ForegroundColor Green
    return 'VerifiedNativeEmptyGpt'
}

function Clear-PfEmptyWholeDeviceMetadata {
    param([int]$Number,$Identity)
    if(-not(Test-PfEmptyWholeDeviceView $Number $Identity)){throw 'USB layout is not a verified empty whole-device view.'}
    $drive="\\.\PhysicalDrive"+$Number;$handle=$null
    $zeros=New-Object byte[] (1MB)
    $writeError=$null
    try{
        $null=Assert-PfUsbDisk -Number $Number -Identity $Identity
        $handle=Open-PfRawDisk -Drive $drive -Access Write
        foreach($offset in @(([long]$Identity.Size-1MB),0L)){
            $null=Assert-PfUsbDisk -Number $Number -Identity $Identity
            [PfRawDisk]::WriteAt($handle,$zeros,$zeros.Length,$offset)
        }
        Flush-PfRawDisk -Handle $handle
    }catch{$writeError=$_}finally{if($handle){$handle.Dispose()}}
    if($writeError){
        $exception=$writeError.Exception;while($exception.InnerException){$exception=$exception.InnerException}
        if($exception.PSObject.Properties['NativeErrorCode'] -and $exception.NativeErrorCode -eq 21 -and (Test-PfEmptyWholeDeviceView $Number $Identity)){
            return Initialize-PfEmptyGptLayout $Number $Identity
        }
        throw $writeError
    }
    $handle=$null;$sha=[Security.Cryptography.SHA256]::Create()
    try{
        $handle=Open-PfRawDisk -Drive $drive -Access Read
        $expected=[Convert]::ToBase64String($sha.ComputeHash($zeros))
        foreach($offset in @(0L,([long]$Identity.Size-1MB))){
            $actual=New-Object byte[] (1MB)
            if((Read-PfRawBytes -Handle $handle -Bytes $actual -Offset $offset) -ne $actual.Length -or [Convert]::ToBase64String($sha.ComputeHash($actual)) -cne $expected){throw 'USB metadata clear failed read-back.'}
        }
    }finally{if($handle){$handle.Dispose()};$sha.Dispose()}
    $null=Assert-PfUsbDisk -Number $Number -Identity $Identity
    [PfRawDisk]::Refresh($drive)
    Update-HostStorageCache -ErrorAction Stop
    if(@(Get-PfDiskPartitions -Number $Number).Count){throw 'Windows still reports a partition after verified metadata clear. Reconnect this same USB and retry; no image body was written.'}
    Write-Host '[OK] Empty whole-device view normalized; both metadata regions read back as zero.' -ForegroundColor Green
    return 'VerifiedWholeDeviceMetadataClear'
}

function Initialize-PfDeferredDiskLayout {
    param([int]$Number,$Identity)
    Assert-PfDeferredDiskReady $Number $Identity
    if(@(Get-PfDiskPartitions -Number $Number).Count -eq 0){return 'VerifiedUnpartitionedMedia'}
    if(Test-PfEmptyWholeDeviceView $Number $Identity){
        return Clear-PfEmptyWholeDeviceMetadata $Number $Identity
    }
    try{Remove-PfDiskLayout -Number $Number -Identity $Identity}
    catch{
        # A removable USB can report a synthetic FAT16 partition after successful
        # IOCTL deletion, while VDS rejects CLEAN with zero-sectors/NOT_READY.
        # Raw boundary reads, empty on-disk partition tables and no volume are
        # required before normalization; a general CLEAN error is never ignored.
        if(-not(Test-PfEmptyWholeDeviceView $Number $Identity)){throw}
        return Clear-PfEmptyWholeDeviceMetadata $Number $Identity
    }
    return 'VerifiedLayoutRemoval'
}
