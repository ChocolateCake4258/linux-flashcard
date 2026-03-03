#!/bin/bash
# Скрипт для очистки временных файлов после сборки
source "$(dirname "$0")/config.sh"

set -e

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

if [ "$EUID" -eq 0 ]; then
    echo "Не запускайте от root, используйте sudo."
    exit 1
fi

# Проверка, смонтировано ли что-то внутри CUSTOM_ROOT
if mountpoint -q "$CUSTOM_ROOT/proc" 2>/dev/null; then
    sudo umount "$CUSTOM_ROOT/proc"
fi
if mountpoint -q "$CUSTOM_ROOT/dev" 2>/dev/null; then
    sudo umount "$CUSTOM_ROOT/dev"
fi
if mountpoint -q "$CUSTOM_ROOT/sys" 2>/dev/null; then
    sudo umount "$CUSTOM_ROOT/sys"
fi

# Удаление рабочих папок
log "Удаление временных папок"
sudo rm -rf "$ISO_MOUNT_DIR" "$EXTRACT_DIR" "$NEW_ISO_DIR"

log "Очистка завершена"