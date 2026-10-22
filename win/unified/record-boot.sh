#!/bin/bash
set -euo pipefail
(( EUID == 0 ))
state=/var/lib/linux-flashcard
mode=direct
[[ ! -b /dev/mapper/ventoy ]] || mode=ventoy
virt=$(systemd-detect-virt || true)
printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u --iso-8601=seconds)" "$mode" "$virt" \
    "$(uname -r)" "$(findmnt -n -o UUID /)" >> "$state/unified-boots.tsv"
