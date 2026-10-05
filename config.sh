#!/bin/bash
# Конфигурация сборки кастомного ISO Kubuntu

# --- Параметры базового дистрибутива ---
# Серия и точечная версия Kubuntu LTS (не менять URL вручную — он собирается ниже)
KUBUNTU_SERIES="24.04"
KUBUNTU_VERSION="24.04.4"

# URL оригинального ISO (канонический путь cdimage.ubuntu.com)
ISO_URL="https://cdimage.ubuntu.com/kubuntu/releases/${KUBUNTU_SERIES}/release/kubuntu-${KUBUNTU_VERSION}-desktop-amd64.iso"
# Файл с официальными контрольными суммами того же каталога
SHA256SUMS_URL="https://cdimage.ubuntu.com/kubuntu/releases/${KUBUNTU_SERIES}/release/SHA256SUMS"

# --- Имена файлов ---
# Имя скачиваемого ISO (не менять без необходимости)
ORIG_ISO="kubuntu.iso"
# Имя изменённого ISO (результат сборки)
OUTPUT_ISO="custom-kubuntu.iso"

# --- Рабочие директории ---
# Папка, где происходит сборка (по умолчанию — корень репозитория)
WORK_DIR="$(cd "$(dirname "$0")" && pwd)"
ISO_MOUNT_DIR="${WORK_DIR}/iso"          # точка монтирования оригинального ISO
EXTRACT_DIR="${WORK_DIR}/extract"        # распакованное содержимое ISO (без squashfs)
CUSTOM_ROOT="${EXTRACT_DIR}/custom"      # корень распакованной системы (chroot)
NEW_ISO_DIR="${WORK_DIR}/newiso"         # папка для сборки нового ISO
TEST_MOUNT_DIR="${WORK_DIR}/test_mount"  # точка монтирования готового ISO (проверка)

# --- Сжатие squashfs ---
SQUASHFS_COMP="-comp xz -b 1M"

# --- Архитектура ---
ARCH="amd64"

# --- Порог свободного места (МБ); ранний отказ до скачивания 5 ГБ ISO ---
# Ориентировочная потребность: ISO 5.5 ГБ + распакованная ФС ~11 ГБ + новый squashfs ~5.5 ГБ
MIN_FREE_MB_HOST=20000       # хост до распаковки
MIN_FREE_MB_BUILD=26000      # хост с учётом распакованной ФС