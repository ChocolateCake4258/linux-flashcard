# Compatible Apps, October 3-4, 2026

This supersedes the unresolved application choices in `GUI-VALIDATION.md`.
Only a new SSD copy was changed. USB, the previous prepared/GUI copies, CPU,
Windows hypervisor settings, guest RAM policy, swap and partition layout were
not changed. No further hot-reboot experiments were performed.

## Ready SSD State

- Workspace: `E:\linux-flashcard-v2\diagnostics\ssd-apps-20261003`.
- Final snapshot: `compatible-apps-ready` in `overlay.qcow2`.
- Backing file: the immutable `usb-current-20261003.img`; the overlay is not
  standalone and must retain this backing file.
- First-boot status: `succeeded`, zero failures, 26 successful operations;
  service enablement remains disabled.
- Temporary root/student autologin files were removed from the final state.
  Older internal diagnostic snapshots still contain them and are not releases.
- The original GUI copy containing the user's PyCharm test was copied, not
  reverted or overwritten. USB changes made after the RAW capture are not in it.

## GeoGebra

Ubuntu APT `geogebra` version `4.0.34.0+dfsg1-9build1` works with the existing
Westmere profile and Java 25. This is an older desktop version with Java-based
math support, not the Discovery build whose native Giac library required AVX.

The GUI accepted `f(x)=x^2` and `a=2+2`, displayed the parabola and `a=4`, saved
`/home/student/pf-geogebra-check.ggb`, and reopened it with the same objects.
The GGB XML confirms the expression and numeric value. A later cold start
retained the file. These are basic graph/calculation/persistence checks, not
verification of every CAS, 3D or modern-file-format feature.

The broken Discovery Snap was removed with normal `snap remove`, preserving an
automatic data snapshot (set 1, 239 KiB). Its unused GNOME 42 runtime had no
connected clients and was removed with its automatic data snapshot preserved
(set 2). Core runtimes required by Code/PyCharm and shared GTK themes were kept.

## Firefox And Jupyter

Official Mozilla Firefox Snap `157.0-1`, revision 8995, installed with its normal
strict confinement. It uses core24, GNOME 46 and Mesa runtime content. The
MozillaTeam PPA native Firefox was replaced by Ubuntu's Snap integration package
`1:1snap1-0ubuntu9.1`, so `/usr/bin/firefox` works normally with the installed Snap.

`win/fixes/firefox-snap.pref` gives only Ubuntu's `firefox` integration package
priority 1002, above the existing MozillaTeam priority 1001. Other packages and
repository definitions were not changed. The earlier local AppArmor prototype
was restored byte-for-byte to its original backup.

Firefox displayed JupyterLab and the Python launcher. The REST/WebSocket test
created a disposable kernel, executed `print(6 * 7)`, checked output `42` and
successful idle completion, then deleted the kernel. It passed after cold start.
The server/token were loopback-only diagnostic settings, not deployed services.

Runtime browser checks observed:

- Main/content processes labelled `snap.firefox.firefox (enforce)`.
- Content process `NoNewPrivs: 1` and `Seccomp: 2`.
- A restricted user-namespace UID mapping (1000 to 1000, one UID).
- Global user namespace/AppArmor restriction sysctls unchanged at their prior
  values (both 1); no disabled browser sandbox or global AppArmor workaround.

Optional Snap documentation bind warnings appeared during one CLI launch, but
the command returned success. This is runtime protection evidence, not a full
security audit or guarantee about all browser features.

## Existing Apps And Recipe

Language compiler, Jupyter, PostgreSQL, Docker `hello-world`, Wireshark and Code
CLI checks passed again. PyCharm reopened its existing UI after the app/runtime
changes; its user-approved agreement/project state was preserved. Display-session
restarts required restarting only our stale diagnostic app scopes, not changing
PyCharm settings or packages. A cosmetic `ksplashqml` crash notification was
observed during one session restart; the desktop and apps continued to work.

The preparation recipe now installs APT GeoGebra and official Firefox Snap,
instead of Discovery. Only Code and PyCharm use `--classic`. Fixture coverage
checks these policies. The offline payload helper includes the Firefox preference
and preserves first-boot enablement instead of enabling heavy setup implicitly.
That helper still copies payload files only, not packages or user data; it was
not run against USB in this phase.

`verify-prepared-system.sh` verifies the revised package choices. Strict Snap
Firefox's version check runs in the student's systemd context, because a plain
`runuser` from root's session inherits the wrong cgroup for Snap confinement.

## Storage And Deployment Limit

The final unchanged 21 GiB root filesystem has approximately 1.5 GiB available
to ordinary users (1.7 GiB was observed earlier). This is limited headroom for
IDE caches, projects, containers and retained Snap update revisions.

Only unreferenced Snap installer-cache files with one hard link were removed,
after checking changes were complete; installed Snap files had separate links
and were not removed. No user cache, project, swap, kernel or filesystem reserve
policy was modified to reclaim space.

Before deploying, agree on the destination and storage plan. A larger USB is
preferable for the full toolset. Deploying to the current device must explicitly
accept/resolve the headroom limit, create a fresh verified backup and preserve
the user's latest files. Never write this older whole image over USB blindly.

## Evidence And Cleanup

The workspace contains `ssd-apps-*.log`, `first-boot-status`, the saved GGB and
screenshots (`geogebra-graph`, `geogebra-reopened`, `jupyter-snap-final`,
`pycharm-loaded`). Logs show no matched soft lockup/RCU stall/OOM/ext4 error entries
at the final check. A timed-out diagnostic scheduled task stopped one trial
after a long pause; qcow2 was checked, a recovery checkpoint saved, and cold-start
checks repeated. The final guest was shut down normally.

Final read-only ext4 checking found no consistency errors; optional extent-tree
optimizations were declined. Final qcow2 checking passed. Owned VM/NBD/tasks and
SSH forwarding were stopped/removed. The GUI launcher now points to this newest
copy, with the same Westmere/WHPX profile and a host-memory reserve.
