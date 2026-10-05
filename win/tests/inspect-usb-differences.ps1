param(
    [Parameter(Mandatory = $true)][string]$ImagePath,
    [Parameter(Mandatory = $true)][int]$DiskNumber,
    [Parameter(Mandatory = $true)][string]$ExpectedDevicePath,
    [Parameter(Mandatory = $true)][string]$ExpectedSerialNumber,
    [Parameter(Mandatory = $true)][long]$ExpectedSize,
    [long]$Offset = 0
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib/pf-tools.psm1') -WarningAction SilentlyContinue
$identity = [pscustomobject]@{ Path = $ExpectedDevicePath; SerialNumber = $ExpectedSerialNumber.Trim(); Size = $ExpectedSize }
$null = Assert-PfUsbDisk -Number $DiskNumber -Identity $identity
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
public static class PfDifferenceProbe {
    public static string[] Compare(byte[] expected, byte[] actual) {
        var result = new List<string>();
        int count = 0;
        for (int i = 0; i < expected.Length; i++) {
            if (expected[i] == actual[i]) continue;
            count++;
            if (result.Count < 64)
                result.Add(String.Format("offset={0} expected={1:X2} actual={2:X2}", i, expected[i], actual[i]));
        }
        result.Add("TOTAL_DIFFERING_BYTES=" + count);
        return result.ToArray();
    }
}
'@
$source = $null
$handle = $null
try {
    $source = [IO.File]::OpenRead($ImagePath)
    $source.Position = $Offset
    $expected = New-Object byte[] (4MB)
    $actual = New-Object byte[] (4MB)
    if ($source.Read($expected, 0, $expected.Length) -ne $expected.Length) { throw 'Short source read.' }
    $handle = Open-PfRawDisk -Drive "\\.\PhysicalDrive$DiskNumber" -Access Read
    if ((Read-PfRawBytes -Handle $handle -Bytes $actual -Offset $Offset) -ne $actual.Length) { throw 'Short USB read.' }
    Write-Output "PROBE_OFFSET=$Offset (reported differences are relative to this offset)"
    [PfDifferenceProbe]::Compare($expected, $actual)
} finally {
    if ($handle) { $handle.Dispose() }
    if ($source) { $source.Dispose() }
}
