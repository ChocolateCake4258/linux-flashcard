#!/bin/bash
# cleanup.sh — освобождение места и удаление временных артефактов сборки.
# Безопасен: не удаляет итоговый ISO и исходный kubuntu.iso.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/config.sh"

require_not_root

log "Очистка временных файлов сборки"

umount_all_under "$CUSTOM_ROOT"
umount_all_under "$ISO_MOUNT_DIR"
umount_all_under "$TEST_MOUNT_DIR"

log "Удаление рабочих папок"
sudo rm -rf "$ISO_MOUNT_DIR" "$EXTRACT_DIR" "$NEW_ISO_DIR"
sudo rmdir "$TEST_MOUNT_DIR" 2>/dev/null || true

if [ -f "$ORIG_ISO" ]; then
    log "Оригинальный ISO оставлен: $ORIG_ISO (для повторной сборки без скачивания)"
    echo "  - удалить его можно вручную: rm -f $ORIG_ISO"
fi

ok "Очистка завершена"