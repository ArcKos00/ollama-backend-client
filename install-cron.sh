#!/usr/bin/env bash
#
# Реєструє update-and-redeploy.sh на автозапуск після перезавантаження
# системи через cron (@reboot). Watcher працює в циклі й сам стежить за
# оновленнями репозиторію.
#
# Використання:
#   ./install-cron.sh              # встановити автозапуск
#   ./install-cron.sh --uninstall  # прибрати автозапуск
#
# Інтервал перевірки можна задати змінною POLL_INTERVAL при встановленні:
#   POLL_INTERVAL=30 ./install-cron.sh
#
set -euo pipefail

# Абсолютні шляхи (== корінь репозиторію)
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER="${REPO_DIR}/update-and-redeploy.sh"
LOG_FILE="${REPO_DIR}/update-and-redeploy.log"
POLL_INTERVAL="${POLL_INTERVAL:-60}"

# Унікальний маркер, щоб знаходити/видаляти саме наш рядок у crontab
MARKER="# ollama-processor auto-redeploy watcher"

# Рядок cron: після ребуту заходимо в репо і запускаємо watcher з логуванням
CRON_LINE="@reboot cd '${REPO_DIR}' && POLL_INTERVAL=${POLL_INTERVAL} '${WATCHER}' >> '${LOG_FILE}' 2>&1 ${MARKER}"

# Поточний crontab без наших рядків (якщо crontab порожній — не падаємо)
current_crontab() {
    crontab -l 2>/dev/null | grep -vF "$MARKER" || true
}

if [ "${1:-}" = "--uninstall" ]; then
    echo "Видаляю автозапуск з crontab..."
    current_crontab | crontab -
    echo "Готово. Записи watcher-а прибрані."
    exit 0
fi

# --- Встановлення ----------------------------------------------------------
if [ ! -f "$WATCHER" ]; then
    echo "ERROR: не знайдено ${WATCHER}" >&2
    exit 1
fi
chmod +x "$WATCHER"

echo "Реєструю автозапуск через cron (@reboot)..."
{
    current_crontab
    echo "$CRON_LINE"
} | crontab -

echo "Готово."
echo "  Скрипт : ${WATCHER}"
echo "  Лог    : ${LOG_FILE}"
echo "  Інтервал: ${POLL_INTERVAL}с"
echo
echo "Перевірити crontab:   crontab -l"
echo "Прибрати автозапуск:  ${BASH_SOURCE[0]} --uninstall"
echo
echo "УВАГА: @reboot спрацьовує при завантаженні системи. Переконайтесь, що"
echo "служба cron увімкнена (наприклад: systemctl enable --now cron|crond)."
