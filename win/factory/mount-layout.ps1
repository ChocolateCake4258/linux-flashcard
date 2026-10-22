# Mount only this workspace's owned file-backed layout, never a physical USB.
param([Parameter(Mandatory=$true)][string]$Workspace,[switch]$Unmount)
$ErrorActionPreference='Stop'
$owner=Get-Content -LiteralPath (Join-Path $Workspace 'factory-state.json') -Raw -Encoding UTF8|ConvertFrom-Json
if($owner.schema -ne 1 -or $owner.workspace.TrimEnd('\') -ine $Workspace.TrimEnd('\')){throw 'Factory workspace ownership mismatch.'}
$image=Join-Path $Workspace 'working\usb-layout.vhd'
$bytes=if($owner.media_bytes){[long]$owner.media_bytes}else{31042043904L}
if((Get-Item -LiteralPath $image).Length -ne ($bytes+512)){throw 'Unexpected fixed factory layout size.'}
$active=@(Get-CimInstance Win32_Process|Where-Object{$_.Name -like 'qemu*' -and $_.CommandLine -and $_.CommandLine.IndexOf($Workspace,[StringComparison]::OrdinalIgnoreCase) -ge 0}).Count -gt 0
$existing=Get-DiskImage -ImagePath $image
if($Unmount){if($active){throw 'An owned factory QEMU/NBD is active.'};if($existing.Attached){$null=Dismount-DiskImage -ImagePath $image};return}
if($active -and -not $existing.Attached){throw 'Active factory QEMU prevents a new layout mount.'}
if(-not $existing.Attached){$null=Mount-DiskImage -ImagePath $image -Access ReadWrite -NoDriveLetter}
$disk=Get-DiskImage -ImagePath $image|Get-Disk
if($disk.BusType -notin 'File Backed Virtual','Virtual' -or $disk.Size -ne $bytes -or $disk.IsBoot -or $disk.IsSystem){throw 'Factory layout did not resolve to its expected virtual disk.'}
$part=Get-Partition -DiskNumber $disk.Number -PartitionNumber 1
$volume=$part|Get-Volume
if($volume.FileSystem -ne 'NTFS' -or $volume.FileSystemLabel -ne 'FLASHCARD'){throw 'Unexpected factory data partition.'}
$mount=Join-Path $Workspace 'mount'
$null=[IO.Directory]::CreateDirectory($mount)
$access=$mount.TrimEnd('\')+'\'
if($part.AccessPaths -notcontains $access){
    if($active){throw 'Cannot change layout access paths while its guest runs.'}
    if(@(Get-ChildItem -LiteralPath $mount -Force).Count){throw 'Refusing an occupied factory mount directory.'}
    $part|Add-PartitionAccessPath -AccessPath $access
}
Write-Output $access
