#!/bin/bash
# Explicit SSD-overlay checks only; never run automatically during USB boot.
set -euo pipefail
[[ $# == 1 && $1 == --ssd-overlay ]] || { printf 'Usage: verify-prepared-system.sh --ssd-overlay\n' >&2; exit 1; }
[[ $(id -u) == 0 ]] || { printf 'Root is required for service checks.\n' >&2; exit 1; }
[[ $(systemctl is-enabled first-boot-setup.service || true) == disabled ]]
[[ -z $(dpkg --audit) ]]
work=$(mktemp -d /tmp/pf-prepared-check.XXXXXX)
trap 'rm -rf -- "$work"' EXIT
chown student:student "$work"
cd "$work"
printf 'package main\nimport "fmt"\nfunc main() { fmt.Println("PF_GO_OK") }\n' > "$work/hello.go"
printf 'fn main() { println!("PF_RUST_OK"); }\n' > "$work/hello.rs"
printf 'console.log("PF_TS_OK");\n' > "$work/hello.ts"
chmod 644 "$work/hello.go" "$work/hello.rs" "$work/hello.ts"
runuser -u student -- env GOTOOLCHAIN=local GOCACHE="$work/go-cache" go run "$work/hello.go" | grep -Fx PF_GO_OK
runuser -u student -- rustc "$work/hello.rs" -o "$work/hello-rust"
runuser -u student -- "$work/hello-rust" | grep -Fx PF_RUST_OK
runuser -u student -- tsc "$work/hello.ts" --outDir "$work/ts"
runuser -u student -- node "$work/ts/hello.js" | grep -Fx PF_TS_OK
runuser -u student -- gdb --batch -ex 'show version' "$work/hello-rust" >/dev/null
runuser -u student -- /usr/local/bin/jupyter lab --version
/opt/linux-flashcard/jupyter/bin/python -m pip check
runuser -u postgres -- psql -Atqc 'select version();'
runuser -u student -- docker info --format '{{.ServerVersion}}'
runuser -u student -- docker run --rm hello-world
runuser -u student -- wireshark --version
runuser -u student -- /snap/bin/code --version
[[ $(dpkg-query -W -f='${Status}' geogebra) == 'install ok installed' ]]
snap list code pycharm-community firefox
# Strict Snap needs the student's systemd context, not root's inherited cgroup.
systemd-run --user --machine=student@.host --wait --pipe /usr/bin/firefox --version
systemctl is-active docker postgresql
printf 'PASS: package audit, student compilers, Jupyter, PostgreSQL, Docker, Wireshark and editor checks.\n'
