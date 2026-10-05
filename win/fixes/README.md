# First-Boot And QEMU Rendering Repairs

Current status: the earlier payload revision was deployed to USB, but its
heavy setup was subsequently disabled after writable-USB stalls. Keep it
disabled. Current SSD preparation uses APT GeoGebra and official Firefox Snap;
these newer choices have not been deployed to USB. See
`../tests/APP-COMPATIBILITY.md` for verified application results and limits.

This payload was tested in a persistent diagnostic overlay on Windows. The
source `.img` and `.qcow2` remain unchanged. The reviewed payload was applied
to the Linux partition of USB serial `0E7113C55070` without repartitioning.

## Payload

- `first-boot-setup.sh`: resumable package installation, isolated Jupyter venv,
  Wireshark/GeoGebra through APT, official Firefox Snap, bounded commands,
  space checks, atomic status. Code/PyCharm use classic confinement; Firefox
  uses strict confinement.
- `first-boot-setup.service`: background `Type=exec`; package installation no
  longer holds multi-user/graphical targets until all downloads finish.
- `sddm-software.conf`: software Qt Quick for the login greeter only.
- `qemu-software-rendering.sh`: software Qt Quick for QEMU desktop sessions,
  selected by DMI vendor. Native sessions and explicit user settings are kept.
- `jupyter-lab.desktop`: student launcher for the isolated environment.
- `firefox-snap.pref`: prefers Ubuntu's integration package for the installed
  official Firefox Snap, without changing other MozillaTeam packages.

`apply-to-mounted-root.sh` is a narrowly guarded offline deployment tool, not
a generic installer. It requires the confirmed NBD partition size and UUID,
backs up changed files and compares the installed bytes. It now preserves
service enablement instead of enabling setup automatically. Prepared USB
systems must keep heavy background installation disabled. This helper copies
payload files only, not the prepared applications or user data.

## Checks And Limits

The diagnostic overlay reached a populated login greeter and a Plasma desktop
with panels. Its corrected setup reported `status=succeeded`, 25 successful
operations, no failures; Jupyter was invoked as `student`. These package
installations were not copied to USB: the USB performs its own first setup.

The patched USB filesystem passed read-only `e2fsck`. Headless USB tests still
show a background-only framebuffer and do not confirm usable login controls.
Test the normal `run-qemu.bat` from the user's Windows desktop and native UEFI
boot before declaring the release complete. Do not disable password login or
copy diagnostic autologin/root-console files to the USB.

Root-only rollback backup on Windows:
`E:\linux-flashcard-v2\diagnostics\usb-before-firstboot-fix\linux-before-fix.qcow2`.
Original replaced files also remain under `/var/backups/linux-flashcard-firstboot-*`
on the USB. Do not restore a root-partition backup onto a whole physical disk.

This payload is not integrated into stages 1-7. New clones from the original
artifacts still need the verified EFI/stage-9 and Linux repair steps.
