#!/bin/bash
set -euo pipefail
route=direct
[[ ! -b /dev/mapper/ventoy ]] || route=ventoy
printf 'route=%s\nvirtualization=%s\nroot_uuid=%s\nkernel=%s\n' \
    "$route" "$(systemd-detect-virt || true)" "$(findmnt -n -o UUID /)" "$(uname -r)"
if [[ -f /var/lib/linux-flashcard/unified-route-proof-passed ]]; then
    printf 'technical_roundtrip=passed\n'
else
    printf 'technical_roundtrip=pending\n'
fi
