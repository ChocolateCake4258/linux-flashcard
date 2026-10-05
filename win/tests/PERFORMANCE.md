# USB QEMU Performance Profile

Host tested: Ryzen 5 1600 (6 cores / 12 threads), 16 GB RAM, Windows 10,
Windows PowerShell 5.1. The old automatic USB launch selected 5120 MB / 6 vCPU;
its serial journal recorded 25-31 second kernel soft lockups and RCU stalls.

## Diagnostic Overlay Results

The existing, repaired diagnostic overlay on E: was used, not a writable USB
boot. QEMU used Westmere and explicit WHPX (`kernel-irqchip=off`), with Qt Quick
software rendering. Each WHPX profile included four minutes of two CPU-load
workers. No swap use, soft lockups or RCU stalls were observed during these runs.

| Profile | Observation | QMP median / p95 / maximum |
|---|---|---|
| 5120 MB / 4 vCPU / WHPX | 14 minutes | 3.50 / 4.78 / 43.87 ms |
| 6144 MB / 4 vCPU / WHPX | 15 minutes | 3.38 / 4.61 / 5.26 ms |
| 6144 MB / 2 vCPU / TCG | Booted; root-console readiness exceeded 90-second deadline initially | 3.22 / 3.93 / 4.20 ms |

QMP responsiveness does not prove guest GUI responsiveness. TCG control-plane
latency was low while guest startup/input was slower. The overlays have completed
first-boot installation and use SSD storage; these results do not reproduce the
USB's random I/O or simultaneous first-boot downloads. The old six-vCPU failure
was not reproduced under identical conditions, so its root cause is not proven.

## Launcher Policy

USB auto mode caps RAM at 6144 MB and vCPU at four, reducing RAM if necessary
to leave 2048 MB currently free for Windows. Explicit overrides are checked
against total and free memory before launch. Ordinary GUI retesting is required.

```bat
D:\run-qemu.bat -RamMb 6144 -Cores 4 -Accel WHPX
```

`-Accel Auto` preserves WHPX with TCG fallback. Explicit WHPX fails instead of
silently using TCG; explicit TCG uses multithreaded emulation. No hypervisor or
firmware settings are changed. Resource changes take effect only at the next boot.

Host runtime logs: `qemu-command.txt`, `qemu-stderr.log`, `qemu-stdout.log`,
`qemu-usb.log`. They remain on Windows host storage, not on the locked USB.

## Current USB Baseline

The 6144 MB / 4 vCPU resource cap did not resolve the user's writable-USB
failure: the retained `.16` launch reports a 27-second soft lockup on CPU 1 at
guest time 87.35 seconds. It occurs while `systemd-fsck-root.service` is running,
before the installed system's application-setup service starts. This run does
not establish application downloads as the immediate trigger. No stack trace
accompanies that watchdog line, so it does not identify the faulty code path.

An exact read-only capture of the current 31,042,043,904-byte USB was fully
compared against the device before testing. SSD overlays used that capture and
were reset to the `comparison-baseline` internal snapshot between profiles.
Only the diagnostic root serial console was added to that baseline.

| Storage / profile | Observation | Result |
|---|---|---|
| SSD / 6144 MB / 4 vCPU / WHPX | More than 21 minutes | No observed soft lockups or RCU stalls; wallpaper-only greeter |
| SSD / 6144 MB / 2 vCPU / WHPX | More than 19 minutes | No observed soft lockups or RCU stalls; wallpaper-only greeter |
| SSD / 6144 MB / 2 vCPU / TCG | Booted; load about 12.35 after five minutes | No observed stalls; wallpaper-only greeter |
| Physical USB, host snapshot / 6144 MB / 4 vCPU / WHPX | 300-second boot-marker deadline | No serial watchdog report, but no graphical-service marker; screenshot shows wallpaper only; test failed |
| Physical USB, host snapshot / same profile, dedicated I/O thread | 300-second boot-marker deadline | Same result as baseline; no evidence of an I/O-thread fix |

The physical-USB snapshot trial redirects guest writes to host storage. Its
absence of serial watchdog reports is not evidence that writable USB works,
nor does its wallpaper screenshot prove a working login screen. The serial
stream reaches a login prompt without a graphical-service marker; the test
intentionally does not treat that as success.

The captured baseline also contains a half-installed `golang-1.26-src`
(`reinstreq`, missing control and md5sums files) and unpacked
`golang-1.26-doc`, both version `1.26.0-1`. In an SSD overlay only, after
stopping first-boot setup with no APT/dpkg process running, downloading and
unpacking the exact source-package version followed by `dpkg --configure -a`
restored package health: `dpkg --audit` produced no output. The experiment is
retained in snapshot `package-repair-experiment`; this repair is not deployed
to USB and does not prove a watchdog fix.

Restarting SDDM in that overlay produced visible user/password controls.
Preserving `QT_WAYLAND_SHELL_INTEGRATION=layer-shell` together with software
rendering was tested, but removing the extra setting and restarting again
also showed the controls. Therefore the shell-integration hypothesis is not
confirmed, and no greeter configuration change was deployed.

A later cold boot restored `comparison-baseline` without the package repair
or extra greeter configuration. The login controls were visible immediately,
then disappeared after the theme's 60-second idle timeout. A QMP Shift keypress
restored them. Thus the previous wallpaper-only screenshots on SSD did not
establish a broken greeter; the idle theme behavior explains those images.
This verifies input wake-up, not password login or desktop responsiveness.

The same wake-up check was then repeated on a physical-USB host snapshot
(6144 MB / 4 vCPU / WHPX). Its post-Shift screenshot shows the student account,
password field and login/power controls. The script still failed its 120-second
serial graphical-marker deadline, correctly distinguishing visible controls
from its required service evidence. No serial watchdog report was observed.
This also explains the earlier physical-USB wallpaper-only screenshots; it
does not resolve the separate writable-USB soft lockup.

Trial transcripts on Windows are `diagnostics/usb-trial-baseline.log`,
`usb-trial-iothread.log`, and `usb-trial-wake.log`. Each records the unique
host TEMP runtime containing the full serial log, QEMU command, stderr and
screenshots. Baseline and I/O-thread trials ended with code 1, not a false pass.

## Snapshot Diagnostic Controls

`win/tests/test-usb-boot.ps1` now supports `-Accel Auto|WHPX|TCG`,
`-DedicatedIoThread`, and `-ObservationSec` (default zero). The observation
period starts at the first completed graphical-service marker; `-TimeoutSec`
remains the deadline for finding that marker. It rejects serial soft lockup,
watchdog lockup, and ordinary/Tasks RCU stall reports. An explicit accelerator
has no fallback. The dedicated thread changes only the diagnostic guest disk
to `virtio-blk-pci` attached to an I/O thread; it is not a production fix.
All variants retain snapshot mode, identity checks, host-only staging and
exclusive USB-volume locks until their owned QEMU process exits.
Screenshot capture saves both the pre-input frame and a frame after a harmless
Shift keypress, so idle hiding is not mistaken for missing login controls.

## Cleanup And Volume Status

All owned diagnostic QEMU/NBD processes were stopped, the three scheduled
diagnostic tasks were removed, and the NBD client was disconnected. The matched
overlay was returned to `comparison-baseline`; `package-repair-experiment` and
all logs/backups remain available.

Windows reports the ESP `D:` as dirty (`Full Repair Needed`), while the disk
itself is healthy and online. A read-only comparison found the same FAT32 boot
status byte at offset 65 (`01`) in both the immutable USB baseline and the
current device; FAT entry 1 was also identical (`FFFFFFFF`, clean-shutdown and
no-hard-error bits set). Thus that on-disk status predates these trials.
Read-only `chkdsk D:` (no `/F` or `/R`) reported no filesystem problems and no
further action required. No dirty-bit clearing or filesystem repair was run.

## Writable USB Trial, October 3

The user launched the normal `.16` USB launcher with 6144 MB / 4 vCPU /
explicit WHPX. QEMU PID 36668 started at 02:04:44 Windows local time, with
direct writable `PhysicalDrive2`, Westmere and `kernel-irqchip=off`. There was
no TCG fallback. The user reported roughly 20 minutes to reach the desktop,
then very slow or absent responses.

Guest screenshots established the following:

- About 3.9 GiB available guest memory, no swap use and no swap I/O.
- Load average 12.25 / 11.62 / 10.72, with 1-4 blocked tasks and 10-67 percent
  I/O wait in the subsequent one-second vmstat samples.
- Three kernel workers named `flush-253:0` in uninterruptible `D` state.
- `lsblk` identifies 253:0 as the whole virtio disk `vda`; root ext4 is `vda3`
  (253:3), and the ESP is `vda2` (253:2). This maps the flush workers to the
  disk backed by the physical USB, not an unrelated guest device.

Windows had about 6.3 GiB free RAM, sampled total CPU usage of 2-11 percent
and zero sampled paging input/output. Raw disk-counter deltas measured USB
mean write latency as high as 358.4 ms in one short interval. The serial log
contains repeated soft lockups on all four CPUs and an RCU self-detected stall;
individual soft lockup reports range up to 56 seconds. These observations
establish serious write-path latency and kernel stalls, not their causal
mechanism. A slow disk alone is not a sufficient explanation for soft lockups.

The copied first-boot log contains several runs. An earlier run ends while
unpacking `golang-1.26-src`; subsequent APT operations refuse to proceed because
dpkg was interrupted. The log does not identify what interrupted that run.
During the current run:

- Setup starts at 02:08:08; `apt-update` succeeds at 02:09:43.
- Eleven APT package operations fail with exit 100 due to interrupted dpkg.
- TypeScript fails with exit 127 because its command cannot be executed,
  consistent with the failed npm installation.
- Jupyter downloads complete and pip enters `Installing collected packages`;
  its 900-second timeout ends with exit 124 at 02:25:25. Internet absence is
  not an adequate explanation for this installation-stage failure.
- Snap VS Code reports store connectivity failure at 02:28:06. PyCharm times
  out at 02:43:22, after a snapd restart-wait message; GeoGebra times out at
  02:58:38. Timeout alone does not diagnose network failure.
- Adding the student to Docker's group fails because that group does not exist.
- Setup finishes at 02:58:38 with 18 successful operations and 17 failures;
  the service remains enabled for a future retry.

The user subsequently reported that lag stopped. At 03:07-03:08 the same QEMU
process and settings were still active; four sampled disk-counter intervals
showed zero writes, read latency about 0.7 ms and zero ending queue length.
The serial log's latest modification was 02:56:32. A later guest screenshot
showed setup in `failed` state, and subsequent vmstat samples showed zero
blocked tasks and I/O wait, zero block I/O and 98-100 percent idle CPU.
The first vmstat row is a since-boot average, not a current one-second sample.
The correlation supports testing background setup separately; it does not
prove that the writable USB or WHPX problem is fixed.

Logs were archived without stopping the VM under
`E:\linux-flashcard-v2\diagnostics\user-whpx4-20261003-033251`:
`qemu-usb.log`, `qemu-stderr.log`, `qemu-stdout.log`, `qemu-command.txt` and
`first-boot-setup.log`. Serial SHA256:
`7DA6036C4FC337EB5E26364E79C4ED668E6D8D26ED46F8453F20DB864FB5AAD3`;
setup SHA256:
`FFDF71A89763DE14781027A9DEA6E8FEC1B46F97663008893D2990D67AC42A01`.

Next controlled comparison: after a graceful guest shutdown, capture a new
verified USB backup without overwriting the old baseline. Temporarily suppress
first-boot setup, keeping QEMU resources, accelerator and writable USB storage
unchanged. Record and restore the service's prior enablement. Do not repair
packages, disable watchdogs or change disk/CPU settings in that same trial.
The running user VM has a file-only serial console and no configured guest
SSH forwarding, so guest shutdown requires user interaction. No offline disk
access, package repair or service disablement was attempted while it ran.

## Controlled No-Setup Preparation

After the user shut the VM down normally, no QEMU process remained. A new
whole-device read-only capture was created and fully compared against the
confirmed USB with `capture-usb.ps1 -Verification`. The old baseline and root
backup were not overwritten. New immutable baseline:

`E:\linux-flashcard-v2\diagnostics\usb-current-20261003.img`

Size: 31,042,043,904 bytes. SHA256:
`53618E206B273126DE321CAD4E7E2F7466060FBE21435DE4CF0C412B447BE933`.
The `.json` sidecar records verified capture and the `.sha256` sidecar records
the hash. The destination file has its read-only attribute set.

`toggle-first-boot-setup.sh` changes only the exact enablement symlink under
`multi-user.target.wants` on a mounted ext4 root with the expected UUID. It
backs up the original enabled state, link target and unchanged service unit.
Restore refuses a changed unit, unexpected saved state or occupied link path.
Its fixture tests cover guards and disable/restore, without accessing USB.

An SSD overlay of the new baseline was prepared in `diagnostics/current-no-setup`.
Only the setup enablement link was removed and the overlay-only root serial
drop-in was added. `no-setup-baseline` is its internal reset snapshot. WHPX,
Westmere, 6144 MB and four vCPUs were unchanged. After more than 19 minutes, setup remained
disabled/inactive; no kernel soft lockup, stall, I/O error or ext4 error entries
were found. Sampled vmstat showed no blocked tasks or swap use and 0-1 percent
I/O wait. A post-Shift screenshot showed student/password login controls.
This is an SSD greeter test, not proof of writable-USB desktop performance.
The broken Go package state was deliberately left unchanged.

The same symlink-only toggle was then applied offline to USB root through the
bounded, supervised root-only NBD export. No packages, renderer settings,
watchdog settings, launcher arguments or diagnostic root autologin were changed
on USB. The guest rollback directory is:

`/var/backups/linux-flashcard-firstboot-toggle-20261003T013719Z.QnvaH5`

The current unit and its saved copy have identical SHA256:
`C0CB7F188B39674550E8EB69EAE798E279BD57BB45AC5EBDE5E8EA3821C5A15E`.
Read-only `e2fsck -fn` checks before and after found no consistency errors;
two optional extent-tree optimizations were offered and declined. The root
was unmounted, NBD disconnected and the export stopped before releasing USB
locks. Setup now stays disabled across reboots until explicitly restored.

Offline restore, after unmounting any guest and safely mounting USB root at
`MOUNTPOINT`, is:

```bash
sudo bash win/tests/toggle-first-boot-setup.sh restore MOUNTPOINT \
  /var/backups/linux-flashcard-firstboot-toggle-20261003T013719Z.QnvaH5
```

The next required comparison is the user's ordinary writable USB launch with
the exact same `-RamMb 6144 -Cores 4 -Accel WHPX` profile and no background
setup. Observe login time, desktop input and watchdog logs before restoring
setup or attempting package repairs. Package repair is intentionally deferred
to keep this comparison to one variable.

The SSD diagnostic VM subsequently shut down through QMP `system_powerdown`
without a logged forced kill. All four `PF-current-*` owned scheduled tasks
were removed, NBD was disconnected, and the SSH forwarding tunnel was closed.
The toggle fixtures and shell syntax checks passed; all 56 PowerShell
regression checks passed on Linux and Windows PowerShell 5.1. No package repair
was performed in this phase. The physical USB remains with setup disabled for
the next user-visible comparison.

The subsequent SSD-only package recovery and verification are documented in
[SSD-PREPARATION.md](SSD-PREPARATION.md). The repaired copy was not deployed to USB.
