#!/usr/bin/env bash
#
# Стежить за поточним git-репозиторієм і при появі нового коміта
# у відстежуваній гілці:
#   1. викачує зміни (git fetch + hard reset до origin/<гілка>);
#   2. перезапускає docker compose з повним перебілдом (--no-cache).
#
# Використання:
#   ./update-and-redeploy.sh                 # цикл, інтервал 60с
#   POLL_INTERVAL=30 ./update-and-redeploy.sh   # свій інтервал (секунди)
#   INITIAL_DEPLOY=false ./update-and-redeploy.sh   # не деплоїти одразу на старті
#   ONCE=true ./update-and-redeploy.sh          # разова перевірка без циклу
#
set -euo pipefail

# --- Налаштування (можна перевизначити через змінні оточення) -------------
POLL_INTERVAL="${POLL_INTERVAL:-60}"      # інтервал перевірки, секунди
INITIAL_DEPLOY="${INITIAL_DEPLOY:-true}"  # зробити деплой одразу при старті
ONCE="${ONCE:-false}"                     # true = перевірити один раз і вийти

# Переходимо в директорію скрипта (== корінь репозиторію)
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Визначаємо команду docker compose (v2 "docker compose" чи v1) --------
if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    DC="docker-compose"
else
    echo "ERROR: не знайдено ані 'docker compose', ані 'docker-compose'." >&2
    exit 1
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

redeploy() {
    log "Повний перебілд і перезапуск docker compose..."
    $DC down --remove-orphans
    $DC build --no-cache
    $DC up -d --force-recreate
    log "Готово. Контейнери підняті."
}

update_repo() {
    log "Виявлено новий коміт — викачую зміни..."
    # Жорсткий reset гарантує, що деплой = точний стан origin/<гілка>
    git reset --hard "origin/${BRANCH}"
    log "Репозиторій оновлено до $(git rev-parse --short HEAD)."
}

check_once() {
    git fetch --quiet origin "$BRANCH"
    local local_rev remote_rev
    local_rev="$(git rev-parse HEAD)"
    remote_rev="$(git rev-parse "origin/${BRANCH}")"

    if [ "$local_rev" != "$remote_rev" ]; then
        update_repo
        redeploy
    else
        log "Оновлень немає (HEAD = ${local_rev:0:7})."
    fi
}

# --- Старт -----------------------------------------------------------------
log "Стеження за гілкою '${BRANCH}'. Docker: '${DC}'. Інтервал: ${POLL_INTERVAL}с."

if [ "$INITIAL_DEPLOY" = "true" ]; then
    log "Початковий деплой при старті..."
    redeploy
fi

if [ "$ONCE" = "true" ]; then
    check_once
    exit 0
fi

# Основний цикл
while true; do
    check_once || log "УВАГА: ітерація завершилась з помилкою, продовжую."
    sleep "$POLL_INTERVAL"
done
