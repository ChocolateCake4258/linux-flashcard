#!/bin/bash
# Exercise real tools as the ordinary user, using only a private temporary tree.
set -euo pipefail
export LC_ALL=C
(( EUID != 0 )) || { printf 'Run as an ordinary Linux user, without sudo.\n' >&2; exit 1; }
work=$(mktemp -d /tmp/pf-cli-check.XXXXXX)
trap 'rm -rf -- "$work"' EXIT
export HOME="$work/home" XDG_CACHE_HOME="$work/cache" XDG_CONFIG_HOME="$work/config" XDG_DATA_HOME="$work/data" XDG_STATE_HOME="$work/state"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
mkdir -p "$HOME" "$work/project"
cp /usr/local/share/linux-flashcard/examples/cli/{hello.c,hello.cpp,Makefile} "$work/project/"
cd "$work/project"

make check
git init -q
git -c user.name='CLI check' -c user.email='cli-check@example.invalid' \
    -c commit.gpgsign=false add hello.c hello.cpp Makefile
git -c user.name='CLI check' -c user.email='cli-check@example.invalid' \
    -c commit.gpgsign=false commit -qm 'Initial CLI exercise'
git cat-file -e HEAD:hello.c
git diff --exit-code
printf '[PASS] Git created a real local commit\n'

vim -Nu NONE -i NONE -n -es -c 'call setline(1, "Vim OK")' -c wq vim-check.txt
[[ $(<vim-check.txt) == 'Vim OK' ]]
nvim --headless -u NONE -i NONE -n -c 'call setline(1, "Neovim OK")' -c wq nvim-check.txt
[[ $(<nvim-check.txt) == 'Neovim OK' ]]
printf '[PASS] Vim and Neovim wrote the expected test content\n'

gdb --batch --quiet --nx \
    -ex 'set pagination off' -ex 'set disable-randomization off' \
    -ex 'set debuginfod enabled off' \
    -ex 'break add' -ex run -ex 'print left + right' -ex continue \
    --args build/hello-c > "$work/gdb.log" 2>&1
cat "$work/gdb.log"
grep -Fq 'Breakpoint 1, add' "$work/gdb.log"
grep -Fq '$1 = 42' "$work/gdb.log"
grep -Fq 'exited normally' "$work/gdb.log"
printf '[PASS] GDB stopped at add(), evaluated 42 and completed the program\n'
printf '[PF_CLI_VERIFIED] C, C++, Make, Git, Vim, Neovim and GDB work as uid=%s\n' "$(id -u)"
