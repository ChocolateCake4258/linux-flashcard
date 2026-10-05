# Read-only inspection of a source RAW image, not a bootability test.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ImagePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$stream = $null
$tableLimit = 16MB

function Read-ImageBytes {
    param([decimal]$Offset, [int]$Count)
    if ($Offset -lt 0 -or $Count -lt 0 -or $Offset + $Count -gt $stream.Length) {
        throw "Read outside image: offset=$Offset count=$Count"
    }
    [void]$stream.Seek([long]$Offset, [System.IO.SeekOrigin]::Begin)
    $buffer = New-Object byte[] $Count
    $done = 0
    while ($done -lt $Count) {
        $read = $stream.Read($buffer, $done, $Count - $done)
        if ($read -eq 0) { throw 'Unexpected end of image.' }
        $done += $read
    }
    return ,$buffer
}

function Get-ClusterOffset {
    param($Volume, [uint32]$Cluster)
    if ($Cluster -lt 2 -or $Cluster -gt $Volume.MaxCluster) {
        throw "Invalid FAT32 cluster: $Cluster"
    }
    return [decimal]$Volume.DataOffset + ([decimal]$Cluster - 2) * $Volume.ClusterBytes
}

function Get-ClusterChain {
    param($Volume, [uint32]$Start, [long]$MaximumClusters = [long]::MaxValue)
    $visited = New-Object 'System.Collections.Generic.HashSet[uint32]'
    $cluster = $Start
    while ($true) {
        [void](Get-ClusterOffset $Volume $cluster)
        if (-not $visited.Add($cluster)) { throw "FAT32 chain loop at cluster $cluster" }
        if ($visited.Count -gt $Volume.ClusterCount -or $visited.Count -gt $MaximumClusters) {
            throw 'FAT32 chain exceeds inspection or volume bounds.'
        }
        $cluster
        $entry = Read-ImageBytes ($Volume.FatOffset + [decimal]$cluster * 4) 4
        $next = [System.BitConverter]::ToUInt32($entry, 0) -band 0x0FFFFFFF
        if ($next -ge 0x0FFFFFF8) { break }
        if ($next -lt 2 -or $next -eq 0x0FFFFFF7 -or $next -gt $Volume.MaxCluster) {
            throw "Invalid FAT32 chain link: $cluster -> $next"
        }
        $cluster = [uint32]$next
    }
}

function Get-DirectoryEntries {
    param($Volume, [uint32]$Start)
    $parts = @{}
    $expected = 0
    $checksum = -1
    $directoryBytes = 0L
    $directoryClusterLimit = [long][Math]::Floor(16MB / $Volume.ClusterBytes)
    foreach ($cluster in (Get-ClusterChain $Volume $Start $directoryClusterLimit)) {
        $directoryBytes += $Volume.ClusterBytes
        if ($directoryBytes -gt 16MB) { throw 'Directory exceeds the 16 MiB inspection limit.' }
        $data = Read-ImageBytes (Get-ClusterOffset $Volume $cluster) $Volume.ClusterBytes
        for ($offset = 0; $offset -lt $data.Length; $offset += 32) {
            $first = $data[$offset]
            if ($first -eq 0) { return }
            if ($first -eq 0xE5) { $parts.Clear(); $expected = 0; continue }
            $attributes = $data[$offset + 11]
            if ($attributes -eq 0x0F) {
                $ordinal = $first -band 0x1F
                if (($first -band 0x40) -ne 0) {
                    $parts.Clear()
                    $expected = $ordinal
                    $checksum = [int]$data[$offset + 13]
                }
                if ($ordinal -lt 1 -or $ordinal -gt 20 -or $ordinal -ne $expected -or
                    $data[$offset + 13] -ne $checksum -or $data[$offset + 12] -ne 0 -or
                    [System.BitConverter]::ToUInt16($data, $offset + 26) -ne 0) {
                    $parts.Clear(); $expected = 0; continue
                }
                $text = ''
                foreach ($position in @(1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30)) {
                    $character = [System.BitConverter]::ToUInt16($data, $offset + $position)
                    if ($character -eq 0 -or $character -eq 0xFFFF) { break }
                    $text += [char]$character
                }
                $parts[$ordinal] = $text
                $expected--
                continue
            }
            $shortBytes = New-Object byte[] 11
            [Array]::Copy($data, $offset, $shortBytes, 0, 11)
            $sum = 0
            foreach ($value in $shortBytes) {
                $sum = ((($sum -band 1) * 128) + ($sum -shr 1) + $value) -band 255
            }
            if ($shortBytes[0] -eq 0x05) { $shortBytes[0] = 0xE5 }
            $base = [System.Text.Encoding]::ASCII.GetString($shortBytes, 0, 8).TrimEnd(' ')
            $extension = [System.Text.Encoding]::ASCII.GetString($shortBytes, 8, 3).TrimEnd(' ')
            if (($data[$offset + 12] -band 8) -ne 0) { $base = $base.ToLowerInvariant() }
            if (($data[$offset + 12] -band 16) -ne 0) { $extension = $extension.ToLowerInvariant() }
            $shortName = $base
            if ($extension.Length -gt 0) { $shortName += '.' + $extension }
            $name = $shortName
            if ($parts.Count -gt 0 -and $expected -eq 0 -and $checksum -eq $sum) {
                $name = ''
                for ($i = 1; $i -le $parts.Count; $i++) { $name += $parts[$i] }
            }
            $parts.Clear(); $expected = 0
            if (($attributes -band 8) -ne 0 -or $shortName -eq '.' -or $shortName -eq '..') { continue }
            [pscustomobject]@{
                Name = $name
                ShortName = $shortName
                IsDirectory = (($attributes -band 16) -ne 0)
                Size = [System.BitConverter]::ToUInt32($data, $offset + 28)
                Cluster = [uint32](([uint32][System.BitConverter]::ToUInt16($data, $offset + 20) * 65536) +
                    [System.BitConverter]::ToUInt16($data, $offset + 26))
            }
        }
    }
}

function Find-Entry {
    param([object[]]$Entries, [string]$Name, [bool]$Directory)
    $matches = @($Entries | Where-Object {
        $_.IsDirectory -eq $Directory -and ($_.Name -ieq $Name -or $_.ShortName -ieq $Name)
    })
    if ($matches.Count -gt 1) { throw "Ambiguous directory entry: $Name" }
    if ($matches.Count -eq 1) { return $matches[0] }
    return $null
}

function Test-IdenticalFile {
    param($Volume, $Left, $Right)
    if ($Left.Size -ne $Right.Size) { return $false }
    if ($Left.Size -eq 0) { return $true }
    $leftChain = @(Get-ClusterChain $Volume $Left.Cluster)
    $rightChain = @(Get-ClusterChain $Volume $Right.Cluster)
    $needed = [long][Math]::Ceiling([double]$Left.Size / $Volume.ClusterBytes)
    if ($leftChain.Count -lt $needed -or $rightChain.Count -lt $needed) { throw 'File has a truncated FAT chain.' }
    $remaining = [long]$Left.Size
    for ($i = 0; $i -lt $needed; $i++) {
        $count = [int][Math]::Min($remaining, $Volume.ClusterBytes)
        $a = Read-ImageBytes (Get-ClusterOffset $Volume $leftChain[$i]) $count
        $b = Read-ImageBytes (Get-ClusterOffset $Volume $rightChain[$i]) $count
        for ($j = 0; $j -lt $count; $j++) {
            if ($a[$j] -ne $b[$j]) { return $false }
        }
        $remaining -= $count
    }
    return $true
}

try {
    if (-not [System.BitConverter]::IsLittleEndian) { throw 'This inspector requires a little-endian host.' }
    $resolvedPath = (Resolve-Path -LiteralPath $ImagePath).ProviderPath
    # Read sharing only: never permit this inspector to write or modify the source.
    $stream = [System.IO.FileStream]::new($resolvedPath, [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $mbr = Read-ImageBytes 0 512
    $bootCodeNonzero = $false
    for ($i = 0; $i -lt 440; $i++) {
        if ($mbr[$i] -ne 0) { $bootCodeNonzero = $true; break }
    }
    $header = Read-ImageBytes 512 512
    if ([System.Text.Encoding]::ASCII.GetString($header, 0, 8) -ne 'EFI PART') { throw 'No primary GPT signature at offset 512.' }
    $headerSize = [System.BitConverter]::ToUInt32($header, 12)
    if ($headerSize -lt 92 -or $headerSize -gt 512 -or [System.BitConverter]::ToUInt64($header, 24) -ne 1) {
        throw 'Invalid primary GPT header.'
    }
    $tableLba = [System.BitConverter]::ToUInt64($header, 72)
    $entryCount = [System.BitConverter]::ToUInt32($header, 80)
    $entrySize = [System.BitConverter]::ToUInt32($header, 84)
    $tableBytes = [decimal]$entryCount * $entrySize
    if ($entryCount -eq 0 -or $entrySize -lt 128 -or ($entrySize % 128) -ne 0 -or
        $tableBytes -gt $tableLimit -or $tableLba -lt 2) { throw 'Invalid or oversized GPT partition table (limit 16 MiB).' }
    $table = Read-ImageBytes ([decimal]$tableLba * 512) ([int]$tableBytes)
    $espType = [guid]'c12a7328-f81f-11d2-ba4b-00a0c93ec93b'
    $reports = @()
    for ($index = 0; $index -lt $entryCount; $index++) {
        $entryOffset = [int]($index * $entrySize)
        $typeBytes = New-Object byte[] 16
        [Array]::Copy($table, $entryOffset, $typeBytes, 0, 16)
        if ([guid]::new($typeBytes) -ne $espType) { continue }
        [uint64]$firstLba = [System.BitConverter]::ToUInt64($table, $entryOffset + 32)
        [uint64]$lastLba = [System.BitConverter]::ToUInt64($table, $entryOffset + 40)
        $partitionOffset = [decimal]$firstLba * 512
        $partitionBytes = ([decimal]$lastLba - $firstLba + 1) * 512
        if ($firstLba -lt 2 -or $lastLba -lt $firstLba -or $partitionOffset + $partitionBytes -gt $stream.Length) {
            throw "ESP partition $($index + 1) lies outside the image."
        }
        $bpb = Read-ImageBytes $partitionOffset 512
        $sectorBytes = [System.BitConverter]::ToUInt16($bpb, 11)
        $sectorsPerCluster = [int]$bpb[13]
        $reserved = [System.BitConverter]::ToUInt16($bpb, 14)
        $fatCount = [int]$bpb[16]
        $fatSectors = [System.BitConverter]::ToUInt32($bpb, 36)
        $rootCluster = [System.BitConverter]::ToUInt32($bpb, 44) -band 0x0FFFFFFF
        $totalSectors = [System.BitConverter]::ToUInt32($bpb, 32)
        $flags = [System.BitConverter]::ToUInt16($bpb, 40)
        if ($sectorBytes -notin @(512, 1024, 2048, 4096) -or $sectorsPerCluster -lt 1 -or
            $sectorsPerCluster -gt 128 -or ($sectorsPerCluster -band ($sectorsPerCluster - 1)) -ne 0 -or
            $reserved -eq 0 -or $fatCount -eq 0 -or $fatSectors -eq 0 -or
            [System.BitConverter]::ToUInt16($bpb, 17) -ne 0 -or
            [System.BitConverter]::ToUInt16($bpb, 22) -ne 0 -or
            [System.BitConverter]::ToUInt16($bpb, 42) -ne 0 -or $bpb[510] -ne 0x55 -or $bpb[511] -ne 0xAA) {
            throw "Invalid or unsupported FAT32 BPB in ESP $($index + 1)."
        }
        $dataSector = [decimal]$reserved + [decimal]$fatCount * $fatSectors
        $clusterCount = [long][Math]::Floor(([decimal]$totalSectors - $dataSector) / $sectorsPerCluster)
        if ($totalSectors * [decimal]$sectorBytes -gt $partitionBytes -or $clusterCount -lt 1 -or
            $clusterCount -gt 0x0FFFFFEE -or ([decimal]$clusterCount + 2) * 4 -gt [decimal]$fatSectors * $sectorBytes) {
            throw 'FAT32 geometry exceeds partition or FAT bounds.'
        }
        $activeFat = 0
        if (($flags -band 0x80) -ne 0) { $activeFat = $flags -band 0x0F }
        if ($activeFat -ge $fatCount) { throw 'Invalid active FAT index.' }
        $volume = [pscustomobject]@{
            FatOffset = $partitionOffset + ([decimal]$reserved + [decimal]$activeFat * $fatSectors) * $sectorBytes
            DataOffset = $partitionOffset + $dataSector * $sectorBytes
            ClusterBytes = [int]($sectorBytes * $sectorsPerCluster)
            ClusterCount = $clusterCount
            MaxCluster = [uint32]($clusterCount + 1)
        }
        $root = @(Get-DirectoryEntries $volume $rootCluster)
        $efiEntry = Find-Entry $root 'EFI' $true
        $efi = @()
        if ($null -ne $efiEntry) { $efi = @(Get-DirectoryEntries $volume $efiEntry.Cluster) }
        $bootEntry = Find-Entry $efi 'BOOT' $true
        $ubuntuEntry = Find-Entry $efi 'ubuntu' $true
        $boot = @(); $ubuntu = @()
        if ($null -ne $bootEntry) { $boot = @(Get-DirectoryEntries $volume $bootEntry.Cluster) }
        if ($null -ne $ubuntuEntry) { $ubuntu = @(Get-DirectoryEntries $volume $ubuntuEntry.Cluster) }
        $directories = [ordered]@{ '/' = $root; '/EFI' = $efi; '/EFI/BOOT' = $boot; '/EFI/ubuntu' = $ubuntu }
        $listing = @()
        $shims = @()
        foreach ($path in $directories.Keys) {
            foreach ($item in $directories[$path]) {
                $fullPath = $path.TrimEnd('/') + '/' + $item.Name
                $listing += [pscustomobject]@{ Path = $fullPath; ShortName = $item.ShortName; Size = $item.Size; IsDirectory = $item.IsDirectory }
                if (-not $item.IsDirectory -and ($item.Name -ieq 'shimx64.efi' -or $item.ShortName -ieq 'shimx64.efi')) {
                    $shims += [pscustomobject]@{ Path = $fullPath; Entry = $item }
                }
            }
        }
        $missing = @()
        foreach ($name in @('BOOTX64.EFI', 'grubx64.efi', 'mmx64.efi', 'grub.cfg')) {
            $file = Find-Entry $boot $name $false
            if ($null -eq $file -or $file.Size -eq 0) { $missing += $name }
        }
        $bootx64 = Find-Entry $boot 'BOOTX64.EFI' $false
        $identicalShims = @()
        if ($null -ne $bootx64 -and $bootx64.Size -gt 0) {
            foreach ($shim in $shims) {
                if (Test-IdenticalFile $volume $bootx64 $shim.Entry) { $identicalShims += $shim.Path }
            }
        }
        $adjacentGrub = Find-Entry $boot 'grubx64.efi' $false
        $adjacentGrubPresent = ($null -ne $adjacentGrub -and $adjacentGrub.Size -gt 0)
        $reports += [pscustomobject]@{
            PartitionIndex = $index + 1
            FirstLba = $firstLba
            LastLba = $lastLba
            Fat32 = [pscustomobject]@{ BytesPerSector = $sectorBytes; SectorsPerCluster = $sectorsPerCluster; ReservedSectors = $reserved; FatCount = $fatCount; FatSectors = $fatSectors; ActiveFat = $activeFat; RootCluster = $rootCluster }
            Entries = $listing
            ShimPresent = ($shims.Count -gt 0)
            ShimPaths = @($shims | ForEach-Object { $_.Path })
            Fallback = [pscustomobject]@{
                RequiredFiles = @('BOOTX64.EFI', 'grubx64.efi', 'mmx64.efi', 'grub.cfg')
                MissingOrEmpty = $missing
                Complete = ($missing.Count -eq 0)
                BootX64ByteIdenticalShimPaths = $identicalShims
                AdjacentGrubRequiredByKnownShim = ($identicalShims.Count -gt 0)
                AdjacentGrubPresent = $adjacentGrubPresent
                KnownShimAdjacencySatisfied = $(if ($identicalShims.Count -gt 0) { $adjacentGrubPresent } else { $null })
            }
        }
    }
    [pscustomobject]@{
        ImagePath = $resolvedPath
        ImageBytes = $stream.Length
        MbrInitial440BootCode = $(if ($bootCodeNonzero) { 'nonzero' } else { 'allzero' })
        EspCount = $reports.Count
        EspPartitions = $reports
        Limitations = @(
            'Read-only source-image inspection; no claim of BIOS or UEFI bootability.'
            'GPT CRCs, backup GPT, FAT mirror agreement, signatures, executable validity and grub.cfg contents are not verified.'
            'Fallback completeness means the four listed files exist and are nonempty, not that their contents or boot chain are valid.'
            'Shim identity is checked only against shimx64.efi in the listed directories; without a byte-identical match no exact shim chain is asserted.'
            'Directory inspection is limited to root, EFI, EFI/BOOT and EFI/ubuntu; each directory is limited to 16 MiB. Short names use ASCII; valid LFN names use UTF-16.'
        )
    } | ConvertTo-Json -Depth 10
}
finally {
    if ($null -ne $stream) { $stream.Dispose() }
}
