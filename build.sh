#!/bin/bash
set -e  # прерывать при ошибке

# Загружаем конфигурацию
source "$(dirname "$0")/config.sh"

# Проверка, что скрипт запущен не от root (но будет использовать sudo)
if [ "$EUID" -eq 0 ]; then 
    echo "Пожалуйста, не запускайте этот скрипт от root. Он будет использовать sudo где необходимо."
    exit 1
fi

# Функция для печати с временем
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log "Начало сборки кастомного ISO Kubuntu"

# Проверка наличия необходимых утилит
for cmd in sudo wget xorriso mksquashfs rsync mount umount; do
    if ! command -v $cmd &> /dev/null; then
        echo "Ошибка: не найдена команда $cmd. Установите необходимые пакеты."
        exit 1
    fi
done

# Создание рабочих папок
log "Создание рабочих директорий в $WORK_DIR"
mkdir -p "$ISO_MOUNT_DIR" "$EXTRACT_DIR" "$NEW_ISO_DIR"

# Скачивание оригинального ISO (если его нет)
if [ ! -f "$ORIG_ISO" ]; then
    log "Скачивание оригинального ISO с $ISO_URL"
    wget -O "$ORIG_ISO" "$ISO_URL"
else
    log "Оригинальный ISO уже существует: $ORIG_ISO"
fi

# Распаковка ISO и squashfs
log "Монтирование ISO и распаковка содержимого"
sudo mount -o loop "$ORIG_ISO" "$ISO_MOUNT_DIR"
sudo rsync --exclude=/casper/filesystem.squashfs -a "$ISO_MOUNT_DIR/" "$EXTRACT_DIR/"
sudo unsquashfs -d "$CUSTOM_ROOT" "$ISO_MOUNT_DIR/casper/filesystem.squashfs"
sudo umount "$ISO_MOUNT_DIR"

# Подготовка chroot
log "Подготовка chroot окружения"
sudo mount --bind /proc "$CUSTOM_ROOT/proc"
sudo mount --bind /dev "$CUSTOM_ROOT/dev"
sudo mount --bind /sys "$CUSTOM_ROOT/sys"
sudo cp /etc/resolv.conf "$CUSTOM_ROOT/etc/"

# Копирование файлов внутрь chroot
log "Копирование packages.list и install-chroot.sh в chroot"
sudo cp "$(dirname "$0")/packages.list" "$CUSTOM_ROOT/"
sudo cp "$(dirname "$0")/install-chroot.sh" "$CUSTOM_ROOT/"
sudo chmod +x "$CUSTOM_ROOT/install-chroot.sh"

# Запуск chroot
log "Запуск install-chroot.sh внутри chroot (это займёт много времени)"
sudo chroot "$CUSTOM_ROOT" /bin/bash -c "/install-chroot.sh"

# Очистка chroot
log "Очистка chroot"
sudo rm -f "$CUSTOM_ROOT/install-chroot.sh" "$CUSTOM_ROOT/packages.list"
sudo rm -f "$CUSTOM_ROOT/etc/resolv.conf"
sudo umount "$CUSTOM_ROOT/proc"
sudo umount "$CUSTOM_ROOT/dev"
sudo umount "$CUSTOM_ROOT/sys"

# Обновление манифеста и пересборка squashfs
log "Обновление манифеста и создание нового squashfs"
sudo chroot "$CUSTOM_ROOT" dpkg-query -W --showformat='${Package} ${Version}\n' | sudo tee "$EXTRACT_DIR/casper/filesystem.manifest" > /dev/null
sudo cp "$EXTRACT_DIR/casper/filesystem.manifest" "$EXTRACT_DIR/casper/filesystem.manifest-desktop"
sudo du -sx --block-size=1 "$CUSTOM_ROOT" | cut -f1 | sudo tee "$EXTRACT_DIR/casper/filesystem.size" > /dev/null
sudo rm -f "$EXTRACT_DIR/casper/filesystem.squashfs"
sudo mksquashfs "$CUSTOM_ROOT" "$EXTRACT_DIR/casper/filesystem.squashfs" $SQUASHFS_COMP
sudo rm -rf "$CUSTOM_ROOT"

# Сборка нового ISO
log "Сборка нового ISO"
sudo cp -r "$EXTRACT_DIR"/* "$NEW_ISO_DIR/"
# Определяем путь к isohdpfx.bin
ISOHDPFX="/usr/lib/ISOLINUX/isohdpfx.bin"
if [ ! -f "$ISOHDPFX" ]; then
    ISOHDPFX="/usr/lib/syslinux/isohdpfx.bin"
fi
if [ ! -f "$ISOHDPFX" ]; then
    echo "Предупреждение: isohdpfx.bin не найден."
    ISOHDPFX_OPT=""
else
    ISOHDPFX_OPT="-isohybrid-mbr $ISOHDPFX"
fi

sudo xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid "Custom Kubuntu" \
    -output "$WORK_DIR/$OUTPUT_ISO" \
    $ISOHDPFX_OPT \
    -b isolinux/isolinux.bin \
    -c isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -eltorito-alt-boot \
    -e boot/grub/efi.img \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    "$NEW_ISO_DIR/"

log "Сборка завершена! Итоговый ISO: $WORK_DIR/$OUTPUT_ISO"