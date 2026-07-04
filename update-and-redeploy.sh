#!/usr/bin/env bash
#
# СКРИПТ 2 — робоча одиниця.
# Одноразова перевірка оновлень поточного git-репозиторію:
#   якщо в origin/<гілка> зʼявився новий коміт — викачує його
#   (git reset --hard) і робить повний перебілд docker compose (--no-cache).
# Якщо оновлень немає — нічого не робить і виходить.
#
# Призначений для періодичного запуску з cron (див. install-cron.sh),
# але його можна запускати й вручну:
#   ./update-and-redeploy.sh
#
set -euo pipefail

# cron дає мінімальний PATH (зазвичай лише /usr/bin:/bin), через що docker чи
# git можуть «не знайтись». Додаємо типові локації, щоб працювало і з cron.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin:${PATH:-}"

# Під cron немає термінала: git не має зависати в очікуванні логіна/пароля,
# а одразу падати з помилкою (її зловимо нижче на git fetch).
export GIT_TERMINAL_PROMPT=0

# Корінь репозиторію (== директорія скрипта)
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# --- Захист від паралельних запусків --------------------------------------
# Перебілд може тривати довше за інтервал cron — не даємо двом запускам
# накластись один на одного.
LOCK_FILE="${REPO_DIR}/.update-and-redeploy.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log "Інший запуск ще працює — пропускаю цю ітерацію."
    exit 0
fi

# --- Команда docker compose (v2 "docker compose" чи v1) -------------------
if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    DC="docker-compose"
else
    log "ERROR: не знайдено ані 'docker compose', ані 'docker-compose'."
    exit 1
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"

# --- Перевірка оновлень ----------------------------------------------------
# Явно ловимо помилку fetch — під cron немає термінала для введення
# креденшлів, тож проблема з доступом до origin має бути видима в логу.
if ! git fetch origin "$BRANCH"; then
    log "ERROR: git fetch не вдався. Перевір доступ до origin / креденшли (під cron немає інтерактивного вводу)."
    exit 1
fi
LOCAL="$(git rev-parse HEAD)"
REMOTE="$(git rev-parse "origin/${BRANCH}")"

if [ "$LOCAL" = "$REMOTE" ]; then
    log "Оновлень немає (гілка '${BRANCH}', HEAD=${LOCAL:0:7})."
    exit 0
fi

# --- Оновлення + редеплой --------------------------------------------------
log "Новий коміт у '${BRANCH}': ${LOCAL:0:7} -> ${REMOTE:0:7}. Оновлюю..."
# Жорсткий reset гарантує, що деплой = точний стан origin/<гілка>
git reset --hard "origin/${BRANCH}"

log "Повний перебілд і перезапуск docker compose..."
$DC down --remove-orphans
$DC build --no-cache
$DC up -d --force-recreate
log "Готово. Розгорнуто ${REMOTE:0:7}."
