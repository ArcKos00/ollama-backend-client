#!/usr/bin/env bash
#
# СКРИПТ (Linux/macOS) — самооновлюваний клієнт OllamaProcessor.
#
# Перевіряє, чи зʼявився новий коміт в origin/<гілка> для ЦЬОГО ж репозиторію
# (того, з якого запущено скрипт). Якщо так — викачує його (git reset --hard)
# і перезбирає/перезапускає docker compose. Якщо ні — нічого не робить.
#
# Команди:
#   ./update-and-redeploy.sh                 одноразова перевірка + редеплой за потреби
#   ./update-and-redeploy.sh install [N]     прописати cron кожні N хв (1..59, типово 5)
#                                            + зробити первинну перевірку одразу
#   ./update-and-redeploy.sh uninstall       прибрати запис із cron
#
# Один файл = і робоча одиниця (її викликає cron), і встановлювач розкладу.
#
set -euo pipefail

# cron дає мінімальний PATH — доповнюємо типовими локаціями docker/git.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin:${PATH:-}"
# Під cron немає термінала: git має одразу падати, а не зависати в очікуванні логіна.
export GIT_TERMINAL_PROMPT=0

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

SELF="${REPO_DIR}/$(basename "${BASH_SOURCE[0]}")"
LOG_FILE="${REPO_DIR}/update-and-redeploy.log"
LOCK_FILE="${REPO_DIR}/.update-and-redeploy.lock"
MARKER="# ollama-processor auto-redeploy"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die() { log "ERROR: $*" >&2; exit 1; }

# docker compose v2 ("docker compose") або v1 ("docker-compose")
compose_cmd() {
    if docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
    else
        return 1
    fi
}

do_run() {
    # Захист від накладання запусків: перебілд може тривати довше за інтервал cron.
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$LOCK_FILE"
        if ! flock -n 9; then
            log "Інший запуск ще працює — пропускаю цю ітерацію."
            exit 0
        fi
    fi

    local DC
    DC="$(compose_cmd)" || die "не знайдено ані 'docker compose', ані 'docker-compose'."

    local BRANCH LOCAL REMOTE
    BRANCH="$(git rev-parse --abbrev-ref HEAD)"

    # Явно ловимо помилку fetch — під cron немає інтерактивного вводу креденшлів.
    git fetch origin "$BRANCH" \
        || die "git fetch не вдався. Перевір доступ до origin / креденшли (під cron немає інтерактивного вводу)."

    LOCAL="$(git rev-parse HEAD)"
    REMOTE="$(git rev-parse "origin/${BRANCH}")"

    if [ "$LOCAL" = "$REMOTE" ]; then
        log "Оновлень немає (гілка '${BRANCH}', HEAD=${LOCAL:0:7})."
        return 0
    fi

    log "Новий коміт у '${BRANCH}': ${LOCAL:0:7} -> ${REMOTE:0:7}. Оновлюю..."
    # Жорсткий reset: деплой = точний стан origin/<гілка> (локальні правки tracked-файлів зникнуть).
    git reset --hard "origin/${BRANCH}"

    log "Перезбірка та перезапуск docker compose..."
    # up --build перебудовує лише те, чий контекст змінився, і перестворює лише
    # контейнери зі зміненим образом/конфігом — ollama не чіпається дарма.
    $DC up -d --build --remove-orphans
    log "Готово. Розгорнуто ${REMOTE:0:7}."
}

do_install() {
    local n="${1:-${INTERVAL_MINUTES:-5}}"
    if ! [[ "$n" =~ ^[0-9]+$ ]] || [ "$n" -lt 1 ] || [ "$n" -gt 59 ]; then
        die "інтервал має бути числом 1..59 (задано: '${n}')."
    fi
    chmod +x "$SELF" 2>/dev/null || true

    local schedule="*/${n} * * * *"
    local line="${schedule} cd '${REPO_DIR}' && '${SELF}' >> '${LOG_FILE}' 2>&1 ${MARKER}"
    {
        crontab -l 2>/dev/null | grep -vF "$MARKER" || true
        echo "$line"
    } | crontab -

    log "Cron прописано: кожні ${n} хв (${schedule}). Лог: ${LOG_FILE}"
    log "Перевірити: crontab -l    |    Прибрати: '${SELF}' uninstall"
    log "УВАГА: служба cron має бути увімкнена (systemctl enable --now cron|crond)."
    log "Роблю первинну перевірку зараз..."
    do_run
}

do_uninstall() {
    { crontab -l 2>/dev/null | grep -vF "$MARKER" || true; } | crontab - 2>/dev/null || true
    log "Запис cron прибрано (marker: ${MARKER})."
}

usage() {
    cat <<EOF
Самооновлюваний клієнт OllamaProcessor (Linux/macOS).

  $(basename "$SELF")                 одноразова перевірка нових комітів + редеплой
  $(basename "$SELF") install [N]     прописати cron кожні N хв (1..59, типово 5) + первинний запуск
  $(basename "$SELF") uninstall       прибрати cron

Перший запуск стека (один раз, вручну):  docker compose up -d --build
EOF
}

case "${1:-run}" in
    run|"")               do_run ;;
    install|--install)    shift || true; do_install "${1:-}" ;;
    uninstall|--uninstall) do_uninstall ;;
    -h|--help|help)       usage ;;
    *)                    die "невідома команда: '$1' (дивись --help)." ;;
esac
