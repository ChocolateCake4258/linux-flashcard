#!/bin/bash
# Explicit Python/notebook profile for the accepted Debian desktop.
set -euo pipefail
export LC_ALL=C DEBIAN_FRONTEND=noninteractive
(( EUID == 0 )) || { printf 'Run inside Linux as root.\n' >&2; exit 1; }
. /etc/os-release
[[ $ID == debian && $VERSION_ID == 13 ]]
state=/var/lib/linux-flashcard
[[ -f $state/desktop-ready ]]
[[ -x /usr/local/bin/pf-verify-python && -x /usr/local/bin/pf-jupyter ]]
for file in hello.py lesson.ipynb demo-package/pyproject.toml demo-package/pf_lesson_demo.py; do
    [[ -f /usr/local/share/linux-flashcard/examples/python/$file ]]
done
[[ -f /usr/local/share/linux-flashcard/PYTHON-START.txt ]]
packages=(python3 python3-pip python3-venv python3-setuptools python3-wheel
          jupyter-notebook python3-ipykernel python3-nbconvert firefox-esr firefox-esr-l10n-ru)
apt-get -o DPkg::Lock::Timeout=180 update
apt-get -s --no-remove --no-install-recommends --no-upgrade install "${packages[@]}"
apt-get -y --no-remove --no-install-recommends --no-upgrade \
    -o DPkg::Lock::Timeout=180 install "${packages[@]}"
[[ -z $(dpkg --audit) ]]
install -d "$state/profiles"
dpkg-query -W -f='${binary:Package}\t${Version}\n' "${packages[@]}" \
    python3-notebook python3-nbformat python3-jupyter-client \
    > "$state/profiles/python-packages.tsv"
dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Status}\n' \
    > "$state/profiles/python-all-packages.tsv"
printf '[PF_PYTHON_INSTALLED] Python, pip, venv, Jupyter and Firefox ESR\n'
cat "$state/profiles/python-packages.tsv"
printf 'Run pf-verify-python as your ordinary Linux user.\n'
