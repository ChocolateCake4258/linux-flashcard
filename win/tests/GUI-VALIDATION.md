# SSD GUI And Reboot Validation

For subsequently verified GeoGebra/browser replacements, see
[APP-COMPATIBILITY.md](APP-COMPATIBILITY.md). Hot reboot was intentionally left
unchanged at the user's request; the results below are historical trials.

The user confirmed that the physical USB preserves changes and boots successfully
on a second normal launch with background setup disabled. This phase did not
modify or rewrite USB. It used a separate copy of the prepared SSD overlay:

`E:\linux-flashcard-v2\diagnostics\ssd-gui-20261003`

The original `ssd-repair-20261003` prepared overlay and immutable RAW backing
image were left unchanged. GUI trials used 4096 MB / two vCPUs. Diagnostic
student/root autologin was used only in this trial, then removed from its final
`gui-review-state` snapshot. Older internal diagnostic snapshots still contain
autologin and must not be shipped or copied to USB.

## Application Results

- VS Code opened a test file, accepted keyboard input and saved the resulting
  `a` line. KDE Wallet was cancelled without entering credentials. The trial
  used `--disable-gpu --disable-extensions`; default GPU/extension behavior
  remains a separate check. Restricted Mode was not bypassed.
- Wireshark displayed its main window and interface list. Packet capture
  permissions were not enabled or tested.
- PyCharm displayed its JetBrains User Agreement. The agreement was not accepted;
  project editing/execution remains pending the user's decision.
- GeoGebra Discovery failed in native Giac code, not during package installation.
  `hs_err_pid3169.log` reports SIGILL in `giac::get_realtime()` at the instruction
  bytes `c5 f9 57 c0` (AVX `vxorpd`). Westmere guest flags contain no AVX. The
  later Java abort/core dump is a consequence of this native illegal instruction.
- JupyterLab displayed its launcher in Firefox. A disposable Python kernel
  created through REST and connected through WebSocket executed `print(6 * 7)`
  and returned `42`, with a successful execute reply and idle completion. The
  test deleted its kernel afterward. The server was loopback-only with a fixed
  diagnostic token, not a production authentication configuration.

## Browser Findings

The prepared system's `/usr/bin/firefox` was the Ubuntu Snap-transition stub,
while the actual Firefox Snap was absent. Existing MozillaTeam PPA priority
selected real Firefox 157.0. In the GUI trial only, APT replaced the transition
stub with that candidate using `--allow-downgrades` because the stub has a higher
epoch. No distro upgrade, autoremove or global network setting change was made.

The MozillaTeam confined `usr.bin.firefox` AppArmor profile lacked permissions
for the new `~/.config/mozilla` layout and some newer cache lock files. A local
diagnostic addition allowed these paths and selected existing-runtime operations,
without unloading AppArmor or changing global user-namespace sysctls. Firefox
then rendered JupyterLab. The addition is stored in
`diagnostic-firefox.apparmor.local` and remains in this experimental GUI trial.
It was not deployed to the prepared overlay or USB.

Residual sandbox warnings remain: the profile denied a `sys_admin` capability
request during the browser's namespace probe, and earlier Wayland/pixbuf warnings
were observed. Full browser sandbox correctness has not been established.
Do not promote this local policy to production based only on successful rendering.

The GUI trial has approximately 2.3 GiB free inside the unchanged root partition.
The older prepared copy had approximately 3.2 GiB; browser installation and GUI
state consume additional space. No partition resizing or USB write was attempted.

## Controlled Reboot Observations

| Acceleration / CPU | Observation |
|---|---|
| WHPX / Westmere | Hot reboot reached `reboot: Restarting system`, then no new diagnostic root console appeared within the 90-second readiness deadline. This reproduced the earlier SSD observation. Cold QEMU start works. |
| TCG / Westmere | Hot reboot did start a new kernel and root session: boot ID changed from `1a719e1d-25af-4c9b-9681-43ecb8aaca47` to `3c1a5684-37ea-471b-bf91-c85a96479b0a`. Startup exceeded the first console deadline and took several minutes. This is not an acceptable desktop-performance workaround. |
| WHPX / Haswell-noTSX | Experimental AVX-capable profile caused an early kernel panic around guest time 1.52 seconds. QEMU also warned about unavailable PCID, TSC-deadline, ERMS and INVPCID features. The profile is rejected as a production fix; no USB launcher CPU setting was changed. |

These results implicate the tested accelerator/profile in hot-reset behavior,
but do not identify the precise kernel/hypervisor defect. The workloads and
readiness limits should not be confused with a general compatibility guarantee.
The original fixed prepared copy was not altered by these CPU experiments.

## Evidence And Review

The workspace contains serial-before-trial logs, QEMU commands/stderr,
`ssd-gui-verification.log`, `ssd-gui-firefox-install.log`, the Java crash report,
and PPM screenshots including `code-file-final`, `wireshark`, `pycharm`,
`jupyter-local-policy`, and `code-file-cancel-wallet`.

The final WHPX/Westmere session had no matched kernel soft lockup, stall or OOM
entries when checked. It was shut down normally. The final ext4 read-only check
found no consistency errors (optional extent optimizations were declined), and
the qcow2 check passed. The owned VM/NBD/tasks/tunnels were cleaned up.

`diagnostic-vm.ps1` now accepts explicit diagnostic `CpuModel` and `Display`
overrides. Defaults remain Westmere/headless. `open-ssd-gui.ps1` opens only this
existing SSD trial with 4096 MB / two vCPUs / WHPX / Westmere and a 2048 MB Windows
memory reserve. It never chooses a physical USB drive or restores a snapshot.

For user review from an elevated interactive Windows PowerShell:

```powershell
& 'E:\linux-flashcard-v2\win\tests\open-ssd-gui.ps1'
```

Log in as student using the normal Linux password, open PyCharm from the menu,
and decide on the displayed agreement. No password needs to be shared with the
assistant. Keep PowerShell open while QEMU runs and shut Linux down normally.
The review does not deploy fixes to USB. Further GUI testing beyond the agreement
depends on the user's acceptance decision.
