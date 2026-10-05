#!/bin/bash
# Run with sudo env TMPDIR=/tmp/opencode; no real mounts or block devices.
set -euo pipefail
[[ $EUID == 0 && ${TMPDIR:-} == /tmp/opencode ]] || {
    printf 'Usage: sudo env TMPDIR=/tmp/opencode bash %s\n' "$0" >&2
    exit 1
}
base=$(dirname -- "$(realpath -e -- "$0")")
payload=$base/../fixes
helper=$payload/apply-to-mounted-root.sh
temporary=$(mktemp -d /tmp/opencode/apply-payload-fixture.XXXXXXXX)
readonly temporary
cleanup() {
    # Never remove TMPDIR itself, other fixtures, or a caller-supplied path.
    [[ $temporary == /tmp/opencode/apply-payload-fixture.* && -d $temporary && ! -L $temporary ]] &&
        rm -rf -- "$temporary"
}
trap cleanup EXIT
export TMPDIR=$temporary
trap 'printf "FAIL: line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

sources=(first-boot-setup.sh first-boot-setup.service sddm-software.conf qemu-software-rendering.sh jupyter-lab.desktop firefox-snap.pref)
destinations=(usr/local/bin/first-boot-setup.sh etc/systemd/system/first-boot-setup.service etc/sddm.conf.d/90-pf-renderer.conf etc/profile.d/pf-qemu-software-rendering.sh usr/share/applications/jupyter-lab.desktop etc/apt/preferences.d/99-pf-firefox-snap)
modes=(755 644 644 644 644 644)

# Exported mocks exercise the helper with strict argument checks.
findmnt() {
    [[ $# == 5 && $1 == -nr && $2 == -o && $4 == --target && $5 == "$root" ]] || return 1
    case $3 in
        TARGET) printf '%s\n' "$root";;
        SOURCE) printf '%s\n' /dev/nbd0;;
        FSTYPE) printf '%s\n' ext4;;
        *) return 1;;
    esac
}
blockdev() {
    [[ $# == 2 && $1 == --getsize64 && $2 == /dev/nbd0 ]] || return 1
    printf '%s\n' "$mock_size"
}
blkid() {
    [[ $# == 5 && $1 == -s && $2 == UUID && $3 == -o && $4 == value && $5 == /dev/nbd0 ]] || return 1
    printf '%s\n' "$mock_uuid"
}
systemctl() {
    printf 'Unexpected systemctl invocation: %s\n' "$*" >> "$service_log"
    return 1
}
export -f findmnt blockdev blkid systemctl
export root mock_size=22545432576 mock_uuid=7a328c21-d5fa-420e-ab31-3fa922210767
export service_log=$temporary/systemctl.log

prepare() {
    root=$temporary/$1
    originals=$temporary/$1-originals
    mkdir -p "$root/var/backups" "$root/etc/systemd/system/multi-user.target.wants"
    for index in "${!destinations[@]}"; do
        destination=${destinations[$index]}
        mkdir -p "$root/$(dirname -- "$destination")" "$originals/$(dirname -- "$destination")"
        printf 'Original fixture file: %s\n' "$destination" > "$root/$destination"
        chmod 600 "$root/$destination"
        cp -a -- "$root/$destination" "$originals/$destination"
    done
    link=$root/etc/systemd/system/multi-user.target.wants/first-boot-setup.service
}
run_helper() {
    local status=0
    bash "$helper" "$root" "${layout_args[@]}" > "$temporary/output" 2>&1 || status=$?
    if [[ -e $service_log ]]; then
        printf 'FAIL: helper invoked systemctl: %s\n' "$(< "$service_log")" >&2
        exit 1
    fi
    return "$status"
}
reject() {
    if run_helper; then
        printf 'FAIL: helper accepted %s\n' "$1" >&2
        exit 1
    fi
    [[ $(< "$temporary/output") == *"$2"* ]] || {
        printf 'FAIL: %s failed for an unexpected reason: %s\n' "$1" "$(< "$temporary/output")" >&2
        exit 1
    }
}
verify_originals() {
    local index
    for index in "${!destinations[@]}"; do
        cmp -- "$originals/${destinations[$index]}" "$root/${destinations[$index]}"
        [[ $(stat -c %a -- "$root/${destinations[$index]}") == 600 ]]
    done
    local backups=("$root"/var/backups/*)
    [[ ! -e ${backups[0]} ]]
}

cases=0
layout_args=()
for profile in default Legacy Esp2GiB; do
    layout_args=()
    mock_size=22545432576
    if [[ $profile != default ]]; then layout_args=("$profile"); fi
    if [[ $profile == Esp2GiB ]]; then mock_size=28891414528; fi
    for state in disabled enabled; do
        prepare "$profile-$state"
        if [[ $state == enabled ]]; then
            ln -s -- /etc/systemd/system/first-boot-setup.service "$link"
            link_before=$(stat -c '%i:%a:%u:%g:%Y:%Z' -- "$link")
        fi
        run_helper
        backups=("$root"/var/backups/linux-flashcard-firstboot-*)
        [[ ${#backups[@]} == 1 && -d ${backups[0]} && $(stat -c %a -- "${backups[0]}") == 755 ]]
        for index in "${!sources[@]}"; do
            destination=${destinations[$index]}
            [[ -f $root/$destination && ! -L $root/$destination ]]
            cmp -- "$payload/${sources[$index]}" "$root/$destination"
            [[ $(stat -c '%a:%u:%g' -- "$root/$destination") == "${modes[$index]}:0:0" ]]
            cmp -- "$originals/$destination" "${backups[0]}/$destination"
            [[ $(stat -c %a -- "${backups[0]}/$destination") == 600 ]]
        done
        if [[ $state == enabled ]]; then
            [[ -L $link && $(readlink -- "$link") == /etc/systemd/system/first-boot-setup.service ]]
            [[ $(stat -c '%i:%a:%u:%g:%Y:%Z' -- "$link") == "$link_before" ]]
        else
            [[ ! -e $link && ! -L $link ]]
        fi
        cases=$((cases + 1))
    done

    prepare wrong-uuid
    mock_uuid=wrong
    reject 'wrong UUID' 'Unexpected root partition geometry or UUID.'
    verify_originals
    cases=$((cases + 1))
    mock_uuid=7a328c21-d5fa-420e-ab31-3fa922210767
    prepare wrong-geometry
    mock_size=22545432575
    reject 'wrong geometry' 'Unexpected root partition geometry or UUID.'
    verify_originals
    cases=$((cases + 1))
    prepare mismatched-profile
    if [[ $profile == Esp2GiB ]]; then mock_size=22545432576; else mock_size=28891414528; fi
    reject 'mismatched layout profile' 'Unexpected root partition geometry or UUID.'
    verify_originals
    cases=$((cases + 1))
done

layout_args=(Unknown)
prepare unknown-profile
reject 'unknown layout profile' 'Unknown layout; expected Legacy or Esp2GiB.'
verify_originals
cases=$((cases + 1))
layout_args=('')
reject 'empty layout profile' 'Unknown layout; expected Legacy or Esp2GiB.'
verify_originals
cases=$((cases + 1))
layout_args=()
mock_size=22545432576

for index in "${!destinations[@]}"; do
    prepare "symlink-$index"
    destination=$root/${destinations[$index]}
    target=$temporary/symlink-target-$index
    printf 'Do not overwrite this symlink target\n' > "$target"
    cp -- "$target" "$target.original"
    rm -- "$destination"
    ln -s -- "$target" "$destination"
    reject "destination symlink ${destinations[$index]}" "Refusing symlink: $destination"
    [[ -L $destination && $(readlink -- "$destination") == "$target" ]]
    cmp -- "$target.original" "$target"
    cases=$((cases + 1))
done
printf 'PASS: %s cases; six payloads, backups, modes, disabled/enabled preservation for default/Legacy/Esp2GiB, UUID/geometry/profile rejection, all destination symlinks, no systemctl invocation\n' "$cases"
