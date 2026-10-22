#!/bin/bash
# Apply system defaults to the Debian file guest without rewriting user prefs.
set -euo pipefail
export LC_ALL=C
(( EUID == 0 )) || { printf 'Run inside Linux as root.\n' >&2; exit 1; }
. /etc/os-release
[[ $ID == debian && $VERSION_ID == 13 ]]
[[ -f /etc/lightdm/lightdm.conf.d/50-pf-desktop.conf && -x /usr/local/bin/pf-start-xfce ]]

for locale in ru_RU.UTF-8 en_US.UTF-8; do
    if ! grep -Eq "^${locale//./\\.}[[:space:]]+UTF-8([[:space:]]|$)" /etc/locale.gen; then
        printf '%s UTF-8\n' "$locale" >> /etc/locale.gen
    fi
done
locale-gen
# Keep an existing explicit language choice; replace only the minimal C default.
language=$(sed -n 's/^LANG=//p' /etc/default/locale | tr -d '"')
case $language in
    ''|C|C.UTF-8|C.utf8|POSIX) update-locale LANG=ru_RU.UTF-8 LANGUAGE=ru:en ;;
esac

keyboard=/etc/X11/xorg.conf.d/30-pf-keyboard.conf
work=$(mktemp -d /tmp/pf-usability.XXXXXX)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/keyboard.conf" <<'EOF'
# Default layouts for the graphical login and users using system defaults.
# User-specific XFCE keyboard preferences retain priority.
Section "InputClass"
    Identifier "LinuxFlashcard keyboard defaults"
    MatchIsKeyboard "on"
    Option "XkbLayout" "us,ru"
    Option "XkbOptions" "grp:alt_shift_toggle"
EndSection
EOF
if [[ -e $keyboard || -L $keyboard ]]; then
    [[ -f $keyboard && ! -L $keyboard ]] && cmp -s "$work/keyboard.conf" "$keyboard" || {
        printf 'Existing keyboard configuration differs: %s\n' "$keyboard" >&2
        exit 1
    }
else
    install -m 644 "$work/keyboard.conf" "$keyboard"
fi

zone=$(readlink /etc/localtime || true)
case $zone in
    /usr/share/zoneinfo/Etc/UTC|/usr/share/zoneinfo/UTC|../usr/share/zoneinfo/Etc/UTC)
        ln -sfn /usr/share/zoneinfo/Europe/Moscow /etc/localtime ;;
esac
printf '[PF_USABILITY_READY] locale=%s timezone=%s layouts=us,ru toggle=Alt+Shift\n' \
    "$(grep '^LANG=' /etc/default/locale)" "$(readlink /etc/localtime)"
