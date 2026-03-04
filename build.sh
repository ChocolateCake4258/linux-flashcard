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

# Шаг 8: Сборка нового ISO
log "Подготовка к сборке нового ISO"

# Копируем всё содержимое extract в newiso (включая скрытые файлы!)
sudo rsync -a "$EXTRACT_DIR/" "$NEW_ISO_DIR/"

# Проверяем наличие isolinux.bin и, при необходимости, копируем из системы
if [ ! -f "$NEW_ISO_DIR/isolinux/isolinux.bin" ]; then
    log "ВНИМАНИЕ: isolinux.bin не найден в newiso/isolinux. Пытаемся восстановить."

    # Проверяем, есть ли isolinux в оригинальном extract
    if [ -f "$EXTRACT_DIR/isolinux/isolinux.bin" ]; then
        log "Копируем isolinux из extract в newiso"
        sudo cp -r "$EXTRACT_DIR/isolinux" "$NEW_ISO_DIR/"
    else
        log "isolinux отсутствует в оригинальном ISO. Устанавливаем isolinux из репозитория."
        sudo apt update
        sudo apt install -y isolinux syslinux-common

        # Создаём каталог и копируем необходимые файлы
        sudo mkdir -p "$NEW_ISO_DIR/isolinux"
        sudo rsync -a /usr/lib/ISOLINUX/ "$NEW_ISO_DIR/isolinux/"
        # Копируем модули syslinux (для корректной работы)
        if [ -d /usr/lib/syslinux/modules/bios ]; then
            sudo cp /usr/lib/syslinux/modules/bios/*.c32 "$NEW_ISO_DIR/isolinux/" 2>/dev/null || true
        fi

        # Копируем конфигурационные файлы из оригинального ISO, если они существуют
        if [ -f "$EXTRACT_DIR/isolinux/isolinux.cfg" ]; then
            sudo cp "$EXTRACT_DIR/isolinux/isolinux.cfg" "$NEW_ISO_DIR/isolinux/"
        elif [ -f "$EXTRACT_DIR/isolinux/txt.cfg" ]; then
            sudo cp "$EXTRACT_DIR/isolinux/txt.cfg" "$NEW_ISO_DIR/isolinux/"
        else
            log "Предупреждение: не найдена конфигурация isolinux. Загрузка может не работать."
            # Создаём минимальную конфигурацию
            echo "DEFAULT linux" | sudo tee "$NEW_ISO_DIR/isolinux/isolinux.cfg"
            echo "LABEL linux" | sudo tee -a "$NEW_ISO_DIR/isolinux/isolinux.cfg"
            echo "  KERNEL /casper/vmlinuz" | sudo tee -a "$NEW_ISO_DIR/isolinux/isolinux.cfg"
            echo "  INITRD /casper/initrd" | sudo tee -a "$NEW_ISO_DIR/isolinux/isolinux.cfg"
            echo "  APPEND root=/dev/ram0 ramdisk_size=1500000 ip=frommedia" | sudo tee -a "$NEW_ISO_DIR/isolinux/isolinux.cfg"
        fi
    fi
fi

# Определяем путь к isohdpfx.bin (для гибридного режима)
ISOHDPFX="/usr/lib/ISOLINUX/isohdpfx.bin"
if [ ! -f "$ISOHDPFX" ]; then
    ISOHDPFX="/usr/lib/syslinux/isohdpfx.bin"
fi
if [ ! -f "$ISOHDPFX" ]; then
    log "Предупреждение: isohdpfx.bin не найден. ISO может не быть гибридным."
    ISOHDPFX_OPT=""
else
    ISOHDPFX_OPT="-isohybrid-mbr $ISOHDPFX"
fi

log "Запуск xorriso для создания ISO"
sudo xorriso -as mkisofs \
    -volid "Custom Kubuntu" \
    -output "$WORK_DIR/$OUTPUT_ISO" \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
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

# Проверка созданного ISO
log "Проверка содержимого созданного ISO"
mkdir -p test_mount
if sudo mount -o loop "$WORK_DIR/$OUTPUT_ISO" test_mount; then
    echo "Содержимое корня ISO:"
    ls -la test_mount/
    if [ -d test_mount/.disk ]; then
        log ".disk присутствует"
    else
        log "ОШИБКА: .disk отсутствует!"
    fi
    if [ -f test_mount/casper/filesystem.squashfs ]; then
        log "filesystem.squashfs присутствует"
    else
        log "ОШИБКА: filesystem.squashfs отсутствует!"
    fi
    sudo umount test_mount
else
    log "Не удалось смонтировать созданный ISO"
fi
rmdir test_mount

log "Сборка завершена! Итоговый ISO: $WORK_DIR/$OUTPUT_ISO"