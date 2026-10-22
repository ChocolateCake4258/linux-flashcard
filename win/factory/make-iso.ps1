# Built-in IMAPI ISO creation for both NoCloud metadata and pinned input media.
param([Parameter(Mandatory=$true)][string]$Directory,
      [Parameter(Mandatory=$true)][string]$Output,
      [Parameter(Mandatory=$true)][string]$Label)
$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\pf-tools.psm1') -Force -WarningAction SilentlyContinue
if(-not(Test-Path -LiteralPath $Directory -PathType Container)){throw 'ISO source directory missing.'}
if(Test-Path -LiteralPath $Output){throw 'ISO output already exists.'}
# Stream the full input tree without allocating a multi-gigabyte byte array.
$fs=New-Object -ComObject IMAPI2FS.MsftFileSystemImage
$fs.FileSystemsToCreate=3;$fs.VolumeName=$Label
# IMAPI otherwise assumes a 700-MB CD, too small for the reviewed IDE tarball.
$fs.FreeMediaBlocks=4194304
$fs.Root.AddTree($Directory,$false)
if(-not('PfFactoryImapi' -as [type])){
Add-Type -TypeDefinition @'
using System;using System.IO;using System.Runtime.InteropServices;using System.Runtime.InteropServices.ComTypes;
public static class PfFactoryImapi {
 public static void Save(object value,string path){
  IStream stream=(IStream)value; IntPtr read=Marshal.AllocHGlobal(4);
  try{using(FileStream output=new FileStream(path,FileMode.CreateNew,FileAccess.Write)){
   byte[] buffer=new byte[1048576];while(true){stream.Read(buffer,buffer.Length,read);int n=Marshal.ReadInt32(read);if(n==0)break;output.Write(buffer,0,n);}output.Flush(true);
  }}finally{Marshal.FreeHGlobal(read);}
 }
}
'@
}
$result=$fs.CreateResultImage()
[PfFactoryImapi]::Save($result.ImageStream,$Output)
Write-Output $Output
