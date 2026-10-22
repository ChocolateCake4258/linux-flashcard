#!/bin/bash
set -eu
if command -v chvt >/dev/null 2>&1; then chvt 1; fi
printf '\033[2J\033[H'
printf 'LinuxFlashcard Debian 13 / XFCE\n\n'
printf 'Create a password for student.\n\n'
until LC_ALL=C passwd student; do printf 'Please repeat password setup.\n'; done
touch /var/lib/linux-flashcard/password-ready
systemctl unmask getty@tty1.service
printf 'Password saved. Starting the graphical login...\n'
