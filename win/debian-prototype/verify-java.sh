#!/bin/bash
# Compile/run a real Java project, using only our private temporary tree.
set -euo pipefail
export LC_ALL=C.UTF-8
(( EUID != 0 )) || { printf 'Run as an ordinary Linux user, without sudo.\n' >&2; exit 1; }
work=$(mktemp -d /tmp/pf-java-check.XXXXXX)
trap 'rm -rf -- "$work"' EXIT
export HOME="$work/home" XDG_CACHE_HOME="$work/cache" XDG_CONFIG_HOME="$work/config" XDG_DATA_HOME="$work/data" XDG_STATE_HOME="$work/state"
mkdir -p "$HOME" "$work/tmp" "$work/project" "$work/reopened"
unset _JAVA_OPTIONS JDK_JAVA_OPTIONS CLASSPATH
export JAVA_TOOL_OPTIONS="-Duser.home=$HOME -Djava.io.tmpdir=$work/tmp -XX:-UsePerfData"
cp /usr/local/share/linux-flashcard/examples/java/{Hello.java,Makefile} "$work/project/"
cd "$work/project"
make check
printf 'Java: 42\nПривет, LinuxFlashcard!\n' > "$work/expected.txt"
cmp "$work/expected.txt" result.txt
printf '[PASS] javac compiled Java 21; class/JAR output and UTF-8 result match\n'
javap -classpath build/classes -l Hello > "$work/debug-info.txt"
grep -Fq 'LineNumberTable:' "$work/debug-info.txt"
grep -Fq 'LocalVariableTable:' "$work/debug-info.txt"
printf '[PASS] Compiled class contains source line and local-variable debug information\n'
cp build/hello.jar "$work/reopened/application.jar"
cd "$work/reopened"
jar --list --file application.jar > "$work/jar-entries.txt"
grep -Fxq 'Hello.class' "$work/jar-entries.txt"
java -jar application.jar > "$work/reopened-output.txt"
cmp "$work/expected.txt" "$work/reopened-output.txt"
cmp "$work/expected.txt" result.txt
printf '[PASS] Reopened JAR runs independently of sources/build classes and writes its result\n'
printf '[PF_JAVA_VERIFIED] javac, java, jar, javap, Make and UTF-8 output work as uid=%s\n' "$(id -u)"
