param([Parameter(Mandatory = $true)][string]$Scenario)
$ErrorActionPreference = 'Stop'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('pf-writer-test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temp
$global:TestImage = Join-Path $temp 'image.img'
$fakeDiskFile = Join-Path $temp 'fake-disk.bin'
$baselineFile = Join-Path $temp 'baseline.img'
$win = Split-Path $PSScriptRoot -Parent
function Require($Condition, $Message) { if (-not $Condition) { throw $Message } }
try {
    # These types deliberately have no P/Invoke declarations. Real module wrappers
    # use their API unchanged; physical drive names can only reach this temp file.
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Collections.Generic;
public static class TestGpt {
    // Independent fixture checksum implementation; never calls production code.
    public static uint Crc(byte[] bytes, int offset, int count) {
        uint crc = 0xffffffffu;
        for (int i = offset; i < offset + count; i++) {
            crc ^= bytes[i];
            for (int bit = 0; bit < 8; bit++)
                crc = (crc >> 1) ^ ((crc & 1) != 0 ? 0xedb88320u : 0u);
        }
        return ~crc;
    }
    public static void HeaderCrc(byte[] bytes, int offset) {
        Array.Clear(bytes, offset + 16, 4);
        BitConverter.GetBytes(Crc(bytes, offset, 92)).CopyTo(bytes, offset + 16);
    }
    public static byte[] Relocate(byte[] image, int offset, long imageBytes, long diskBytes, bool backup) {
        byte[] header = new byte[512];
        Array.Copy(image, offset, header, 0, 512);
        ulong delta = (ulong)((diskBytes - imageBytes) / 512);
        ulong last = (ulong)(diskBytes / 512 - 1);
        if (backup) {
            BitConverter.GetBytes(last).CopyTo(header, 24);
            BitConverter.GetBytes(BitConverter.ToUInt64(header, 72) + delta).CopyTo(header, 72);
        } else {
            BitConverter.GetBytes(last).CopyTo(header, 32);
        }
        BitConverter.GetBytes(BitConverter.ToUInt64(header, 48) + delta).CopyTo(header, 48);
        HeaderCrc(header, 0);
        return header;
    }
}
public static class TestState {
    public static string DiskPath, Scenario;
    public static int Partitions = 2, Deletes, Refreshes, Writes, Reads, Unlocks;
    public static long Written, DiskBytes = 16777216, ReadBytes;
    public static bool Changed;
    public static bool DeferredRescan;
    public static List<string> Events = new List<string>();
    public static List<TestHandle> Handles = new List<TestHandle>();
}
public class TestHandle : IDisposable {
    public FileStream Stream;
    public string Kind;
    public bool Disposed;
    public TestHandle(string kind, FileStream stream) {
        Kind = kind; Stream = stream; TestState.Handles.Add(this);
        TestState.Events.Add("open-" + kind);
    }
    public void Dispose() {
        if (Stream != null) Stream.Dispose();
        Disposed = true; TestState.Events.Add("dispose-" + Kind);
    }
}
public static class PfRawDisk {
    public static TestHandle Open(string path, bool write) {
        if (path != @"\\.\PhysicalDrive7") throw new Exception("Unexpected disk path");
        if (!write && TestState.Scenario == "baseline-read-failure") throw new IOException("Injected current read open failure");
        return new TestHandle(write ? "write" : "read", new FileStream(
            TestState.DiskPath, FileMode.Open, write ? FileAccess.Write : FileAccess.Read, FileShare.ReadWrite));
    }
    public static void Write(TestHandle h, byte[] bytes, int count) {
        TestState.Writes++;
        if (TestState.Scenario == "write-failure") throw new IOException("Injected write failure");
        if (TestState.Scenario == "short-write") {
            h.Stream.Write(bytes, 0, count - 1);
            TestState.Written += count - 1;
            throw new IOException("Injected short write");
        }
        h.Stream.Write(bytes, 0, count);
        TestState.Written += count;
    }
    public static void WriteAt(TestHandle h, byte[] bytes, int count, long offset) {
        TestState.Events.Add("write-at:" + offset + ":" + count);
        if (TestState.Scenario == "deferred-body-failure") throw new IOException("Injected deferred body failure");
        if (TestState.Scenario == "deferred-final-rescan" && count == 1048576 && offset > 0 && !TestState.DeferredRescan) {
            TestState.DeferredRescan = true;
            throw new System.ComponentModel.Win32Exception(433, "Injected GPT rescan");
        }
        h.Stream.Position = offset;
        Write(h, bytes, count);
    }
    public static uint Read(TestHandle h, byte[] bytes, long offset) {
        TestState.Reads++; TestState.Events.Add("read");
        h.Stream.Position = offset;
        int n = h.Stream.Read(bytes, 0, bytes.Length);
        if (TestState.Scenario == "short-read" || TestState.Scenario == "baseline-short-read") return (uint)(n - 1);
        if (TestState.Scenario == "corrupt-read") bytes[123] ^= 1;
        if (TestState.Scenario == "deferred-publish-body-corrupt" && offset >= 1048576) bytes[123] ^= 1;
        if (TestState.Scenario == "deferred-publish-boot-corrupt" && offset == 0) bytes[123] ^= 1;
        if (TestState.Scenario == "deferred-publish-identity-changed") TestState.Changed = true;
        if (TestState.Scenario == "deferred-publish-short-read" && TestState.Written > 0) return (uint)(n - 1);
        TestState.ReadBytes += n;
        return (uint)n;
    }
    public static void Flush(TestHandle h) { h.Stream.Flush(); }
    public static int DeleteLayout(string path) {
        TestState.Deletes++; TestState.Events.Add("delete");
        if (TestState.Scenario != "deferred-clean-fallback") TestState.Partitions = 0;
        return 0;
    }
    public static void Refresh(string path) {
        TestState.Refreshes++; TestState.Events.Add("refresh");
        if (TestState.Scenario.StartsWith("deferred")) TestState.Partitions = 2;
        if (TestState.Scenario == "refresh-failure" || TestState.Scenario == "deferred-publish-refresh-failure") throw new IOException("Injected refresh failure");
        if (TestState.Scenario == "deferred-publish-mounted") {
            using (var disk = new FileStream(TestState.DiskPath, FileMode.Open, FileAccess.Write, FileShare.ReadWrite)) {
                disk.Position = 5242880; disk.WriteByte(0x91); // Simulated post-mount filesystem metadata.
            }
        }
    }
}
public static class PfVolume {
    public static TestHandle OpenVolume(string path) {
        TestState.Events.Add("volume-path:" + path);
        return new TestHandle("volume", null);
    }
    public static void LockAndDismount(TestHandle h) {
        TestState.Events.Add("lock");
        if (TestState.Scenario.StartsWith("deferred-publish") && TestState.Partitions > 0) throw new IOException("Injected mounted FAT lock failure");
        if ((TestState.Scenario == "lock-failure" || TestState.Scenario == "baseline-lock-failure" || TestState.Scenario == "identity-changed") &&
            TestState.Handles.FindAll(x => x.Kind == "volume").Count == 2) {
            if (TestState.Scenario == "identity-changed") TestState.Changed = true;
            throw new IOException("Injected lock failure");
        }
    }
    public static void Unlock(TestHandle h) { TestState.Unlocks++; TestState.Events.Add("unlock"); }
}
'@
    [TestState]::DiskPath = $fakeDiskFile
    [TestState]::Scenario = $Scenario
    $isRelocation = $Scenario -like 'gpt-relocation*'
    $isBaseline = $Scenario -like 'baseline-*'
    $isDeferred = $Scenario -like 'deferred*'
    $isBeforePublish=$Scenario -like 'deferred-publish*'
    $isReadOnlyScenario = $isRelocation -or $Scenario -in 'verify-only', 'verify-only-corrupt'
    if ($Scenario -in 'windows-volume-selection', 'linux-driver-volume') { [TestState]::Partitions = 3 }
    Require ([TestGpt]::Crc([Text.Encoding]::ASCII.GetBytes('123456789'), 0, 9) -eq [Convert]::ToUInt32('CBF43926', 16)) 'Fixture CRC implementation failed known vector'
    $length = 8MB + 512
    if ($Scenario -eq 'small') { $length = 8MB - 512 }
    if ($Scenario -eq 'unaligned') { $length++ }
    $bytes = New-Object byte[] $length
    $bytes[510] = 0x55; $bytes[511] = 0xaa
    [Text.Encoding]::ASCII.GetBytes('EFI PART').CopyTo($bytes, 512)
    $fixtureLastSector = [uint64]([Math]::Floor($length / 512) - 1)
    [BitConverter]::GetBytes([uint32]92).CopyTo($bytes, 524)
    [BitConverter]::GetBytes([uint64]1).CopyTo($bytes, 536)
    [BitConverter]::GetBytes($fixtureLastSector).CopyTo($bytes, 544)
    $backupOffset = $length - 512
    [Text.Encoding]::ASCII.GetBytes('EFI PART').CopyTo($bytes, $backupOffset)
    [BitConverter]::GetBytes([uint32]92).CopyTo($bytes, ($backupOffset + 12))
    [BitConverter]::GetBytes($fixtureLastSector).CopyTo($bytes, ($backupOffset + 24))
    [BitConverter]::GetBytes([uint64]1).CopyTo($bytes, ($backupOffset + 32))
    $backupTableOffset = [int](($fixtureLastSector - 1) * 512)
    $diskGuid = [guid]'01234567-89ab-cdef-0123-456789abcdef'
    foreach ($headerOffset in @(512, $backupOffset)) {
        [BitConverter]::GetBytes([uint32]0x10000).CopyTo($bytes, ($headerOffset + 8))
        [BitConverter]::GetBytes([uint64]3).CopyTo($bytes, ($headerOffset + 40))
        [BitConverter]::GetBytes([uint64]($fixtureLastSector - 2)).CopyTo($bytes, ($headerOffset + 48))
        $diskGuid.ToByteArray().CopyTo($bytes, ($headerOffset + 56))
        $tableLba = if ($headerOffset -eq 512) { [uint64]2 } else { [uint64]($fixtureLastSector - 1) }
        [BitConverter]::GetBytes($tableLba).CopyTo($bytes, ($headerOffset + 72))
        [BitConverter]::GetBytes([uint32]4).CopyTo($bytes, ($headerOffset + 80))
        [BitConverter]::GetBytes([uint32]128).CopyTo($bytes, ($headerOffset + 84))
    }
    # One basic-data partition and three unused entries, identical in both tables.
    ([guid]'ebd0a0a2-b9e5-4433-87c0-68b6b72699c7').ToByteArray().CopyTo($bytes, 1024)
    ([guid]'76543210-fedc-ba98-7654-3210fedcba98').ToByteArray().CopyTo($bytes, 1040)
    [BitConverter]::GetBytes([uint64]3).CopyTo($bytes, 1056)
    [BitConverter]::GetBytes([uint64]($fixtureLastSector - 2)).CopyTo($bytes, 1064)
    [Array]::Copy($bytes, 1024, $bytes, $backupTableOffset, 512)
    # Nonzero data at chunk and sample boundaries catches truncated/empty writes.
    foreach ($offset in @((4MB - 1), 4MB, ($length - 1))) { $bytes[$offset] = 0x73 }
    $tableCrc = [TestGpt]::Crc($bytes, 1024, 512)
    foreach ($headerOffset in @(512, $backupOffset)) {
        [BitConverter]::GetBytes($tableCrc).CopyTo($bytes, ($headerOffset + 88))
        [TestGpt]::HeaderCrc($bytes, $headerOffset)
    }
    if ($Scenario -eq 'table-bounds') {
        [BitConverter]::GetBytes($fixtureLastSector).CopyTo($bytes, 584)
        [TestGpt]::HeaderCrc($bytes, 512)
    }
    if ($Scenario -eq 'primary-header-crc') { $bytes[528] = $bytes[528] -bxor 1 }
    if ($Scenario -eq 'backup-header-crc') { $bytes[$backupOffset + 16] = $bytes[$backupOffset + 16] -bxor 1 }
    if ($Scenario -eq 'table-crc') { $bytes[1024] = $bytes[1024] -bxor 1 }
    if ($Scenario -eq 'backup-table-crc') { $bytes[$backupTableOffset] = $bytes[$backupTableOffset] -bxor 1 }
    if ($Scenario -eq 'bad-mbr') { $bytes[510] = 0 }
    if ($Scenario -eq 'bad-gpt') { $bytes[512] = 0 }
    if ($Scenario -eq 'truncated-gpt') { [BitConverter]::GetBytes([uint64]($fixtureLastSector + 1)).CopyTo($bytes, 544) }
    if ($Scenario -eq 'missing-backup') { [Array]::Clear($bytes, $backupOffset, 512) }
    [IO.File]::WriteAllBytes($global:TestImage, $bytes)
    if($isBeforePublish -and $Scenario -ne 'deferred-publish-size-mismatch'){[TestState]::DiskBytes=$length}
    $initialDisk = New-Object byte[] ([TestState]::DiskBytes)
    if($initialDisk.Length -gt $bytes.Length){$initialDisk[$bytes.Length] = 0x4a}
    if ($isReadOnlyScenario) {
        [Array]::Copy($bytes, $initialDisk, $bytes.Length)
        if ($Scenario -eq 'verify-only-corrupt') { $initialDisk[123] = $initialDisk[123] -bxor 1 }
    }
    if ($isRelocation) {
        # Seed canonical relocation independently, retaining the original backup
        # and table at image EOF as well as the new copies at physical disk EOF.
        $fixturePrimary = [TestGpt]::Relocate($bytes, 512, $bytes.Length, $initialDisk.Length, $false)
        $fixtureBackup = [TestGpt]::Relocate($bytes, $backupOffset, $bytes.Length, $initialDisk.Length, $true)
        $physicalBackupOffset = $initialDisk.Length - 512
        $physicalTableOffset = $initialDisk.Length - 1024
        $fixturePrimary.CopyTo($initialDisk, 512)
        $fixtureBackup.CopyTo($initialDisk, $physicalBackupOffset)
        [Array]::Copy($bytes, $backupTableOffset, $initialDisk, $physicalTableOffset, 512)
        if ($Scenario -eq 'gpt-relocation-primary-corrupt') {
            $initialDisk[568] = $initialDisk[568] -bxor 1
            [TestGpt]::HeaderCrc($initialDisk, 512)
        }
        if ($Scenario -eq 'gpt-relocation-backup-corrupt') {
            $initialDisk[$physicalBackupOffset + 56] = $initialDisk[$physicalBackupOffset + 56] -bxor 1
            [TestGpt]::HeaderCrc($initialDisk, $physicalBackupOffset)
        }
        if ($Scenario -eq 'gpt-relocation-table-corrupt') { $initialDisk[$physicalTableOffset] = $initialDisk[$physicalTableOffset] -bxor 1 }
        if ($Scenario -eq 'gpt-relocation-data-corrupt') { $initialDisk[5MB] = $initialDisk[5MB] -bxor 1 }
        Require ([Convert]::ToBase64String($initialDisk, $backupOffset, 512) -ceq [Convert]::ToBase64String($bytes, $backupOffset, 512)) 'Fixture changed the original backup header'
    }
    [IO.File]::WriteAllBytes($fakeDiskFile, $initialDisk)
    if ($isBaseline) {
        [IO.File]::WriteAllBytes($baselineFile, $initialDisk)
        if ($Scenario -eq 'baseline-mismatch') {
            # Outside the new image, in the final chunk of the full-disk baseline.
            $initialDisk[$initialDisk.Length - 1] = 0x5b
            [IO.File]::WriteAllBytes($fakeDiskFile, $initialDisk)
        }
        if ($Scenario -eq 'baseline-wronglength') { [IO.File]::WriteAllBytes($baselineFile, $bytes) }
    }
    if ($Scenario -in 'checksum', 'bad-sidecar') {
        $sidecar = if ($Scenario -eq 'checksum') { '0' * 64 } else { 'invalid' }
        [IO.File]::WriteAllText($global:TestImage + '.sha256', $sidecar)
    }
    if ($Scenario -eq 'valid-checksum' -or $isBeforePublish) {
        $checksum = (Get-FileHash -LiteralPath $global:TestImage -Algorithm SHA256).Hash
        [IO.File]::WriteAllText($global:TestImage + '.sha256', $checksum)
    }
    Import-Module (Join-Path $win 'lib/pf-tools.psm1') -Force -WarningAction SilentlyContinue
    $module = Get-Module pf-tools
    & $module {
        function script:Test-PfIsAdmin { $true }
        function script:Get-Disk {
            param($Number)
            [pscustomobject]@{
                Number = 7; Path = $(if ([TestState]::Changed) { 'changed-device' } else { 'test-device' })
                SerialNumber = 'serial'; Size = [TestState]::DiskBytes; BusType = 'USB'; LogicalSectorSize = 512
                IsBoot = ([TestState]::Scenario -eq 'boot'); IsSystem = $false
                IsReadOnly = $false; IsOffline = $false; NumberOfPartitions = [TestState]::Partitions
            }
        }
        function script:Get-Partition {
            param($DiskNumber, $PartitionNumber, $DriveLetter)
            if ($DriveLetter) { return [pscustomobject]@{ DiskNumber = 7; PartitionNumber = 1 } }
            for ($i = 1; $i -le [TestState]::Partitions; $i++) {
                if ([TestState]::Scenario -in 'windows-volume-selection', 'linux-driver-volume') {
                    $types = @('21686148-6449-6e6f-744e-656564454649', 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b', '0fc63daf-8483-4772-8e79-3d69d8477de4')
                    [pscustomobject]@{ DiskNumber = 7; PartitionNumber = $i; DriveLetter = @('B', 'E', 'L')[$i - 1]; GptType = $types[$i - 1] }
                    continue
                }
                [pscustomobject]@{ DiskNumber = 7; PartitionNumber = $i; DriveLetter = $(if ($i -eq 1) { 'D' } else { 'E' }) }
            }
        }
        function script:Get-Volume {
            [CmdletBinding()]
            param([Parameter(Mandatory = $true, ValueFromPipeline = $true)]$Partition)
            process {
                [TestState]::Events.Add("query-volume:$($Partition.PartitionNumber)")
                $filesystem = ''
                if ($Partition.PartitionNumber -eq 2) { $filesystem = 'FAT32' }
                if ($Partition.PartitionNumber -eq 3 -and [TestState]::Scenario -eq 'linux-driver-volume') { $filesystem = 'EXT4' }
                [pscustomobject]@{ FileSystem = $filesystem }
            }
        }
        function script:Update-HostStorageCache { }
        function script:diskpart.exe {
            param([Parameter(ValueFromRemainingArguments = $true)]$Arguments)
            if ([TestState]::Scenario -ne 'deferred-clean-fallback') { throw 'Unexpected diskpart call in harness.' }
            [TestState]::Events.Add('diskpart-clean')
            [TestState]::Partitions = 0
            $global:LASTEXITCODE = 0
        }
        function script:Get-PfDiskReport { 'fake disk' }
        function script:Write-PfRawBytes {
            param($Handle, [byte[]]$Bytes, [int]$Count)
            if (-not $global:src.CanRead) { throw 'Source closed before write' }
            if ([TestState]::Scenario -like 'baseline-*') {
                if (-not $global:currentImage.CanRead -or $global:currentImage.CanWrite) { throw 'Baseline not held read-only during write' }
                if ([TestState]::Reads -ne 4) { throw 'Baseline did not read the entire disk before writing' }
                if (@([TestState]::Handles | Where-Object { $_.Kind -eq 'read' -and -not $_.Disposed }).Count) { throw 'Current read handle still open during write' }
            }
            [PfRawDisk]::Write($Handle, $Bytes, $Count)
        }
        function script:Read-PfRawBytes {
            param($Handle, [byte[]]$Bytes, [long]$Offset)
            if (-not $global:src.CanRead) { throw 'Source closed before verification' }
            if ([TestState]::Scenario -like 'baseline-*' -and -not $global:currentImage.CanRead) { throw 'Baseline closed before verification' }
            [int][PfRawDisk]::Read($Handle, $Bytes, $Offset)
        }
    }
    function Get-CimInstance { param($ClassName) [pscustomobject]@{ InterfaceType = 'USB'; Index = 7; Model = 'test'; Size = [TestState]::DiskBytes } }
    function Test-PfIsAdmin { $true }
    function Write-PfRawBytes {
        param($Handle, [byte[]]$Bytes, [int]$Count)
        & $module { param($h, $b, $n) Write-PfRawBytes -Handle $h -Bytes $b -Count $n } $Handle $Bytes $Count
    }
    function Read-PfRawBytes {
        param($Handle, [byte[]]$Bytes, [long]$Offset)
        & $module { param($h, $b, $o) Read-PfRawBytes -Handle $h -Bytes $b -Offset $o } $Handle $Bytes $Offset
    }
    function Get-Disk { param($Number) & $module { Get-Disk -Number 7 } }
    function Get-Partition {
        param($DriveLetter)
        [pscustomobject]@{ DiskNumber = $(if ($Scenario -in 'source-target', 'baseline-source-target') { 7 } else { 0 }); PartitionNumber = 1 }
    }
    function Update-HostStorageCache { }
    function Start-Transcript { }
    function Stop-Transcript { }
    $global:WriterMessages = [Collections.Generic.List[string]]::new()
    function Write-Host { param($Object, $ForegroundColor) $global:WriterMessages.Add([string]$Object) }
    function Write-PfHeader { param($Title) }
    function Start-Sleep { param($Seconds) }
    # AST edits remove import/exit, supply the original file's script root, and
    # expose the source variable for lifetime assertions. Control flow is intact.
    $writer = Join-Path $win 'write-image.ps1'
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($writer, [ref]$tokens, [ref]$errors)
    Require ($errors.Count -eq 0) 'Writer parse failed'
    $text = [IO.File]::ReadAllText($writer)
    $edits = @($ast.FindAll({ param($n)
        $n -is [Management.Automation.Language.ExitStatementAst] -or
        ($n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Import-Module')
    }, $true) | ForEach-Object {
        $replacement = if ($_ -is [Management.Automation.Language.ExitStatementAst]) { '$global:WriterExit = ' + $_.Pipeline.Extent.Text } else { '' }
        [pscustomobject]@{ Start = $_.Extent.StartOffset; Length = $_.Extent.EndOffset - $_.Extent.StartOffset; Text = $replacement }
    })
    $edits += @($ast.FindAll({ param($n)
        $n -is [Management.Automation.Language.VariableExpressionAst] -and
        $n.VariablePath.UserPath -in 'PSScriptRoot', 'src', 'currentImage'
    }, $true) | Where-Object {
        $node = $_
        @($edits | Where-Object { $node.Extent.StartOffset -ge $_.Start -and $node.Extent.EndOffset -le ($_.Start + $_.Length) }).Count -eq 0
    } | ForEach-Object {
        $replacement = if ($_.VariablePath.UserPath -in 'src', 'currentImage') { '$global:' + $_.VariablePath.UserPath } else { "'" + $win.Replace("'", "''") + "'" }
        [pscustomobject]@{ Start = $_.Extent.StartOffset; Length = $_.Extent.EndOffset - $_.Extent.StartOffset; Text = $replacement }
    })
    if ($Scenario -in 'source-target', 'baseline-source-target') {
        $roots = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Extent.Text -eq '[IO.Path]::GetPathRoot($path)' }, $true))
        Require ($roots.Count -eq 1) 'Cannot find source path-root check'
        $rootText = if ($Scenario -eq 'baseline-source-target') { "`$(if (`$path -eq `$ExpectedCurrentImagePath) { 'C:\' } else { '/' })" } else { "'C:\'" }
        $edits += [pscustomobject]@{ Start = $roots[0].Extent.StartOffset; Length = $roots[0].Extent.EndOffset - $roots[0].Extent.StartOffset; Text = $rootText }
    }
    foreach ($edit in ($edits | Sort-Object Start -Descending)) { $text = $text.Remove($edit.Start, $edit.Length).Insert($edit.Start, $edit.Text) }
    $arguments = @{ ImagePath = $global:TestImage; DiskNumber = 7; Yes = $true; ExpectedDevicePath = 'test-device'; ExpectedSerialNumber = 'serial'; ExpectedSize = [TestState]::DiskBytes; VerifyFull = ($Scenario -eq 'full' -or $isReadOnlyScenario) }
    if ($isReadOnlyScenario) { $arguments.VerifyOnly = $true }
    if ($isBaseline) { $arguments.ExpectedCurrentImagePath = $baselineFile }
    if ($isRelocation) { $arguments.AllowGptRelocation = $true }
    if ($Scenario -eq 'missing-identity') { $arguments.Remove('ExpectedDevicePath') }
    if ($isDeferred) { $arguments.DeferPartitionTable = $true; $arguments.VerifyFull = $true }
    if($isBeforePublish){$arguments.VerifyBeforePublish=$true;$arguments.ResultPath=Join-Path $temp 'writer-result.json'}
    if ($Scenario -eq 'deferred-guard-rejected') { $arguments.ExpectedCurrentImagePath = 'does-not-exist' }
    if ($Scenario -eq 'deferred-verify-rejected') { $arguments.VerifyOnly = $true }
    $global:WriterExit = -99
    . ([scriptblock]::Create($text)) @arguments
    $expected = if ($Scenario -in 'success', 'full', 'valid-checksum', 'verify-only', 'gpt-relocation', 'lock-failure', 'windows-volume-selection', 'linux-driver-volume', 'baseline-match', 'deferred', 'deferred-final-rescan', 'deferred-clean-fallback', 'deferred-publish', 'deferred-publish-mounted') { 0 } else { 1 }
    Require ($global:WriterExit -eq $expected) "Expected writer exit $expected, got $global:WriterExit. $($global:WriterMessages -join '; ')"
    $reasons = @{
        'bad-mbr' = 'Expected a complete GPT'; 'bad-gpt' = 'Expected a complete GPT'
        'truncated-gpt' = 'GPT header does not describe this image size'
        'missing-backup' = 'Backup GPT header is missing or inconsistent'
        'primary-header-crc' = 'GPT header CRC32 mismatch'; 'backup-header-crc' = 'GPT header CRC32 mismatch'
        'table-crc' = 'GPT partition table CRC32 mismatch'; 'backup-table-crc' = 'GPT partition table CRC32 mismatch'
        'table-bounds' = 'Invalid or unsupported GPT partition table bounds'
        'small' = 'at least 8 MB and sector-aligned'; 'unaligned' = 'at least 8 MB and sector-aligned'
        'checksum' = 'SHA256 does not match'; 'bad-sidecar' = 'Invalid SHA256 sidecar'
        'missing-identity' = '-Yes requires the device identity'; 'boot' = 'boot/system or non-USB'
        'source-target' = 'source image or running project'; 'identity-changed' = 'identity changed'
        'write-failure' = 'Injected write failure'; 'short-write' = 'Injected short write'; 'short-read' = 'Read-back mismatch'
        'corrupt-read' = 'Read-back mismatch'; 'refresh-failure' = 'Injected refresh failure'
        'verify-only-corrupt' = 'Read-back mismatch at byte 0'
        'gpt-relocation-primary-corrupt' = 'Primary GPT differs beyond the exact expected relocation'
        'gpt-relocation-backup-corrupt' = 'Relocated backup GPT header is inconsistent'
        'gpt-relocation-table-corrupt' = 'Relocated backup partition table differs from the image'
        'gpt-relocation-data-corrupt' = 'Read-back mismatch at byte 4194304'
        'baseline-mismatch' = 'Expected current image mismatch at byte 12582912'
        'baseline-wronglength' = 'Expected current image length must equal the saved target disk size'
        'baseline-lock-failure' = 'Cannot exclusively lock volumes for expected current image check'
        'baseline-short-read' = 'Short current disk read at byte 0'
        'baseline-read-failure' = 'Injected current read open failure'
        'baseline-source-target' = 'source image or running project'
        'deferred-body-failure' = 'Injected deferred body failure'
        'deferred-guard-rejected' = 'explicit layout-clearing write mode'
        'deferred-verify-rejected' = 'explicit layout-clearing write mode'
        'deferred-publish-body-corrupt'='Deferred read-back mismatch'
        'deferred-publish-boot-corrupt'='Deferred read-back mismatch'
        'deferred-publish-short-read'='Deferred read-back mismatch'
        'deferred-publish-size-mismatch'='exact target capacity'
        'deferred-publish-identity-changed'='identity changed'
        'deferred-publish-refresh-failure'='Injected refresh failure'
    }
    if ($reasons.ContainsKey($Scenario)) {
        Require (($global:WriterMessages -join '; ') -match [regex]::Escape($reasons[$Scenario])) "Wrong rejection reason: $($global:WriterMessages -join '; ')"
    }
    Require (@([TestState]::Handles | Where-Object { -not $_.Disposed }).Count -eq 0) 'Handle leak'
    if ($Scenario -in 'truncated-gpt', 'missing-backup', 'primary-header-crc', 'backup-header-crc', 'table-crc', 'backup-table-crc', 'table-bounds') {
        Require ([TestState]::Writes -eq 0 -and [TestState]::Written -eq 0) 'Invalid GPT reached disk writing'
        Require ([TestState]::Handles.Count -eq 0) 'Invalid GPT opened a disk or volume handle'
    }
    if ($src) { Require (-not $src.CanRead) 'Source stream leak' }
    if ($isBaseline) {
        Require (-not $global:currentImage.CanRead) 'Baseline stream leak'
        Require ([TestState]::Deletes -eq 0) 'Baseline check used destructive fallback'
        $events = [TestState]::Events
        if ($Scenario -in 'baseline-match', 'baseline-mismatch', 'baseline-short-read') {
            Require ($events.LastIndexOf('lock') -lt $events.IndexOf('open-read')) 'Baseline read opened before all locks'
            Require ($events.IndexOf('unlock') -gt $events.LastIndexOf('dispose-read')) 'Baseline read handle outlived locks'
        }
        if ($Scenario -eq 'baseline-match') {
            Require ($currentOffset -eq 16MB -and [TestState]::Reads -eq 7) 'Baseline match skipped disk bytes or read-back'
            Require ($events.IndexOf('dispose-read') -lt $events.IndexOf('open-write')) 'Write handle opened before current read closed'
        } else {
            Require ([TestState]::Writes -eq 0 -and [TestState]::Written -eq 0) 'Failed baseline check wrote to disk'
            Require (@([TestState]::Handles | Where-Object Kind -eq 'write').Count -eq 0) 'Failed baseline check opened write handle'
        }
        if ($Scenario -eq 'baseline-lock-failure') { Require ([TestState]::Reads -eq 0 -and [TestState]::Unlocks -eq 1) 'Failed lock did not abort and release held lock' }
        if ($Scenario -in 'baseline-wronglength', 'baseline-source-target') { Require ([TestState]::Handles.Count -eq 0) 'Invalid baseline reached disk handles' }
    }
    $written = ([TestState]::Writes -gt 0 -and $Scenario -notin 'write-failure', 'short-write')
    if($isBeforePublish){
        if(Test-Path -LiteralPath $arguments.ResultPath){
            $receipt=Get-Content -LiteralPath $arguments.ResultPath -Raw -Encoding UTF8|ConvertFrom-Json
            Require ($receipt.Complete -eq ($expected -eq 0)) 'Wrong completion receipt'
        }else{Require ($Scenario -eq 'deferred-publish-size-mismatch') 'Missing writer receipt'}
        Require (@([TestState]::Events|Where-Object{$_ -eq 'lock'}).Count -eq 0) 'Pre-publication verification attempted to relock mounted FAT'
        $commits=@([TestState]::Events|Where-Object{$_ -like 'write-at:*:1048576'})
        if($Scenario -in 'deferred-publish-body-corrupt','deferred-publish-short-read','deferred-publish-identity-changed'){
            Require ($commits.Count -eq 0 -and [TestState]::Refreshes -eq 0) 'Failed body verification published GPT'
        }elseif($Scenario -eq 'deferred-publish-size-mismatch'){
            Require ([TestState]::Deletes -eq 0 -and [TestState]::Writes -eq 0) 'Capacity mismatch modified USB'
        }else{
            Require ([TestState]::Written -eq $bytes.Length -and $commits.Count -eq 2) 'Incomplete boot/GPT publication'
            Require ([TestState]::Events.IndexOf('read') -lt [TestState]::Events.IndexOf($commits[0])) 'GPT was published before body read-back'
            Require ([TestState]::Events.LastIndexOf('read') -lt [TestState]::Events.IndexOf('refresh') -or $Scenario -eq 'deferred-publish-boot-corrupt') 'Refresh preceded verification'
            if($expected -eq 0){
                Require ($receipt.BytesVerified -eq $bytes.Length -and [TestState]::ReadBytes -ge $bytes.Length -and $receipt.BeforePublicationBodyVerified) 'Missing complete read-back coverage'
                Require ($receipt.ExpectedSourceSha256 -eq $checksum) 'Receipt lost validated source hash'
                $actual=[IO.File]::ReadAllBytes($fakeDiskFile)
                if($Scenario -eq 'deferred-publish-mounted'){
                    Require ($actual[5MB] -eq 0x91) 'Post-mount metadata simulation did not run'
                    $actual[5MB]=$bytes[5MB]
                }
                $comparison=[Security.Cryptography.SHA256]::Create()
                try{Require ([Convert]::ToBase64String($comparison.ComputeHash($actual)) -ceq [Convert]::ToBase64String($comparison.ComputeHash($bytes))) 'Unexpected written bytes'}finally{$comparison.Dispose()}
            }
        }
    }elseif ($written) {
        $actual = [IO.File]::ReadAllBytes($fakeDiskFile)
        $hash = [Security.Cryptography.SHA256]::Create()
        try {
            Require ([Convert]::ToBase64String($hash.ComputeHash($actual, 0, $bytes.Length)) -eq [Convert]::ToBase64String($hash.ComputeHash($bytes))) 'Written disk bytes differ from image'
            Require ($actual.Length -eq 16MB -and $actual[$bytes.Length] -eq 0x4a) 'Wrote beyond image length'
        } finally { $hash.Dispose() }
        Require ([TestState]::Refreshes -eq $(if ($isDeferred) { 2 } else { 1 })) 'Completed write must refresh, even when verification fails'
        Require ([TestState]::Reads -gt 0) 'No read-back verification'
        $events = [TestState]::Events
        if ($Scenario -ne 'lock-failure' -and -not $isDeferred) {
            Require ([TestState]::Deletes -eq 0) 'Lock success used destructive fallback'
            Require ($events.IndexOf('unlock') -gt $events.LastIndexOf('read')) 'Locks released before verification completed'
        }
        Require ($events.LastIndexOf('refresh') -gt $events.LastIndexOf('dispose-read')) 'Final refresh occurred before read handle disposal'
    } else {
        Require ([TestState]::Deletes -eq $(if ($Scenario -eq 'deferred-body-failure') { 1 } else { 0 })) 'Unexpected layout deletion on failure'
        Require ([TestState]::Refreshes -eq 0) 'Incomplete write refreshed'
        $hash = [Security.Cryptography.SHA256]::Create()
        if ($Scenario -eq 'short-write') { [Array]::Copy($bytes, $initialDisk, (4MB - 1)) }
        try { Require ([Convert]::ToBase64String($hash.ComputeHash([IO.File]::ReadAllBytes($fakeDiskFile))) -eq [Convert]::ToBase64String($hash.ComputeHash($initialDisk))) 'Rejected scenario changed unexpected disk bytes' }
        finally { $hash.Dispose() }
    }
    if ($Scenario -eq 'lock-failure') {
        Require ([TestState]::Deletes -eq 1) 'Failed lock did not delete layout'
        Require ([TestState]::Events.IndexOf('unlock') -lt [TestState]::Events.IndexOf('delete')) 'Fallback deleted layout before lock cleanup'
        Require ([TestState]::Partitions -eq 0) 'Layout deletion was not verified'
    }
    if ($Scenario -eq 'identity-changed') {
        Require ([TestState]::Changed -and [TestState]::Writes -eq 0) 'Identity change case never reached the pre-deletion guard'
        Require ([TestState]::Unlocks -eq 1) 'Identity rejection leaked the successfully held lock'
    }
    if ($Scenario -in 'write-failure', 'short-write') {
        Require ([TestState]::Writes -eq 1 -and [TestState]::Unlocks -eq 2) 'Write exception did not release both locks'
    }
    if ($Scenario -eq 'full') { Require ([TestState]::Reads -eq 3) 'Full verification missed final partial chunk' }
    if ($Scenario -in 'deferred','deferred-final-rescan','deferred-clean-fallback') {
        Require ([TestState]::Written -eq $bytes.Length -and $verified -eq $bytes.Length) 'Deferred mode did not copy and verify the entire image.'
        Require ([TestState]::Deletes -eq 1) 'Deferred mode must explicitly clear layout once.'
        $writes = @([TestState]::Events | Where-Object { $_ -like 'write-at:*' })
        Require ($writes[0] -eq 'write-at:1048576:4194304') 'Body must start at 1 MiB, before GPT exposure.'
        Require ($writes[-1] -eq 'write-at:0:1048576') 'Primary GPT must be the last region written.'
        Require ([TestState]::Events.IndexOf('unlock') -gt [TestState]::Events.LastIndexOf('read')) 'New volume locks released before deferred read-back finished.'
        if ($Scenario -eq 'deferred-clean-fallback') { Require ([TestState]::Events.Contains('diskpart-clean')) 'IOCTL-success-with-partitions did not reach the guarded clean fallback.' }
    }
    if ($isReadOnlyScenario) {
        Require ([TestState]::Writes -eq 0 -and [TestState]::Written -eq 0) 'VerifyOnly performed writes'
        Require ([TestState]::Deletes -eq 0 -and [TestState]::Refreshes -eq 0) 'VerifyOnly deleted or refreshed the layout'
        Require (@([TestState]::Handles | Where-Object { $_.Kind -eq 'write' }).Count -eq 0) 'VerifyOnly opened a write handle'
        Require (@([TestState]::Handles | Where-Object { $_.Kind -eq 'volume' }).Count -eq 2 -and [TestState]::Unlocks -eq 2) 'VerifyOnly did not hold and release both volume locks'
        $events = [TestState]::Events
        Require ($events.LastIndexOf('lock') -ge 0 -and $events.LastIndexOf('lock') -lt $events.IndexOf('read')) 'VerifyOnly read before acquiring locks'
        Require ($events.IndexOf('unlock') -gt $events.LastIndexOf('read')) 'VerifyOnly released locks before read-back completed'
        Require ((Split-Path $WriteLog -Leaf) -ceq 'write-image-verify.log') 'VerifyOnly used the write log'
        if ($Scenario -in 'verify-only', 'gpt-relocation') {
            Require ([TestState]::Reads -ge 3 -and $verified -eq $bytes.Length) 'VerifyOnly did not verify the entire image including the final partial chunk'
            if ($isRelocation) { Require ([TestState]::Reads -ge 6) 'Relocation verification skipped metadata reads' }
        } elseif ($Scenario -eq 'verify-only-corrupt') {
            Require ([TestState]::Reads -eq 1 -and $verified -eq 0) 'VerifyOnly accepted or skipped the corrupt first block'
        } elseif ($Scenario -eq 'gpt-relocation-data-corrupt') {
            Require ([TestState]::Reads -ge 5 -and $verified -eq 4MB) 'Relocation verification skipped later data blocks'
        } else {
            $expectedMetadataReads = switch ($Scenario) {
                'gpt-relocation-primary-corrupt' { 1 }
                'gpt-relocation-backup-corrupt' { 2 }
                'gpt-relocation-table-corrupt' { 3 }
            }
            Require ([TestState]::Reads -eq $expectedMetadataReads) 'Relocation corruption did not fail at its metadata check'
        }
    }
    if ($Scenario -in 'windows-volume-selection', 'linux-driver-volume') {
        $expectedVolumes = if ($Scenario -eq 'linux-driver-volume') { 2 } else { 1 }
        Require (@([TestState]::Handles | Where-Object { $_.Kind -eq 'volume' }).Count -eq $expectedVolumes) 'Wrong native volume handle count'
        Require ([TestState]::Unlocks -eq $expectedVolumes) 'Wrong native unlock count'
        Require (@([TestState]::Events | Where-Object { $_ -eq 'lock' }).Count -eq $expectedVolumes) 'Wrong native lock count'
        Require ([TestState]::Deletes -eq 0) 'Volume selection used destructive fallback'
        $selectedPaths = @([TestState]::Events | Where-Object { $_ -like 'volume-path:*' })
        $expectedPaths = if ($Scenario -eq 'linux-driver-volume') { 'volume-path:\\.\E:,volume-path:\\.\L:' } else { 'volume-path:\\.\E:' }
        Require (($selectedPaths -join ',') -ceq $expectedPaths) "Wrong selected volumes: $selectedPaths"
        Require ((@([TestState]::Events | Where-Object { $_ -like 'query-volume:*' }) -join ',') -ceq 'query-volume:1,query-volume:3') 'BIOS/Linux filesystem queries did not receive the piped partitions'
    }
    $result = @{ HarnessPassed = $true; WriterExit = $global:WriterExit; Bytes = [TestState]::Written; Verified = $verified; Reads = [TestState]::Reads; Deletes = [TestState]::Deletes; Refreshes = [TestState]::Refreshes; Volumes = @([TestState]::Handles | Where-Object { $_.Kind -eq 'volume' }).Count; Unlocks = [TestState]::Unlocks }
    [Console]::WriteLine(($result | ConvertTo-Json -Compress))
    exit $global:WriterExit
} catch {
    [Console]::WriteLine((@{ HarnessPassed = $false; Error = $_.Exception.Message; Location = $_.ScriptStackTrace } | ConvertTo-Json -Compress))
    exit 2
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
