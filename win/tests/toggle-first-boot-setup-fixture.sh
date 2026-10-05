#!/bin/bash
# Isolated fixtures: no real mount, root privileges, or guest process execution.
set -euo pipefail
base=$(dirname -- "$(realpath -e -- "$0")")
helper=$base/toggle-first-boot-setup.sh
bash -n "$helper" "$0"
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT
root=$temporary/root
mkdir -p "$root/etc/systemd/system/multi-user.target.wants" "$root/var/backups"
unit=/etc/systemd/system/first-boot-setup.service
link=$root/etc/systemd/system/multi-user.target.wants/first-boot-setup.service
cp -- "$base/../fixes/first-boot-setup.service" "$root$unit"
ln -s -- "$unit" "$link"

# Exported command mocks exercise the production entry point without test flags.
id() { [[ $* == -u ]] && printf '%s\n' "$mock_uid"; }
findmnt() {
    [[ $# == 5 && $1 == -nr && $2 == -o && $4 == --target && $5 == "$root"* ]] || return 1
    case $3 in
        TARGET) printf '%s\n' "$mock_mount";;
        FSTYPE) printf '%s\n' "$mock_fstype";;
        UUID) printf '%s\n' "$mock_uuid";;
        *) return 1;;
    esac
}
export -f id findmnt
export root mock_uid=0 mock_mount=$root mock_fstype=ext4 mock_uuid=7a328c21-d5fa-420e-ab31-3fa922210767
reject() {
    if bash "$helper" "$@" > "$temporary/output" 2>&1; then
        printf 'FAIL: unexpectedly accepted %s\n' "$*" >&2
        exit 1
    fi
}

reject
reject disable /
reject restore "$root"
mock_uid=1000; reject disable "$root"; mock_uid=0
mock_mount=/; reject disable "$root"; mock_mount=$root
mock_fstype=xfs; reject disable "$root"; mock_fstype=ext4
mock_uuid=wrong; reject disable "$root"; mock_uuid=7a328c21-d5fa-420e-ab31-3fa922210767
[[ -L $link && $(readlink -- "$link") == "$unit" ]]
unlink -- "$link"
reject disable "$root"
printf 'not a link\n' > "$link"
reject disable "$root"
rm -- "$link"
ln -s -- /unexpected "$link"
reject disable "$root"
unlink -- "$link"
ln -s -- "$unit" "$link"
printf 'ExecStart=/bin/false\n' >> "$root$unit"
reject disable "$root"
cp -- "$base/../fixes/first-boot-setup.service" "$root$unit"
mv -- "$root/var/backups" "$root/var/saved-backups"
ln -s -- saved-backups "$root/var/backups"
reject disable "$root"
unlink -- "$root/var/backups"
mv -- "$root/var/saved-backups" "$root/var/backups"

bash "$helper" disable "$root"
[[ ! -e $link && ! -L $link ]]
backups=("$root"/var/backups/linux-flashcard-firstboot-toggle-*)
[[ ${#backups[@]} == 1 && -d ${backups[0]} ]]
backup=${backups[0]}
guest_backup=${backup#"$root"}
[[ $(< "$backup/original-state") == enabled && $(< "$backup/original-target") == "$unit" ]]
cmp -- "$root$unit" "$backup/service-unit"
reject disable "$root"
reject restore "$root" /var/backups/../backups/elsewhere
printf 'disabled\n' > "$backup/original-state"
reject restore "$root" "$guest_backup"
printf 'enabled\n' > "$backup/original-state"
printf '/unexpected\n' > "$backup/original-target"
reject restore "$root" "$guest_backup"
printf '%s\n' "$unit" > "$backup/original-target"
printf '\n' >> "$backup/original-target"
reject restore "$root" "$guest_backup"
printf '%s\n' "$unit" > "$backup/original-target"
printf '# changed service\n' >> "$root$unit"
reject restore "$root" "$guest_backup"
cp -- "$backup/service-unit" "$root$unit"
mv -- "$backup/service-unit" "$backup/saved-unit"
ln -s -- saved-unit "$backup/service-unit"
reject restore "$root" "$guest_backup"
unlink -- "$backup/service-unit"
mv -- "$backup/saved-unit" "$backup/service-unit"
ln -s -- /conflicting "$link"
reject restore "$root" "$guest_backup"
[[ $(readlink -- "$link") == /conflicting ]]
unlink -- "$link"
printf 'conflict\n' > "$link"
reject restore "$root" "$guest_backup"
[[ $(< "$link") == conflict ]]
rm -- "$link"
[[ ! -e $link && ! -L $link ]]
bash "$helper" restore "$root" "$guest_backup"
[[ -L $link && $(readlink -- "$link") == "$unit" && -d $backup ]]
cmp -- "$root$unit" "$base/../fixes/first-boot-setup.service"
reject restore "$root" "$guest_backup"
printf 'PASS: mount/root/UUID guards, exact enablement, persistent backup, changed state/target/unit, unsafe paths, conflicts, disable/restore\n'
