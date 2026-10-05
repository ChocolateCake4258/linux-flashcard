#!/bin/bash
# build.sh — сборка кастомного ISO Kubuntu с предустановленным ПО.
# Использование:
#   ./build.sh            — полная сборка
#   ./build.sh --keep     — не удалять временные папки при прерывании
#   ALLOW_ROOT=1 ./build.sh — запуск от root (для CI/контейнеров)
#   sudo считается доступным (скрипту нужны права для mount/chroot).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/config.sh"

KEEP_ON_ERROR=0
[ "${1:-}" = "--keep" ] && KEEP_ON_ERROR=1

require_not_root

# Проверка наличия нужных утилит до начала работы
if ! require_cmds sudo wget curl xorriso unsquashfs mksquashfs rsync mount umount; then
    echo "Запустите ./prepare.sh для установки недостающих утилит." >&2
    exit 1
fi

log "=== Начало сборки кастомного ISO ($OUTPUT_ISO) ==="
log "Рабочая директория: $WORK_DIR"

# Рабочие папки
mkdir -p "$ISO_MOUNT_DIR" "$EXTRACT_DIR" "$NEW_ISO_DIR"
check_space "$WORK_DIR" "$MIN_FREE_MB_HOST"

# ---------------------------------------------------------------- 1. Скачивание
if [ ! -f "$ORIG_ISO" ]; then
    log "Скачивание оригинального ISO: $ISO_URL (продолжаемо, ~5.5 ГБ)"
    wget -c -O "$ORIG_ISO" "$ISO_URL" 2>&1 | tail -20
else
    log "Оригинальный ISO уже существует: $ORIG_ISO"
fi
[ -s "$ORIG_ISO" ] || die "Исходный ISO пуст/не скачан: $ORIG_ISO"

if ! verify_iso "$ORIG_ISO" "$SHA256SUMS_URL"; then
    warn "SHA256 не совпала с официальной (или не получили сумму)."
    warn "Файл может быть битым. Выполните: rm -f $ORIG_ISO  — и повторите."
    read -r -p "Продолжить несмотря на несовпадение? [y/N]: " ans
    [ "${ans:-N}" = "y" ] || die "Сборка отменена."
fi

# ---------------------------------------------------- 2. Распаковка ISO и FS
log "Монтирование и распаковка ISO"
rm -rf "$EXTRACT_DIR"/*
sudo mount -o loop "$ORIG_ISO" "$ISO_MOUNT_DIR" || die "не удалось смонтировать ISO"
trap 'umount_all_under "$ISO_MOUNT_DIR"; trap_cleanup; exit 1' INT TERM EXIT

sudo rsync --exclude=/casper/filesystem.squashfs -a "$ISO_MOUNT_DIR/" "$EXTRACT_DIR/"
check_space "$WORK_DIR" "$MIN_FREE_MB_BUILD"

log "Распаковка filesystem.squashfs (займёт 10+ минут)"
sudo unsquashfs -d "$CUSTOM_ROOT" "$ISO_MOUNT_DIR/casper/filesystem.squashfs"
sudo umount "$ISO_MOUNT_DIR"

# ------------------------------------------------------------ 3. Подготовка chroot
log "Подготовка chroot-окружения"
sudo mount --bind /proc "$CUSTOM_ROOT/proc"
sudo mount --bind /dev "$CUSTOM_ROOT/dev"
sudo mount --bind /sys "$CUSTOM_ROOT/sys"
sudo cp /etc/resolv.conf "$CUSTOM_ROOT/etc/"

sudo cp "$SCRIPT_DIR/packages.list" "$CUSTOM_ROOT/packages.list"
sudo cp "$SCRIPT_DIR/install-chroot.sh" "$CUSTOM_ROOT/install-chroot.sh"
sudo cp "$SCRIPT_DIR/config.sh" "$CUSTOM_ROOT/config.sh" 2>/dev/null || true
sudo chmod +x "$CUSTOM_ROOT/install-chroot.sh"

# -------------------------------------------------- 4. Установка ПО внутри chroot
log "Запуск install-chroot.sh внутри chroot (это займёт очень много времени)"
sudo chroot "$CUSTOM_ROOT" /bin/bash -c "/install-chroot.sh"

# -------------------------------------------------- 5. Очистка и обновление манифеста
log "Очистка chroot и обновление манифеста"
sudo rm -f "$CUSTOM_ROOT/install-chroot.sh" "$CUSTOM_ROOT/packages.list" "$CUSTOM_ROOT/config.sh"
sudo rm -f "$CUSTOM_ROOT/etc/resolv.conf"
umount_all_under "$CUSTOM_ROOT"

sudo chroot "$CUSTOM_ROOT" dpkg-query -W --showformat='${Package} ${Version}\n' | sudo tee "$EXTRACT_DIR/casper/filesystem.manifest" > /dev/null
sudo cp "$EXTRACT_DIR/casper/filesystem.manifest" "$EXTRACT_DIR/casper/filesystem.manifest-desktop"
sudo du -sx --block-size=1 "$CUSTOM_ROOT" | cut -f1 | sudo tee "$EXTRACT_DIR/casper/filesystem.size" > /dev/null

# ------------------------------------------------------ 6. Пересборка squashfs
log "Пересборка filesystem.squashfs ($SQUASHFS_COMP)"
sudo rm -f "$EXTRACT_DIR/casper/filesystem.squashfs"
sudo mksquashfs "$CUSTOM_ROOT" "$EXTRACT_DIR/casper/filesystem.squashfs" $SQUASHFS_COMP -no-progress
sudo rm -rf "$CUSTOM_ROOT"

# ----------------------------------------------------------------- 7. Новый ISO
log "Сборка нового ISO через xorriso"
sudo rsync -a "$EXTRACT_DIR/" "$NEW_ISO_DIR/"

ISOHDPFX=""
for cand in /usr/lib/ISOLINUX/isohdpfx.bin /usr/lib/syslinux/isohdpfx.bin; do
    [ -f "$cand" ] && ISOHDPFX="$cand" && break
done
[ -n "$ISOHDPFX" ] && log "isohybrid-mbr: $ISOHDPFX" || warn "isohdpfx.bin не найден — ISO может не быть гибридным"

sudo rm -f "$WORK_DIR/$OUTPUT_ISO"
sudo xorriso -as mkisofs \
    -volid "Custom Kubuntu" \
    -output "$WORK_DIR/$OUTPUT_ISO" \
    ${ISOHDPFX:+-isohybrid-mbr "$ISOHDPFX"} \
    -c boot.cat \
    -b boot/grub/i386-pc/eltorito.img \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -eltorito-alt-boot \
    -e EFI/boot/bootx64.efi \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    -iso-level 3 \
    -rock -joliet \
    "$NEW_ISO_DIR/"

# ------------------------------------------------- 8. Проверка готового ISO
log "Проверка содержимого собранного ISO"
mkdir -p "$TEST_MOUNT_DIR"
if sudo mount -o loop "$WORK_DIR/$OUTPUT_ISO" "$TEST_MOUNT_DIR"; then
    for need in .disk casper/filesystem.squashfs; do
        if [ -e "$TEST_MOUNT_DIR/$need" ]; then
            ok "$need присутствует"
        else
            warn "ОТСУТСТВУЕТ: $need"
        fi
    done
    sudo umount "$TEST_MOUNT_DIR" && rmdir "$TEST_MOUNT_DIR"
else
    warn "Не удалось смонтировать готовый ISO"
fi

# ---------------------------------------------------- 9. Контрольная сумма
(cd "$WORK_DIR" && sha256sum "$OUTPUT_ISO" > "$OUTPUT_ISO.sha256")
log "Контрольная сумма:"
cat "$WORK_DIR/$OUTPUT_ISO.sha256"

ok "Сборка завершена: $WORK_DIR/$OUTPUT_ISO"
log "Размер и дальнейшая инструкция — в README.md (раздел «Создание загрузочного носителя»)."