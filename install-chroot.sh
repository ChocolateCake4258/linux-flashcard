#!/bin/bash
# install-chroot.sh — установка ПО внутрь chroot распакованной Kubuntu.
# Запускается ТОЛЬКО внутри chroot через build.sh. Не запускать на хосте!
set -euo pipefail

log() {
    echo "========================================="
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
    echo "========================================="
}

log "Начало установки внутри chroot"

# Предварительные ответы debconf (не дают интерактива в wireshark)
echo "wireshark-common wireshark-common/install-setuid boolean true"        | debconf-set-selections
echo "wireshark-common wireshark-common/install-setuid debconf:boolean true" | debconf-set-selections 2>/dev/null || true
echo "libssl1.1 libssl1.1/restart-services string" | debconf-set-selections 2>/dev/null || true

export DEBIAN_FRONTEND=noninteractive

log "Обновление индекса пакетов"
apt update

log "Установка вспомогательных утилит"
apt install -y --no-install-recommends \
    wget \
    curl \
    ca-certificates \
    apt-transport-https \
    software-properties-common \
    gnupg \
    gpg \
    lsb-release

# ----------------------------------------------------------------------------
# 1. Пакеты из официального репозитория (см. packages.list)
if [ -f /packages.list ]; then
    PACKAGES=$(grep -v '^\s*#' /packages.list | tr '\n' ' ')
    if [ -n "$PACKAGES" ]; then
        log "Установка официальных пакетов: $PACKAGES"
        apt install -y --no-install-recommends $PACKAGES
    else
        log "packages.list пуст или не содержит пакетов"
    fi
else
    log "Предупреждение: /packages.list не найден"
fi

# ----------------------------------------------------------------------------
# 2. Сторонние репозитории (Microsoft: .NET + VS Code)
log "Добавление репозитория Microsoft для .NET и VS Code"
wget -q https://packages.microsoft.com/keys/microsoft.asc -O /tmp/microsoft.asc
gpg --dearmor < /tmp/microsoft.asc > /etc/apt/trusted.gpg.d/microsoft.gpg
rm -f /tmp/microsoft.asc
UBUNTU_CODENAME=$(lsb_release -cs)
VERSION_ID=$(lsb_release -rs)
# Microsoft репозитории собираются для LTS; для 24.04 это 'noble'
if [ "$UBUNTU_CODENAME" = "noble" ]; then
    echo "deb [arch=amd64] https://packages.microsoft.com/ubuntu/${VERSION_ID}/stable/vscode $UBUNTU_CODENAME main" > /etc/apt/sources.list.d/vscode.list
    echo "deb [arch=amd64] https://packages.microsoft.com/ubuntu/${VERSION_ID}/prod $UBUNTU_CODENAME main" > /etc/apt/sources.list.d/microsoft-prod.list
else
    # fallback: пакетный репозиторий для иных серий — по-прежнему подписан mscript key
    echo "deb [arch=amd64] https://packages.microsoft.com/repos/vscode stable main" > /etc/apt/sources.list.d/vscode.list
    echo "deb [arch=amd64] https://packages.microsoft.com/repos/microsoft-ubuntu-$(lsb_release -cs)-prod stable main" > /etc/apt/sources.list.d/microsoft-prod.list
fi

apt update
log "Установка .NET SDK 8"
apt install -y dotnet-sdk-8.0

log "Установка Visual Studio Code"
apt install -y code

# VS Code в chroot не может использовать sandbox (no setuid) — запускаем с --no-sandbox
cat > /usr/local/bin/code << 'EOF'
#!/bin/bash
exec /usr/bin/code --no-sandbox --user-data-dir="$HOME/.vscode" "$@"
EOF
chmod +x /usr/local/bin/code
# alias на случай shell-сессии
grep -q '^alias code=' /etc/bash.bashrc || echo 'alias code="code --no-sandbox"' >> /etc/bash.bashrc

# ----------------------------------------------------------------------------
# 3. Rust через пакетный менеджер (не скачиваем 1+ ГБ rustup toolcahain в chroot)
# Полный toolchain из репозитория Ubuntu достаточен для учебных задач.
if command -v apt-cache >/dev/null && apt-cache policy rustc 2>/dev/null | grep -q 'Candidate:'; then
    log "Rust toolchain (rustc + cargo) уже установлен через packages.list"
else
    log "Установка rustc и cargo"
    apt install -y rustc cargo
fi

# ----------------------------------------------------------------------------
# 4. Глобальные npm-пакеты (TypeScript)
log "Установка глобального TypeScript"
if command -v npm >/dev/null; then
    npm install -g typescript || log "ВНИМАНИЕ: не удалось поставить typescript глобально"
else
    log "npm недоступен — пропускаю TypeScript"
fi

# ----------------------------------------------------------------------------
log "Очистка кэша apt"
apt clean
rm -rf /var/lib/apt/lists/*

log "Установка завершена успешно"