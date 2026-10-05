#!/bin/bash
# Offline diagnostic only: change one enablement link, never run guest commands.
set -euo pipefail
fail() { printf '%s\n' "$*" >&2; exit 1; }
[[ $(id -u) == 0 ]] || fail 'Root is required.'
[[ $# == 2 || $# == 3 ]] || fail 'Usage: toggle-first-boot-setup.sh disable MOUNTPOINT | restore MOUNTPOINT /var/backups/BACKUP'
action=$1
[[ $action == disable && $# == 2 || $action == restore && $# == 3 ]] || fail 'Invalid action or arguments.'
root=$(realpath -e -- "$2")
[[ $root != / && $(findmnt -nr -o TARGET --target "$root") == "$root" ]] || fail 'An exact offline mountpoint is required.'
[[ $(findmnt -nr -o FSTYPE --target "$root") == ext4 &&
   $(findmnt -nr -o UUID --target "$root") == 7a328c21-d5fa-420e-ab31-3fa922210767 ]] || fail 'Unexpected root filesystem or UUID.'

unit=/etc/systemd/system/first-boot-setup.service
link=$root/etc/systemd/system/multi-user.target.wants/first-boot-setup.service
# Do not follow guest directory symlinks into the host or another mount.
for directory in etc/systemd/system etc/systemd/system/multi-user.target.wants var/backups; do
    [[ $(realpath -e -- "$root/$directory") == "$root/$directory" &&
       $(findmnt -nr -o TARGET --target "$root/$directory") == "$root" ]] || fail "Unsafe guest directory: $directory"
done
[[ -f $root$unit && ! -L $root$unit ]] || fail 'Expected a regular guest service unit.'
exec_start=$(grep -E '^[[:space:]]*ExecStart[[:space:]]*=' "$root$unit" || true)
[[ $exec_start == 'ExecStart=/bin/bash /usr/local/bin/first-boot-setup.sh' ]] || fail 'Unexpected service ExecStart.'

if [[ $action == disable ]]; then
    [[ -L $link && $(readlink -- "$link") == "$unit" ]] || fail 'Expected the exact enabled service symlink.'
    umask 077
    backup=$(mktemp -d "$root/var/backups/linux-flashcard-firstboot-toggle-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")
    printf '%s\n' enabled > "$backup/original-state"
    readlink -- "$link" > "$backup/original-target"
    cp -- "$root$unit" "$backup/service-unit"
    cmp -- "$root$unit" "$backup/service-unit"
    sync -f "$backup"
    [[ -L $link && $(readlink -- "$link") == "$unit" ]] || fail 'Service symlink changed during backup.'
    unlink -- "$link"
    sync -f "$root"
    printf 'Disabled only the first-boot enablement symlink. Guest backup: %s\n' "${backup#"$root"}"
else
    guest_backup=$3
    [[ $guest_backup == /var/backups/linux-flashcard-firstboot-toggle-* &&
       ${guest_backup#/var/backups/} != */* ]] || fail 'Expected a guest toggle backup path.'
    backup=$root$guest_backup
    [[ -d $backup && ! -L $backup && $(realpath -e -- "$backup") == "$backup" &&
       $(findmnt -nr -o TARGET --target "$backup") == "$root" ]] || fail 'Unsafe or missing backup directory.'
    for file in original-state original-target service-unit; do
        [[ -f $backup/$file && ! -L $backup/$file ]] || fail "Missing or unsafe backup file: $file"
    done
    cmp -s -- "$backup/original-state" <(printf '%s\n' enabled) &&
        cmp -s -- "$backup/original-target" <(printf '%s\n' "$unit") || fail 'Unexpected saved state or symlink target.'
    cmp -s -- "$root$unit" "$backup/service-unit" || fail 'Service unit changed since disable.'
    [[ ! -e $link && ! -L $link ]] || fail 'Enablement path is occupied; refusing to overwrite it.'
    ln -sT -- "$unit" "$link"
    sync -f "$root"
    printf 'Restored the original first-boot enablement symlink. Backup retained: %s\n' "$guest_backup"
fi
