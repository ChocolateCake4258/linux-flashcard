#!/bin/bash
set -e  # остановить при любой ошибке

# Функция для печати разделителей
log() {
    echo "========================================="
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
    echo "========================================="
}

log "Начало установки внутри chroot"

# Предварительная настройка debconf для wireshark
echo "wireshark-common wireshark-common/install-setuid boolean true" | debconf-set-selections

apt update

log "Установка вспомогательных утилит"
apt install -y --no-install-recommends \
    wget \
    curl \
    ca-certificates \
    apt-transport-https \
    software-properties-common \
    gnupg \
    isolinux

# Установка пакетов из официального репозитория (через apt)
if [ -f /packages.list ]; then
    PACKAGES=$(grep -v '^\s*#' /packages.list | tr '\n' ' ')
    if [ -n "$PACKAGES" ]; then
        log "Установка официальных пакетов: $PACKAGES"
        apt install -y --no-install-recommends $PACKAGES
    else
        log "Файл packages.list пуст или не содержит пакетов"
    fi
else
    log "Предупреждение: /packages.list не найден"
fi

# Внешние репозитории

log "Добавление репозитория Node.js 20.x"
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs

log "Установка .NET SDK 8.0"
wget https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb -O packages-microsoft-prod.deb
dpkg -i packages-microsoft-prod.deb
rm packages-microsoft-prod.deb
apt update
apt install -y dotnet-sdk-8.0

log "Установка Visual Studio Code"
wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > packages.microsoft.gpg
install -D -o root -g root -m 644 packages.microsoft.gpg /etc/apt/keyrings/packages.microsoft.gpg
rm packages.microsoft.gpg
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" > /etc/apt/sources.list.d/vscode.list
apt update
apt install -y code


# log "Установка PyCharm Community Edition"
# wget -O /tmp/pycharm.tar.gz "https://download.jetbrains.com/python/pycharm-community-latest.tar.gz"
# tar -xzf /tmp/pycharm.tar.gz -C /opt/
# # Переименовываем (обычно pycharm-community-*)
# mv /opt/pycharm-community-* /opt/pycharm-community
# ln -s /opt/pycharm-community/bin/pycharm.sh /usr/local/bin/pycharm
# rm /tmp/pycharm.tar.gz

log "Установка Rust"
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
# Добавляем путь в /etc/profile.d
echo 'export PATH=/root/.cargo/bin:$PATH' > /etc/profile.d/rust.sh
chmod +x /etc/profile.d/rust.sh
# Создаём ссылки для немедленного использования
ln -s /root/.cargo/bin/rustc /usr/local/bin/rustc
ln -s /root/.cargo/bin/cargo /usr/local/bin/cargo

log "Очистка кэша apt"
apt clean
rm -rf /var/lib/apt/lists/*

log "Установка завершена успешно"