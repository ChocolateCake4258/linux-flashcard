#!/bin/bash
# Apply only the reviewed payload to the confirmed, offline Linux USB partition.
set -euo pipefail
[[ $EUID == 0 && ( $# == 1 || $# == 2 ) ]] || { echo 'Usage (root): apply-to-mounted-root.sh MOUNTPOINT [Legacy|Esp2GiB]' >&2; exit 1; }
case ${2-Legacy} in
    Legacy) root_size=22545432576;;
    Esp2GiB) root_size=28891414528;;
    *) echo 'Unknown layout; expected Legacy or Esp2GiB.' >&2; exit 1;;
esac
root=$(realpath -e "$1")
[[ $root != / && $(findmnt -nr -o TARGET --target "$root") == "$root" ]] || { echo 'An exact offline mountpoint is required.' >&2; exit 1; }
device=$(findmnt -nr -o SOURCE --target "$root")
[[ $(findmnt -nr -o FSTYPE --target "$root") == ext4 && $device == /dev/nbd0 ]] || { echo 'Expected the supervised NBD ext4 root partition.' >&2; exit 1; }
[[ $(blockdev --getsize64 "$device") == "$root_size" &&
   $(blkid -s UUID -o value "$device") == 7a328c21-d5fa-420e-ab31-3fa922210767 ]] || { echo 'Unexpected root partition geometry or UUID.' >&2; exit 1; }
payload=$(cd -- "$(dirname -- "$0")" && pwd)
for file in first-boot-setup.sh first-boot-setup.service sddm-software.conf qemu-software-rendering.sh jupyter-lab.desktop firefox-snap.pref; do
    [[ -s $payload/$file ]] || { echo "Missing payload: $file" >&2; exit 1; }
done
[[ -f $root/usr/local/bin/first-boot-setup.sh && -f $root/etc/systemd/system/first-boot-setup.service ]] || { echo 'Original setup files are missing.' >&2; exit 1; }
backup=$(mktemp -d "$root/var/backups/linux-flashcard-firstboot-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")
chmod 755 "$backup"
sources=(first-boot-setup.sh first-boot-setup.service sddm-software.conf qemu-software-rendering.sh jupyter-lab.desktop firefox-snap.pref)
destinations=(usr/local/bin/first-boot-setup.sh etc/systemd/system/first-boot-setup.service etc/sddm.conf.d/90-pf-renderer.conf etc/profile.d/pf-qemu-software-rendering.sh usr/share/applications/jupyter-lab.desktop etc/apt/preferences.d/99-pf-firefox-snap)
modes=(755 644 644 644 644 644)
for index in "${!sources[@]}"; do
    destination="$root/${destinations[$index]}"
    [[ ! -L $destination ]] || { echo "Refusing symlink: $destination" >&2; exit 1; }
    if [[ -e $destination ]]; then
        mkdir -p "$backup/$(dirname -- "${destinations[$index]}")"
        cp -a -- "$destination" "$backup/${destinations[$index]}"
    fi
    temporary=$(mktemp "$(dirname -- "$destination")/.pf-fix.XXXXXX")
    install -o root -g root -m "${modes[$index]}" "$payload/${sources[$index]}" "$temporary"
    mv -fT -- "$temporary" "$destination"
    cmp -- "$payload/${sources[$index]}" "$destination"
done
# Preserve enablement: installing payload files must not restart USB setup loops.
sync -f "$root"
printf 'Payload installed and byte-verified. Original files: %s\n' "$backup"
printf 'No diagnostic root console, autologin, packages, GPT or ESP were copied.\n'
printf 'First-boot service enablement was preserved.\n'
