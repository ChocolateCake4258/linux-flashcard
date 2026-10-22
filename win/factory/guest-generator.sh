#!/bin/sh
# A sealed image is inert in ordinary launches. An explicit factory fw_cfg job
# can still resume a seal interrupted between its receipt and host checkpoint.
modprobe qemu_fw_cfg >/dev/null 2>&1 || true
test -e /sys/firmware/qemu_fw_cfg/by_name/opt/pf.factory/raw || exit 0
test -f /var/lib/linux-flashcard/factory-origin.json || test -f /var/lib/linux-flashcard/factory-pending || exit 0
mkdir -p "$1/multi-user.target.wants"
ln -sf /etc/systemd/system/pf-factory.service "$1/multi-user.target.wants/pf-factory.service"
