#!/usr/bin/env bash
#
# Реєструє update-and-redeploy.sh як службу systemd, що стартує після
# перезавантаження системи (і після docker.service). Надійніший за cron:
# авто-рестарт при падінні, статуси й логи через journalctl.
#
# Запускати з sudo:
#   sudo ./install-systemd.sh                 # встановити (інтервал 60с)
#   sudo POLL_INTERVAL=300 ./install-systemd.sh   # свій інтервал
#   sudo ./install-systemd.sh --uninstall     # прибрати службу
#
# Після встановлення:
#   systemctl status  ollama-auto-redeploy
#   journalctl -u ollama-auto-redeploy -f
#
set -euo pipefail

SERVICE_NAME="ollama-auto-redeploy"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"

# Абсолютні шляхи (== корінь репозиторію)
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER="${REPO_DIR}/update-and-redeploy.sh"
POLL_INTERVAL="${POLL_INTERVAL:-60}"

# Служба має ставитись з-під root, але бігти від імені звичайного користувача
# (він має бути в групі docker, щоб керувати контейнерами без sudo).
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: запускайте через sudo (потрібні права на /etc/systemd/system)." >&2
    exit 1
fi
RUN_USER="${SUDO_USER:-root}"

# --- Видалення -------------------------------------------------------------
if [ "${1:-}" = "--uninstall" ]; then
    echo "Зупиняю й видаляю службу ${SERVICE_NAME}..."
    systemctl disable --now "${SERVICE_NAME}.service" 2>/dev/null || true
    rm -f "$UNIT_PATH"
    systemctl daemon-reload
    echo "Готово. Служба прибрана."
    exit 0
fi

# --- Встановлення ----------------------------------------------------------
if [ ! -f "$WATCHER" ]; then
    echo "ERROR: не знайдено ${WATCHER}" >&2
    exit 1
fi
chmod +x "$WATCHER"

echo "Створюю ${UNIT_PATH} (User=${RUN_USER}, POLL_INTERVAL=${POLL_INTERVAL})..."
cat > "$UNIT_PATH" <<EOF
[Unit]
Description=OllamaProcessor auto-redeploy watcher
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
User=${RUN_USER}
WorkingDirectory=${REPO_DIR}
Environment=POLL_INTERVAL=${POLL_INTERVAL}
ExecStart=/usr/bin/env bash ${WATCHER}
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}.service"

echo "Готово. Служба ${SERVICE_NAME} увімкнена й запущена."
echo
echo "Статус : systemctl status ${SERVICE_NAME}"
echo "Логи   : journalctl -u ${SERVICE_NAME} -f"
echo "Прибрати: sudo ${BASH_SOURCE[0]} --uninstall"
echo
echo "УВАГА: користувач '${RUN_USER}' має бути в групі docker, щоб керувати"
echo "контейнерами без sudo:  sudo usermod -aG docker ${RUN_USER}"
