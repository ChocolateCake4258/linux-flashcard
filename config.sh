#!/bin/bash
# Конфигурация сборки

# URL оригинального ISO (можно изменить на другую версию)
ISO_URL="https://cdimage.ubuntu.com/kubuntu/releases/24.04.3/release/kubuntu-24.04.4-desktop-amd64.iso"

# Имя скачиваемого ISO (не менять, используется в скриптах)
ORIG_ISO="kubuntu.iso"

# Имя измененного ISO
OUTPUT_ISO="custom-kubuntu.iso"

# Папка где происходит сборка
WORK_DIR="$(pwd)"   # по умолчанию текущая папка

# Каталоги внутри WORK_DIR
ISO_MOUNT_DIR="${WORK_DIR}/iso"          # точка монтирования оригинального ISO
EXTRACT_DIR="${WORK_DIR}/extract"        # распакованное содержимое ISO (без squashfs)
CUSTOM_ROOT="${EXTRACT_DIR}/custom"      # корень распакованной системы
NEW_ISO_DIR="${WORK_DIR}/newiso"         # папка для сборки нового ISO

# Сжатие squashfs (параметры)
SQUASHFS_COMP="-comp xz -b 1M"