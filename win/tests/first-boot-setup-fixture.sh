#!/bin/bash
# No root access, package installations, or writes to system paths.
set -euo pipefail
base=$(dirname "$(dirname "$(realpath "$0")")")
script=$base/fixes/first-boot-setup.sh
service=$base/fixes/first-boot-setup.service
bash -n "$script" "$0"
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$script" "$0"
else
    printf 'SKIP: shellcheck is not installed\n'
fi

definitions=''
while IFS= read -r line; do
    [[ $line == '# Main '* ]] && break
    definitions+="$line"$'\n'
done < "$script"
eval "$definitions"
FAILED=''; OKN=0; BADN=0
log() { :; }

record example 7
[[ $FAILED == example && $BADN == 1 && $OKN == 0 ]]
run good true
if run bad false; then exit 1; fi
[[ $FAILED == 'example bad' && $BADN == 2 && $OKN == 1 ]]

timeout() {
    [[ $* == '--kill-after=30s 900s apt-get -o DPkg::Lock::Timeout=120 -o Acquire::Retries=2 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 -o APT::Update::Error-Mode=any install -y --no-install-recommends wireshark' ]]
    [[ $DEBIAN_FRONTEND == noninteractive ]]
    [[ $NEEDRESTART_MODE == l ]]
    if IFS= read -r unexpected; then return 1; fi
}
apt_command install -y --no-install-recommends wireshark <<< 'stdin must not reach APT'
unset -f timeout

df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/mock 9000000 5000000 %s 60%% /\n' "$FREE"; }
FREE=3145728
space_ok
FREE=3145727
if space_ok; then exit 1; fi
FREE=unknown
if space_ok; then exit 1; fi
unset -f df

# A failed package must not prevent the next package, and each gets cache cleanup.
space_definition=$(declare -f space_ok)
space_ok() { return 0; }
dpkg-query() { return 1; }
calls=''
apt_command() {
    calls+="|$*"
    [[ $* != 'install -y --no-install-recommends broken' ]]
}
if pkgs broken working; then :; else exit 1; fi
[[ $calls == '|install -y --no-install-recommends broken|clean|install -y --no-install-recommends working|clean' ]]
[[ $FAILED == *broken* ]]

# Only the editor/IDE Snaps use classic confinement; Firefox remains strict.
calls=''
timeout() {
    calls+="|$*"
    [[ $3 == snap && $4 == install ]]
}
before_ok=$OKN
before_bad=$BADN
for app in code pycharm-community firefox; do install_snap "$app"; done
[[ $calls == '|--kill-after=30s 900s snap list code|--kill-after=30s 900s snap install code --classic|--kill-after=30s 900s snap list pycharm-community|--kill-after=30s 900s snap install pycharm-community --classic|--kill-after=30s 900s snap list firefox|--kill-after=30s 900s snap install firefox' ]]
[[ $OKN == $((before_ok + 3)) && $BADN == "$before_bad" ]]

STATE_DIR=$(mktemp -d)
trap 'rm -rf "$STATE_DIR"' EXIT
VENV_DIR=$STATE_DIR/venv
USER_BIN_DIR=$STATE_DIR/bin
timeout() { return 1; }
if run jupyter-venv install_jupyter; then exit 1; fi
[[ $FAILED == *jupyter-venv* && ! -e $USER_BIN_DIR/jupyter ]]
timeout() {
    [[ $* == "--kill-after=30s 900s python3 -m venv $VENV_DIR" ]]
}
if run jupyter-pip install_jupyter; then exit 1; fi
[[ $FAILED == *jupyter-pip* && ! -e $USER_BIN_DIR/jupyter ]]
if run snap:code timeout --kill-after=30s 900s snap install code --classic; then exit 1; fi
if run apt-update false; then exit 1; fi
if run typescript false; then exit 1; fi
if run docker-student false; then exit 1; fi
[[ $FAILED == *'snap:code apt-update typescript docker-student' ]]
timeout() {
    if [[ $1 == --kill-after=5s && $2 == 30s ]]; then
        shift 2
        "$@"
    else
        return 0
    fi
}
# This fixture executable stands in for the venv Python import validation.
mkdir -p "$VENV_DIR/bin"
printf '#!/bin/bash\n[[ $1 == -c && $2 == "import jupyterlab, notebook" ]]\n' > "$VENV_DIR/bin/python"
printf '#!/bin/bash\nexit 0\n' > "$VENV_DIR/bin/jupyter"
printf 'include-system-site-packages = false\n' > "$VENV_DIR/pyvenv.cfg"
chmod 755 "$VENV_DIR/bin/python" "$VENV_DIR/bin/jupyter"
run jupyter install_jupyter
[[ -x $USER_BIN_DIR/jupyter ]]
bash -n "$USER_BIN_DIR/jupyter"
grep -Fx "exec $VENV_DIR/bin/jupyter \"\$@\"" "$USER_BIN_DIR/jupyter" >/dev/null

# Resume at 2.8 GiB free: validated apps bypass all installs and disk guards.
eval "$space_definition"
df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/mock 9000000 6000000 2936012 70%% /\n'; }
if space_ok; then exit 1; fi
dpkg-query() {
    [[ $1 == -W && $2 == '-f=${Status}' ]] || return 1
    case $3 in
        installed) printf 'install ok installed';;
        partial) printf 'install ok unpacked';;
        query-error) printf 'install ok installed'; return 1;;
        *) return 1;;
    esac
}
calls=''
before_ok=$OKN
before_bad=$BADN
pkgs installed
[[ $OKN == $((before_ok + 1)) && $BADN == "$before_bad" && -z $calls ]]
pkgs partial query-error missing
[[ $BADN == $((before_bad + 3)) && -z $calls ]]

timeout() {
    case "$*" in
        '--kill-after=30s 900s npm list -g --depth=0 typescript' | \
        '--kill-after=30s 900s snap list code' | \
        '--kill-after=30s 900s snap list pycharm-community' | \
        '--kill-after=30s 900s snap list firefox') return 0;;
        "--kill-after=5s 30s $VENV_DIR/bin/python -c import jupyterlab, notebook")
            shift 2; "$@";;
        *) calls+="|unexpected:$*"; return 1;;
    esac
}
before_ok=$OKN
before_bad=$BADN
install_typescript
for app in code pycharm-community firefox; do install_snap "$app"; done
rm -f "$USER_BIN_DIR/jupyter"
run jupyter install_jupyter
[[ $OKN == $((before_ok + 5)) && $BADN == "$before_bad" && -z $calls ]]
[[ -x $USER_BIN_DIR/jupyter ]]
bash -n "$USER_BIN_DIR/jupyter"
grep -Fx "exec $VENV_DIR/bin/jupyter \"\$@\"" "$USER_BIN_DIR/jupyter" >/dev/null

# An existing directory alone is not success: both notebook imports must work.
printf '#!/bin/bash\nexit 1\n' > "$VENV_DIR/bin/python"
before_bad=$BADN
if run jupyter install_jupyter; then exit 1; fi
[[ $BADN == $((before_bad + 1)) && -z $calls ]]

# Missing apps are still rejected below 3 GiB, without npm/snap/pip installs.
timeout() {
    case "$*" in
        '--kill-after=30s 900s npm list -g --depth=0 typescript' | \
        '--kill-after=30s 900s snap list missing') return 1;;
        *) calls+="|unexpected:$*"; return 1;;
    esac
}
before_bad=$BADN
install_typescript
install_snap missing
rm -f "$VENV_DIR/pyvenv.cfg"
if run jupyter install_jupyter; then exit 1; fi
[[ $BADN == $((before_bad + 3)) && -z $calls ]]
unset -f timeout
unset -f df dpkg-query

systemctl() { [[ $* == 'disable first-boot-setup.service' ]]; disabled=yes; }
disabled=no
if finish; then exit 1; fi
[[ $disabled == no ]]
grep -qx 'status=failed' "$STATE_DIR/first-boot-status"
grep -qx "failed=$FAILED" "$STATE_DIR/first-boot-status"
FAILED=''; BADN=0
finish
[[ $disabled == yes ]]
grep -qx 'status=succeeded' "$STATE_DIR/first-boot-status"
grep -qx "successcounter=$OKN" "$STATE_DIR/first-boot-status"
systemctl() { return 1; }
if finish; then exit 1; fi
[[ $FAILED == disable-service ]]
grep -qx 'status=failed' "$STATE_DIR/first-boot-status"

grep -qx 'Type=exec' "$service"
grep -qx 'After=network.target' "$service"
grep -qx 'WantedBy=multi-user.target' "$service"
grep -Eq '^pkgs .*\bgeogebra\b' "$script"
grep -qx 'for app in code pycharm-community firefox; do' "$script"
if grep -qi 'geogebra-discovery' "$script"; then
    printf 'GeoGebra Discovery must not be in the first-boot policy\n' >&2
    exit 1
fi
if grep -Eq 'RemainAfterExit|Type=oneshot|--break-system-packages|pip3 install|snap install wireshark|setcap|chmod.*[+]s' "$script" "$service"; then
    printf 'Forbidden first-boot behavior found\n' >&2
    exit 1
fi
printf 'PASS: syntax, bounded noninteractive APT, accounting, 3 GiB disk guard, Snap confinement, APT GeoGebra/Firefox Snap policy, installed-app resume at 2.8 GiB, launcher refresh without pip, venv/pip failures, atomic status, retry policy, service constraints\n'
