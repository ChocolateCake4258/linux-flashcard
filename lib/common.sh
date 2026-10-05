#!/bin/bash
# Общие функции для скриптов сборки. Подключается через: source lib/common.sh

# Цвета для логов (отключаются при не-интерактивном запуске)
if [ -t 1 ] && [ "$TERM" != "dumb" ]; then
    C_RESET=$'\033[0m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_CYAN=$'\033[36m'
else
    C_RESET=""
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_CYAN=""
fi

log() {
    echo "${C_CYAN}[$(date '+%Y-%m-%d %H:%M:%S')]${C_RESET} $1"
}

warn() {
    echo "${C_YELLOW}[ВНИМАНИЕ]${C_RESET} $1" >&2
}

die() {
    echo "${C_RED}[ОШИБКА]${C_RESET} $1" >&2
    exit 1
}

ok() {
    echo "${C_GREEN}[ГОТОВО]${C_RESET} $1"
}

# Проверка, что скрипт запущен не от root напрямую (sudo используется точечно).
# Внутри контейнера/CI root разрешён через переменную ALLOW_ROOT=1.
require_not_root() {
    if [ "$EUID" -eq 0 ] && [ "$ALLOW_ROOT" != "1" ]; then
        die "Не запускайте этот скрипт от root напрямую — он вызовет sudo сам. Для CI: ALLOW_ROOT=1."
    fi
}

# Проверка наличия всех нужных утилит.
require_cmds() {
    local missing=0 cmd
    for cmd in "$@"; do
        if ! command -v "$cmd" &>/dev/null; then
            warn "не найдена команда: $cmd (установите: make prepare)"
            missing=1
        fi
    done
    [ "$missing" -eq 0 ]
}

# Проверка свободного места. Печатает размер требуемой директории.
check_space() {
    local dir="$1" needed_mb="$2" avail_mb
    [ -d "$dir" ] || mkdir -p "$dir"
    avail_mb=$(df -PBM "$dir" | awk 'NR==2 {gsub("M","",$4); print $4}')
    log "Свободно в $dir: ${avail_mb} МБ (требуется ~${needed_mb} МБ)"
    if [ "${avail_mb:-0}" -lt "$needed_mb" ]; then
        die "Недостаточно места на диске: ${avail_mb} МБ < ${needed_mb} МБ"
    fi
}

# Размонтирование всех точек внутри указанной директории (могут быть nested).
umount_all_under() {
    local root="$1" mp
    [ -d "$root" ] || return 0
    # Сначала самые вложенные
    while read -r mp; do
        [ -n "$mp" ] && sudo umount "$mp" 2>/dev/null && log "размонтировано: $mp"
    done < <(mount | awk -v r="$root" '$3 ~ "^"r {print $3}' | sort -r)
}

# Проверка/сохранение контрольной суммы скачанного ISO.
# На вход: путь к файлу и официальный SHA256SUMS (скачивается автоматически).
# usage: verify_iso_from_url <file> <sums_url>  -- вернёт 0 если совпало
verify_iso() {
    local file="$1" sums_url="$2" expected=""
    [ -f "$file" ] || return 1
    expected=$(curl -fsSL --max-time 30 "$sums_url" 2>/dev/null | grep -F "$(basename "$file")" | awk '{print $1}')
    if [ -z "$expected" ]; then
        warn "не удалось получить ожидаемую контрольную сумму для $(basename "$file")"
        return 1
    fi
    log "Проверка SHA256 $(basename "$file")..."
    echo "$expected  $file" | sha256sum -c - --status 2>/dev/null
}

# Шаблон для trap: размонтировать всё и удалить рабочие папки по сигналу.
trap_cleanup() {
    local root="${CUSTOM_ROOT:-}"
    [ -n "$root" ] && umount_all_under "$root"
    warn "прервано по сигналу"
}