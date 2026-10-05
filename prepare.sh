#!/bin/bash
# Установка утилит, необходимых для сборки, на хост-систему (Debian/Ubuntu).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

log "Обновление индекса пакетов и установка утилит сборки..."

sudo apt update
sudo apt install -y --no-install-recommends \
    wget \
    curl \
    xorriso \
    isolinux \
    rsync \
    mount \
    squashfs-tools \
    syslinux-common \
    p7zip-full \
    ca-certificates

log "Готово. Проверка доступности ключевых утилит:"
for cmd in wget curl xorriso unsquashfs mksquashfs rsync mount; do
    command -v "$cmd" &>/dev/null && echo "  ок: $cmd" || { echo "  ОШИБКА: $cmd не установлен"; exit 1; }
done