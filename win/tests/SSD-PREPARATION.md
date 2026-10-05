# SSD Preparation, October 3, 2026

See [GUI-VALIDATION.md](GUI-VALIDATION.md) for subsequent interactive findings.
Installation/CLI success below is not full GUI or deployment readiness: the GUI
trial found GeoGebra CPU incompatibility and an absent Firefox Snap behind its
transition stub, plus browser policy issues after testing the PPA alternative.

All changes in this phase were made only in a new host SSD overlay. No USB
partition, mounted USB filesystem, USB launcher or user USB VM was modified,
stopped or locked. The VM used 2048 MB / 2 vCPU / explicit WHPX; SDDM was
stopped inside this diagnostic guest to conserve memory for the user's tests.

## Stored State

- Workspace: `E:\linux-flashcard-v2\diagnostics\ssd-repair-20261003`.
- Overlay: `overlay.qcow2`, approximately 4.82 GB at completion.
- Immutable backing file: `E:\linux-flashcard-v2\diagnostics\usb-current-20261003.img`.
- Internal snapshots: `before-package-repair`, `packages-installed`, `packages-ready`.
- Use `packages-ready` for the final prepared state. Earlier diagnostic snapshots
  still contain the overlay-only root serial autologin; it was removed before
  saving `packages-ready`.
- The overlay is not standalone. Preserve its backing image and metadata; do
  not overwrite the USB with this older copy of the user's filesystem.
- First-boot setup remains disabled, with `status=succeeded`, empty `failed`,
  and `successcounter=25` in `/var/lib/linux-flashcard/first-boot-status`.

## Repairs And Installations

The exact `golang-1.26-src=1.26.0-1` package was downloaded and unpacked again,
then `dpkg --configure -a` completed Go documentation/source configuration.
`dpkg --audit` produced no output before and after subsequent installations.

APT installed Go, Rust/Cargo, Node.js/npm, PostgreSQL/client, Docker, net-tools,
traceroute and Wireshark with `--no-install-recommends`. Wireshark's setuid
capture option was disabled. Required APT dependency updates were accepted;
no distribution upgrade or autoremove was performed.

TypeScript was installed globally through npm. The existing isolated Jupyter
venv was completed, `pip check` passed, and the `/usr/local/bin/jupyter` launcher
was restored without installing Python packages into the distribution Python.
The student was added to the Docker group, as intended by the original setup.

Snap Store connectivity passed in this guest. Code, PyCharm Community and
GeoGebra Discovery installed successfully without network configuration changes.
The old failed Snap changes report `unexpected EOF` on downloads and one local
DNS timeout; these explain more than the original CLI timeout messages, but do
not prove the cause of the old USB kernel stalls. IPv4 HTTPS worked; the tested
IPv6 HTTPS connection failed. No global IPv6/DNS workaround was deployed.

| Component | Observed Version |
|---|---|
| Go | 1.26.0 |
| Rust / Cargo | 1.93.1 |
| Node.js / npm | 22.22.1 / 9.2.0 |
| TypeScript | 7.0.2 |
| PostgreSQL | 18.6 |
| Docker | 29.1.3 |
| JupyterLab / Notebook / ipykernel | 4.6.4 / 7.6.3 / 7.4.0 |
| Wireshark | 4.6.4 |
| VS Code | 1.140.0, snap revision 267 |
| PyCharm Community | 2026.2.3, snap revision 676 |
| GeoGebra Discovery | 5.0.641.0, snap revision 472 |

The original setup script was then run manually after all installations were
present. Its final verification completed 25 operations with zero failures,
and did not re-enable its automatic startup.

## Functional Verification

`verify-prepared-system.sh --ssd-overlay` checks the disabled setup state and
clean package audit, then uses the student account to compile/run Go and Rust,
compile TypeScript and execute it through Node.js, and run a GDB batch check.
It also checks Jupyter, PostgreSQL SQL access, student access to the Docker
daemon and the official `hello-world` container, Wireshark/Code versions,
installed Snap applications and active database/container services.

These checks passed twice, including after a full QEMU stop/start. The post-start
kernel journal had no matched soft lockup, stall, I/O error, ext4 error or OOM
entries at the time of verification. Full interactive GUI operation of the
editors and GeoGebra remains unverified; installed presence and CLI checks are
not equivalent to testing their windows.

A guest `systemctl reboot` reached `reboot: Restarting system` but did not start
a new boot within the diagnostic console deadline. Its framebuffer reported
inactive display output. QMP `quit` ended only this owned SSD VM, and a fresh
QEMU launch booted the repaired system successfully. This hot-reboot issue under
the tested WHPX profile is unresolved; do not describe cold-start success as
proof that hot reboot works. Final guest poweroff completed normally.

Read-only `e2fsck -fn` after final shutdown found no filesystem consistency
errors; two optional extent-tree optimizations were declined. `qemu-img check`
reported no qcow2 errors after saving the final snapshot.

Approximately 3.2 GiB remain free inside the unchanged 21 GiB root filesystem.
Allow for user projects, editor caches, containers and future package updates;
this is limited headroom, not a reason to resize or rewrite the USB automatically.

## Evidence And Tool Checks

The workspace contains `ssd-repair-apt.log`, `ssd-repair-jupyter.log`,
`ssd-repair-typescript.log`, `ssd-repair-snap-*.log`,
`ssd-repair-final-setup.log`, `ssd-repair-verification.log`,
`ssd-repair-verification-after-reboot.log`, and `first-boot-status`, copied from
the offline SSD guest. Serial and QEMU command/stderr logs remain there too.

An upload-tool bug was found during these checks: `install -d -m 755` changed
the permissions of an existing guest destination directory, including `/tmp`.
`guest-console.py` now creates the directory only when missing. This diagnostic
guest's `/tmp` mode was restored to 1777. Regression tests exercise the actual
upload command with existing modes 0711/1777, missing parents, quoted paths and
binary payloads. No physical USB directory permissions were changed in this phase.

Only owned SSD scheduled tasks/processes were cleaned up. The NBD client was
disconnected and the SSD SSH forwarding tunnel closed. The ready copy was not
deployed to USB; user files changed during current USB testing are not represented
by its earlier immutable backing image.
