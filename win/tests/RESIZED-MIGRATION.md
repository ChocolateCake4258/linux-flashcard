# Data-Preserving ESP Resize

The user approved a 2 GiB ESP, use of the remaining device space for Linux,
and guarded deployment to the confirmed USB. Original images and backups were
not overwritten. No working CPU/RAM/WHPX policy, swap size or hot-reset behavior
was changed.

## Evidence And Layout

Confirmed device: USB serial `0E7113C55070`, size `31042043904` bytes, not boot or
system. Verified latest capture:

`E:\linux-flashcard-v2\diagnostics\usb-pre-resize-20261004.img`

SHA256: `EE4E882257E2A701451892D8C8B2F7B4C87D0F5275294270712E7D1139DAB919`.
The capture's full device comparison passed and the image was made read-only.

The new image retains the original disk and partition GUIDs, filesystem UUIDs
(`8732-FF9D`, `7a328c21-d5fa-420e-ab31-3fa922210767`) and labels. At 512-byte sectors:

| Partition | Start | Size |
|---|---:|---:|
| Existing BIOS slot | 1 MiB | 1 MiB |
| ESP / QEMU | 2 MiB | 2 GiB |
| Linux root | 2050 MiB | 28891414528 bytes, about 26.9 GiB |

Root ends at 29603 MiB exclusive. The whole image is exactly the device size.
Existing BIOS-slot contents were copied, but the zero MBR boot code was retained:
the system remains UEFI-only, with no new Legacy BIOS support claimed.

ESP copy/hash verification covered all 3404 files, including EFI and Windows
QEMU. FAT source and target mounts explicitly use UTF-8; a first scratch attempt
with legacy FAT charset failed on Cyrillic names and was not deployed.

## User Data And System Preparation

The root was copied from the latest USB capture, not an older prepared system.
This retained current users, passwords, identity, network/settings and coherent
package state. Swap was recreated at the same 4 GiB size/mode, without copying
stale memory contents. Latest `/etc/fstab` uses the preserved filesystem UUIDs
and `/swap.img`, with no old swap-UUID resume configuration found.

Prepared user-data changes were merged using the original common base:
1180 selected changes imported; 573 conflicting/protected variants archived
privately under `/var/backups/linux-flashcard-migration-*`. Latest active data
and credentials won conflicts, prepared deletions were not applied, and caches,
known diagnostic data and browser/keyring credentials were not imported over
latest data. Private manifests/archives retain alternatives for review.

Post-install verification confirmed both existing login identities/password
states, machine identity, SSH host keys and fstab stayed unchanged, without
printing secret contents. New service accounts and Docker membership were
created through package managers rather than copying account databases.

The reviewed native GeoGebra/official Firefox recipe was installed in the new
SSD target. The interrupted Go source package was repaired first. A transient
DNS failure interrupted the first Code download; a retry succeeded. Final setup:
`succeeded`, 26 successful operations, zero failures, service disabled.

Compiler, Jupyter, PostgreSQL, Docker and editor checks passed. Jupyter's temporary
REST/WebSocket kernel returned 42. Native GeoGebra and the desktop displayed.
Code also opened/edited/saved a test file with ordinary startup arguments, without
the earlier GPU/extension diagnostic flags. No matched watchdog/RCU/OOM/ext4
error entries were observed at the final check.

After apps, root had about 7.6 GiB available and ESP about 825 MiB. Temporary
root/student autologin and the test-generated Jupyter cookie were removed.
Read-only ext4/FAT checks passed. The final sanitized image booted to normal
student/password login in a separate disposable overlay.

## Final Artifact And Deployment Guard

`E:\linux-flashcard-v2\diagnostics\linux-flashcard-resized-ready-20261004.img`

SHA256: `B79F23B237F969429A6056E021FD6AC2151C166EC3E7F56C864D972AF3E20958`.
Its `.sha256` sidecar contains the bare hash expected by the writer. The file is
read-only. Do not deploy the earlier `latest-layout-20261004.img` preparation
base: it contains temporary diagnostic console configuration and lacks the
finished package preparation.

`write-image.ps1 -ExpectedCurrentImagePath` requires exclusive volume locks and
compares the whole current USB to the verified latest backup before any write.
Mismatch/check failure aborts without layout deletion or writes, and the guarded
mode cannot fall back to destructive layout removal. Full read-back is required
after deployment. This prevents silently losing changes made during preparation.

Deployment outcome is recorded in `write-image.log`, the scheduled task result,
and subsequent verification logs. Do not infer deployment success merely from
creation of the final artifact.

## Tools And Future Builds

The whole-disk launcher and identity/GPT writer remain layout-generic. Root-only
export/deployment tools now require the matching explicit `Legacy` or `Esp2GiB`
profile. Esp2GiB root offset is `2149580800`, size `28891414528`; its verified
root backup directory is separate from legacy backups. Never restore the old
21 GiB root backup onto the larger root or whole device.

Future factory builds use 2 GiB ESP while retaining the generic 28 GiB image size
for 32 GB-device compatibility, producing about 26 GiB root. This one-off image
uses the whole confirmed device and has 26.9 GiB root; do not conflate geometries.
Original `.img`/`.qcow2` artifacts were not rebuilt or overwritten.
