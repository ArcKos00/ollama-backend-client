#!/usr/bin/env bash
#
# СКРИПТ 1 — інсталятор.
# Прописує в crontab поточного користувача періодичний запуск
# update-and-redeploy.sh (СКРИПТ 2). Той щоразу перевіряє оновлення і за
# потреби робить редеплой.
#
# Використання (без sudo, від свого користувача):
#   bash install-cron.sh                       # кожні 5 хв
#   INTERVAL_MINUTES=10 bash install-cron.sh   # свій інтервал (1..59 хв)
#   bash install-cron.sh --uninstall           # прибрати
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER="${REPO_DIR}/update-and-redeploy.sh"
LOG_FILE="${REPO_DIR}/update-and-redeploy.log"
INTERVAL_MINUTES="${INTERVAL_MINUTES:-5}"

# Унікальний маркер, щоб знаходити/видаляти саме наш рядок у crontab
MARKER="# ollama-processor auto-redeploy"

current_crontab() {
    crontab -l 2>/dev/null | grep -vF "$MARKER" || true
}

# --- Видалення -------------------------------------------------------------
if [ "${1:-}" = "--uninstall" ]; then
    echo "Прибираю запис із crontab..."
    current_crontab | crontab -
    echo "Готово."
    exit 0
fi

# --- Встановлення ----------------------------------------------------------
if [ ! -f "$WORKER" ]; then
    echo "ERROR: не знайдено ${WORKER}" >&2
    exit 1
fi
if ! [[ "$INTERVAL_MINUTES" =~ ^[0-9]+$ ]] || [ "$INTERVAL_MINUTES" -lt 1 ] || [ "$INTERVAL_MINUTES" -gt 59 ]; then
    echo "ERROR: INTERVAL_MINUTES має бути числом 1..59 (задано: '${INTERVAL_MINUTES}')." >&2
    exit 1
fi
chmod +x "$WORKER"

# Розклад cron: кожні N хвилин запускаємо Скрипт 2 з логуванням у файл
SCHEDULE="*/${INTERVAL_MINUTES} * * * *"
CRON_LINE="${SCHEDULE} cd '${REPO_DIR}' && '${WORKER}' >> '${LOG_FILE}' 2>&1 ${MARKER}"

{
    current_crontab
    echo "$CRON_LINE"
} | crontab -

echo "Готово. Cron прописано."
echo "  Скрипт 2 : ${WORKER}"
echo "  Розклад  : кожні ${INTERVAL_MINUTES} хв (${SCHEDULE})"
echo "  Лог      : ${LOG_FILE}"
echo
echo "Перевірити:   crontab -l"
echo "Прибрати:     bash install-cron.sh --uninstall"
echo
echo "УВАГА: служба cron має бути увімкнена (systemctl enable --now cron|crond)."
echo "Перший запуск стека зробіть вручну:  ${DC:-docker compose} up -d --build"
