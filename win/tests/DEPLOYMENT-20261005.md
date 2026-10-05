# Physical USB deployment, October 5, 2026

## Confirmed target and image

The user confirmed that the USB from the previous deployment logs is the intended
target and authorized discarding its contents and rewriting it from scratch.

- Target: USB serial `0E7113C55070`, Windows Disk 2 at deployment time.
- Capacity: `31042043904` bytes; not a boot or system disk.
- Image: `E:\linux-flashcard-v2\diagnostics\linux-flashcard-resized-ready-20261004.img`.
- SHA256: `B79F23B237F969429A6056E021FD6AC2151C166EC3E7F56C864D972AF3E20958`.

The image hash was recomputed and matched. The Windows writer/module hashes
matched the local source tree. No QEMU process was running before deployment.

## Successful full rewrite

The existing FAT volume could be locked and dismounted. The writer overwrote
the entire disk image while retaining volume locks through full read-back.
No separate format or layout deletion was necessary or performed in this run.

Writing took 3056 seconds, approximately 10 MiB/s. All `31042043904` bytes were
then read back and compared against the source, without mismatches. The writer
finished with exit code 0 at Windows local time `2026-10-05T01:07:17+03:00`.
Partition enumeration was refreshed successfully.

- FAT32 ESP: 2 GiB, label `FLASHCARD`, mounted as `D:`.
- Linux root partition: `28891414528` bytes, approximately 26.9 GiB.
- The QEMU executable, launcher script and module on `D:` matched their working
  copies on `E:` by SHA256.
- `EFI/BOOT` contains shim, GRUB, MMX and the configuration referencing root UUID
  `7a328c21-d5fa-420e-ab31-3fa922210767`.

Evidence on Windows:

- `diagnostics/write-image-before-20261005.log` preserves the previous failed log.
- `diagnostics/rewrite-20261005.log` preserves this full write/read-back transcript.
- `diagnostics/rewrite-20261005-result.json` records exit code 0.

The temporary `PF-rewrite-20261005` scheduled task was removed after completion.
The earlier failure's root cause remains unproven; successful locking and writing
in this run do not establish why the previous attempts failed.

## QEMU snapshot check

The physical USB was booted using QEMU copied from its ESP to Windows TEMP,
UEFI, WHPX/Westmere, 6144 MiB RAM and four vCPUs. Guest writes were redirected to
a temporary host snapshot and discarded afterward.

The framebuffer after a Shift keypress shows the normal graphical student login
screen with a password field. No matched kernel soft-lockup or RCU-stall report
was observed by the diagnostic script during its 600-second readiness window.

However, `test-usb-boot.ps1` failed with exit code 1 because its required completed
graphical-service marker was absent from the serial log. The serial console
reached a normal login prompt. The visible greeter does not turn that automated
failure into a pass and does not establish desktop, application or writable-USB
performance. WHPX emitted a performance-monitoring-feature warning.

Evidence:

- `diagnostics/usb-post-rewrite-20261005.log`.
- `diagnostics/usb-post-rewrite-20261005-result.json`.
- `diagnostics/usb-post-rewrite-evidence-20261005/`: serial log, QEMU command,
  stderr/stdout and before/after-input framebuffer captures.

The owned snapshot VM was stopped and volume locks released.

## Ordinary writable-USB results and follow-up

The user launched `D:\run-qemu.bat` and confirmed that the normal student login
and desktop eventually appeared, with roughly five minutes waiting after login.
The desktop remained slow. Four-vCPU serial/journal evidence includes 27-second
soft lockups on all four CPUs and timeouts/failures in accounts-daemon, polkit,
udisks2 and KDE startup. Guest diagnostics were printed to the serial console
by a user-run sudo command; no login password was shared with the assistant.

The guest reported setup `status=succeeded`, no failed operations and
`successcounter=26`. Ten vmstat samples showed no current swap activity and
approximately 3 GiB free RAM. Subsequent samples were mostly idle with little
I/O wait; the first since-boot average reported 27 percent I/O wait. This does
not explain the earlier lockups. `open-vm-tools` also dumped core while probing
VMware through `Backdoor_Vmcall`; no service configuration was changed.

Following an ordinary shutdown, the user tested 6144 MiB / two vCPUs / explicit
WHPX. It remained slow; serial logs recorded 25-39-second soft lockups on both
vCPUs. Reducing vCPU count is not a confirmed fix. The host is Ryzen 5 1600,
16 GiB RAM, Windows 10; QEMU reports version
`11.1.0 (v11.1.0-12130-ge470268ff4)`.

Archived evidence on Windows:

- `diagnostics/writable-usb-20261005-whpx4/` includes user-provided guest diagnostics.
- `diagnostics/writable-usb-20261005-whpx2/` includes the two-vCPU trial.

A separate diagnostic launcher was prepared under
`diagnostics/cache-none-runtime-20261005/`; it changes only the guest drive
option to `cache=none` relative to the two-vCPU run. Production launchers and
USB launcher files were not changed. Initial attempts failed volume locking
with Windows code 5, before QEMU launch. After closing USB windows and using a
host working directory, the user started this trial and reported lag and no
usable system. At the final inspection QEMU PID 20308 was still running with
two vCPUs / 6144 MiB / WHPX / cache=none. Its logs remain in that diagnostic
directory. No complete journal-based diagnosis or success was established.
The user's active guest was not forcibly killed or accessed offline.

The user asked to pause further experiments because of their remaining token
budget. There is no confirmed performance fix, and `cache=none` must not be
promoted to production based on this trial. Continue by reviewing this latest
trial after a normal guest shutdown, then investigating storage latency versus
the WHPX/QEMU/kernel interaction with bounded, one-variable comparisons.

The user also noticed a historical test file on the desktop. It came from the
prepared image, which contains migrated user data: the disk was fully rewritten,
but this was not a fresh factory installation. That distinction was explained;
the user selected performance diagnosis rather than rebuilding a clean OS.

App GUI/function tests and persistence across cold restarts remain incomplete.
Physical UEFI boot was deferred by the user. Legacy BIOS support is not claimed.
