# QEMU without a 3D renderer needs software Qt Quick for Plasma panels/widgets.
# Use DMI: WHPX can report "vmware" through systemd-detect-virt.
# Do not alter native hardware sessions or override an explicit user choice.
if [ -r /sys/class/dmi/id/sys_vendor ] &&
   [ "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)" = QEMU ] &&
   [ -z "${QT_QUICK_BACKEND:-}" ]; then
    export QT_QUICK_BACKEND=software
fi
