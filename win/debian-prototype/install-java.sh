#!/bin/bash
# Explicit console Java profile for the accepted Debian desktop.
set -euo pipefail
export LC_ALL=C DEBIAN_FRONTEND=noninteractive
(( EUID == 0 )) || { printf 'Run inside Linux as root.\n' >&2; exit 1; }
. /etc/os-release
[[ $ID == debian && $VERSION_ID == 13 ]]
state=/var/lib/linux-flashcard
[[ -f $state/desktop-ready && -x /usr/local/bin/pf-verify-java ]]
for file in Hello.java Makefile; do
    [[ -f /usr/local/share/linux-flashcard/examples/java/$file ]]
done
[[ -f /usr/local/share/linux-flashcard/JAVA-START.txt ]]
apt-get -o DPkg::Lock::Timeout=180 update
apt-get -s --no-remove --no-install-recommends --no-upgrade install default-jdk-headless
apt-get -y --no-remove --no-install-recommends --no-upgrade \
    -o DPkg::Lock::Timeout=180 install default-jdk-headless
[[ -z $(dpkg --audit) ]]
install -d "$state/profiles"
dpkg-query -W -f='${binary:Package}\t${Version}\n' default-jdk-headless \
    default-jre-headless java-common ca-certificates-java \
    openjdk-21-jdk-headless openjdk-21-jre-headless \
    > "$state/profiles/java-packages.tsv"
dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Status}\n' \
    > "$state/profiles/java-all-packages.tsv"
{ java -version; javac -version; } > "$state/profiles/java-runtime.txt" 2>&1
printf '[PF_JAVA_INSTALLED] Debian default JDK, javac and jar\n'
cat "$state/profiles/java-packages.tsv" "$state/profiles/java-runtime.txt"
printf 'Run pf-verify-java as your ordinary Linux user.\n'
