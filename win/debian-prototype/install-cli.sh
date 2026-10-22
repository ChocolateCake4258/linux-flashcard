#!/bin/bash
# Explicit, optional CLI profile for an already-prepared Debian guest.
set -euo pipefail
export LC_ALL=C DEBIAN_FRONTEND=noninteractive
(( EUID == 0 )) || { printf 'Run inside Linux as root.\n' >&2; exit 1; }
. /etc/os-release
[[ $ID == debian && $VERSION_ID == 13 ]]
state=/var/lib/linux-flashcard
[[ -f $state/desktop-ready ]]
[[ -x /usr/local/bin/pf-verify-cli ]]
for file in hello.c hello.cpp Makefile; do
    [[ -f /usr/local/share/linux-flashcard/examples/cli/$file ]]
done
[[ -f /usr/local/share/linux-flashcard/CLI-START.txt ]]

apt-get -o DPkg::Lock::Timeout=180 update
packages=(git vim neovim build-essential gdb)
apt-get -s --no-remove --no-install-recommends --no-upgrade install "${packages[@]}"
apt-get -y --no-remove --no-install-recommends --no-upgrade \
    -o DPkg::Lock::Timeout=180 install "${packages[@]}"
[[ -z $(dpkg --audit) ]]
install -d "$state/profiles"
dpkg-query -W -f='${binary:Package}\t${Version}\n' \
    git vim neovim gcc g++ gdb make build-essential libc6-dev \
    > "$state/profiles/cli-packages.tsv"
dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Status}\n' \
    > "$state/profiles/cli-all-packages.tsv"
printf '[PF_CLI_INSTALLED] Git, Vim, Neovim, GCC/G++, GDB, Make\n'
cat "$state/profiles/cli-packages.tsv"
printf 'Run pf-verify-cli as your ordinary Linux user to check this profile.\n'
