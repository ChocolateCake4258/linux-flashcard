#!/bin/bash
# Установка необходимых утилит
sudo apt update
sudo apt install -y --no-install-recommends \
    sudo \
    wget \
    xorriso \
    isolinux \
    rsync \
    mount \
    squashfs-tools \
    syslinux-common