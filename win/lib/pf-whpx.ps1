# Read-only WHPX API check; it does not change Windows features or boot settings.
function Get-PfWhpxStatus {
    if (-not ('PfWhpxCapabilityV1' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PfWhpxCapabilityV1 {
    [DllImport("WinHvPlatform.dll", ExactSpelling=true)]
    public static extern int WHvGetCapability(int code, out int present, int size, out int written);
}
'@
    }
    try {
        $present = 0; $written = 0
        $hr = [PfWhpxCapabilityV1]::WHvGetCapability(0, [ref]$present, 4, [ref]$written)
        $available = $hr -eq 0 -and $written -eq 4 -and $present -ne 0
        $detail = if ($available) { 'WinHvPlatform: HypervisorPresent=true' }
            elseif ($hr -ne 0) { 'WHvGetCapability: 0x{0:X8}' -f ($hr -band 0xffffffffL) }
            else { 'Гипервизор Windows не запущен.' }
        return [pscustomobject]@{ Available=[bool]$available; ApiAvailable=$true; HypervisorPresent=($present -ne 0); HResult=$hr; Detail=$detail }
    } catch {
        return [pscustomobject]@{ Available=$false; ApiAvailable=$false; HypervisorPresent=$false; HResult=$null; Detail=$_.Exception.Message }
    }
}

function Assert-PfWhpxAvailable {
    param($Status)
    if (-not $Status.Available) {
        throw ("Аппаратное ускорение WHPX недоступно: $($Status.Detail) " +
            'Для настройки запустите enable-acceleration.bat (потребуются права администратора). ' +
            'Проверьте виртуализацию AMD-V/SVM или Intel VT-x в UEFI/BIOS. ' +
            'После настройки Windows может потребоваться перезагрузка. Ускоренный режим не переключается на TCG автоматически.')
    }
}
