#!/bin/bash
# Install the complete remaining application set in the backed-up shared image.
set -euo pipefail
export LC_ALL=C DEBIAN_FRONTEND=noninteractive
(( EUID == 0 ))
. /etc/os-release
[[ $ID == debian && $VERSION_ID == 13 ]]
state=/var/lib/linux-flashcard
[[ -f $state/unified-ready ]]
[[ -f $state/unified-route-proof-passed || -f $state/factory-pending ]]
inputs=${PF_FULL_INPUTS:-/mnt/full-inputs}
[[ -f $inputs/vendor-inputs.json && -x /usr/local/bin/pf-verify-all ]]
[[ ! -f $state/full-suite-installed ]]
dpkg -i "$inputs/packages-microsoft-prod.deb"
apt-get -o DPkg::Lock::Timeout=180 update
packages=(dotnet-sdk-10.0 golang-go rustc cargo nodejs npm sqlite3
          postgresql postgresql-client libreoffice libreoffice-gtk3 libreoffice-l10n-ru libreoffice-java-common
          geogebra docker.io docker-cli wireshark tshark wireless-regdb xvfb xauth xdotool wmctrl x11-utils)
printf 'wireshark-common wireshark-common/install-setuid boolean true\n' | debconf-set-selections
apt-get -s --no-remove --no-install-recommends --no-upgrade install "${packages[@]}" "$inputs/code_1.142.0_amd64.deb"
apt-get -y --no-remove --no-install-recommends --no-upgrade -o DPkg::Lock::Timeout=180 \
    install "${packages[@]}" "$inputs/code_1.142.0_amd64.deb"
[[ -z $(dpkg --audit) ]]

install -d /opt/linux-flashcard /usr/local/lib/linux-flashcard /usr/local/share/linux-flashcard
pycharm=/opt/linux-flashcard/pycharm-2026.2.3
if [[ ! -e $pycharm ]]; then
    stage=/opt/linux-flashcard/.pycharm-staging
    if [[ -d $stage ]]; then [[ -f $state/factory-pending ]] && rm -rf "$stage"; fi
    install -d "$stage"
    tar -xzf "$inputs/pycharm-2026.2.3.tar.gz" -C "$stage"
    [[ -x $stage/pycharm-2026.2.3/bin/pycharm && -x $stage/pycharm-2026.2.3/jbr/bin/java ]]
    mv "$stage/pycharm-2026.2.3" "$pycharm";rmdir "$stage"
fi
[[ -x $pycharm/bin/pycharm && -x $pycharm/jbr/bin/java ]]
if [[ ! -e /opt/linux-flashcard/pycharm ]]; then ln -s pycharm-2026.2.3 /opt/linux-flashcard/pycharm; fi
[[ $(readlink /opt/linux-flashcard/pycharm) == pycharm-2026.2.3 ]]

typescript=/opt/linux-flashcard/typescript-7.0.2
if [[ ! -e $typescript ]]; then
    stage=/opt/linux-flashcard/.typescript-staging
    if [[ -d $stage ]]; then [[ -f $state/factory-pending ]] && rm -rf "$stage"; fi
    install -d "$stage/node_modules/@typescript/typescript-linux-x64"
    tar -xzf "$inputs/typescript-7.0.2.tgz" --strip-components=1 -C "$stage"
    tar -xzf "$inputs/typescript-linux-x64-7.0.2.tgz" --strip-components=1 -C "$stage/node_modules/@typescript/typescript-linux-x64"
    [[ -x $stage/bin/tsc ]];mv "$stage" "$typescript"
fi
if [[ ! -e /usr/local/bin/tsc ]]; then ln -s "$typescript/bin/tsc" /usr/local/bin/tsc; fi
[[ $(readlink /usr/local/bin/tsc) == "$typescript/bin/tsc" ]]

usermod -aG docker,wireshark student
# New application services are started explicitly by the preparation/check flow.
systemctl disable docker.service docker.socket containerd.service postgresql.service
while read -r version cluster rest; do
    [[ -z $version ]] || printf 'manual\n' > "/etc/postgresql/$version/$cluster/start.conf"
done < <(pg_lsclusters --no-header)

documents=/usr/local/share/linux-flashcard/examples/full-suite/documents
if [[ -f $state/factory-pending ]]; then
    # Generate a complete bundle before publishing it; interrupted extraction is resumable.
    if [[ ! -d $documents ]]; then
        stage=/usr/local/share/linux-flashcard/examples/full-suite/.documents-staging
        if [[ -d $stage ]]; then rm -rf "$stage"; fi
        python3 /usr/local/sbin/pf-make-full-examples "$stage"
        mv "$stage" "$documents"
    fi
    for file in lesson.odt lesson.ods lesson.ggb; do [[ -s $documents/$file ]]; done
else
    python3 /usr/local/sbin/pf-make-full-examples "$documents"
fi
install -d "$state/profiles"
cp "$inputs/vendor-inputs.json" "$state/profiles/full-suite-vendor-inputs.json"
dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Status}\n' > "$state/profiles/full-suite-packages.tsv"
touch "$state/full-suite-installed"
sync
printf '[PF_FULL_SUITE_INSTALLED] languages, IDEs, databases, office/math, Docker and Wireshark\n'
