#!/bin/bash
# Keep package failures independent; report them all and retry on the next boot.
set -u

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

record() {
    local name=$1 result=$2
    if (( result == 0 )); then
        OKN=$((OKN + 1))
        log "OK: $name"
    else
        BADN=$((BADN + 1))
        FAILED="${FAILED:+$FAILED }$name"
        log "FAILED: $name (exit $result)"
    fi
}

run() {
    local name=$1
    shift
    "$@"
    local result=$?
    record "$name" "$result"
    return "$result"
}

apt_command() {
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l timeout --kill-after=30s 900s apt-get \
        -o DPkg::Lock::Timeout=120 -o Acquire::Retries=2 \
        -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 \
        -o APT::Update::Error-Mode=any "$@" </dev/null
}

space_ok() {
    local available
    available=$(df -Pk / | { read -r _; read -r _ _ _ free _; printf '%s' "$free"; })
    if [[ ! $available =~ ^[0-9]+$ ]] || (( available < 3 * 1024 * 1024 )); then
        log "Insufficient root space: need at least 3 GiB free (available KiB: ${available:-unknown}). No user data will be removed."
        return 1
    fi
}

pkgs() {
    local package status
    for package in "$@"; do
        if status=$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null) && [[ $status == 'install ok installed' ]]; then
            record "$package" 0
        elif space_ok; then
            run "$package" apt_command install -y --no-install-recommends "$package"
            run "apt-clean:$package" apt_command clean
        else
            record "space:$package" 1
        fi
    done
}

install_jupyter() {
    if [[ ! -f $VENV_DIR/pyvenv.cfg || ! -x $VENV_DIR/bin/python || ! -x $VENV_DIR/bin/jupyter ]] ||
        ! timeout --kill-after=5s 30s "$VENV_DIR/bin/python" -c 'import jupyterlab, notebook'; then
        space_ok || return
        mkdir -p "$VENV_DIR" || return
        timeout --kill-after=30s 900s python3 -m venv "$VENV_DIR" || return
        timeout --kill-after=30s 900s "$VENV_DIR/bin/python" -m pip install \
            --no-cache-dir jupyter jupyterlab || return
        timeout --kill-after=5s 30s "$VENV_DIR/bin/python" -c 'import jupyterlab, notebook' || return
        [[ -f $VENV_DIR/pyvenv.cfg && -x $VENV_DIR/bin/jupyter ]] || return 1
    fi
    mkdir -p "$USER_BIN_DIR" || return
    # A system-wide launcher, but Python packages stay inside the private venv.
    printf '#!/bin/bash\nexec %q "$@"\n' "$VENV_DIR/bin/jupyter" > "$USER_BIN_DIR/jupyter" || return
    chmod 755 "$USER_BIN_DIR/jupyter"
}

install_typescript() {
    # Global TypeScript is intentional, matching the original promised tooling.
    if timeout --kill-after=30s 900s npm list -g --depth=0 typescript >/dev/null 2>&1; then
        record typescript 0
    elif space_ok; then
        run typescript timeout --kill-after=30s 900s npm install -g typescript
    else
        record space:typescript 1
    fi
}

install_snap() {
    local app=$1
    if timeout --kill-after=30s 900s snap list "$app" >/dev/null 2>&1; then
        record "snap:$app" 0
    elif ! space_ok; then
        record "space:snap:$app" 1
    elif [[ $app == code || $app == pycharm-community ]]; then
        run "snap:$app" timeout --kill-after=30s 900s snap install "$app" --classic
    else
        run "snap:$app" timeout --kill-after=30s 900s snap install "$app"
    fi
}

write_status() {
    local status=$1 temporary
    temporary=$(mktemp "$STATE_DIR/.first-boot-status.XXXXXX") || return
    if ! printf 'status=%s\nfailed=%s\nsuccesscounter=%s\n' \
        "$status" "$FAILED" "$OKN" > "$temporary"; then
        rm -f "$temporary"
        return 1
    fi
    chmod 644 "$temporary" && mv -f "$temporary" "$STATE_DIR/first-boot-status"
}

finish() {
    local status=failed
    if (( BADN == 0 )); then
        # Disable does not stop this process; retain both files for reproduction.
        run disable-service systemctl disable first-boot-setup.service
    fi
    (( BADN == 0 )) && status=succeeded
    write_status "$status" || { log 'FAILED: cannot save final status'; return 1; }
    log "Result: $status; successful operations: $OKN; failures: $BADN; failed: ${FAILED:-none}"
    if (( BADN > 0 )); then
        log 'Failed run did not change service enablement. Manual retry: sudo /usr/local/bin/first-boot-setup.sh'
        return 1
    fi
}

# Main (the shell fixture loads only the function definitions above).
if (( EUID != 0 )); then
    printf 'first-boot-setup must run as root\n' >&2
    exit 1
fi
exec 9>/run/lock/linux-flashcard-first-boot.lock || exit 1
if ! flock -n 9; then
    printf 'Another replacement first-boot setup is already running\n' >&2
    exit 1
fi

STATE_DIR=${STATE_DIR:-/var/lib/linux-flashcard}
VENV_DIR=${VENV_DIR:-/opt/linux-flashcard/jupyter}
USER_BIN_DIR=${USER_BIN_DIR:-/usr/local/bin}
LOG=/var/log/first-boot-setup.log
FAILED=''
OKN=0
BADN=0
mkdir -p "$STATE_DIR" || exit 1
# Command output reaches the file and journal once, without extra LOG redirects.
exec > >(tee -a "$LOG") 2>&1
trap 'record interrupted 1; write_status failed; exit 1' INT TERM HUP
write_status running || exit 1
log 'Starting first-boot application setup'

net_ok=0
for (( i=1; i<=12; i++ )); do
    if timeout --kill-after=2s 5s getent hosts archive.ubuntu.com >/dev/null 2>&1; then
        net_ok=1
        break
    fi
    sleep 5
done
(( net_ok == 1 )) || record network 1
run apt-update apt_command update

# Never clean user data: only APT's downloaded package cache.
run apt-clean apt_command clean
pkgs geogebra libreoffice-writer libreoffice-calc libreoffice-impress gdb golang \
    rustc cargo nodejs npm postgresql postgresql-client docker.io net-tools traceroute

if printf 'wireshark-common wireshark-common/install-setuid boolean false\n' | debconf-set-selections; then
    pkgs wireshark
else
    record wireshark-preseed 1
fi
pkgs python3-venv

install_typescript
run jupyter install_jupyter

for app in code pycharm-community firefox; do
    install_snap "$app"
done
run docker-student usermod -aG docker student
finish
exit $?
