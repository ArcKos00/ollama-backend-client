#!/usr/bin/env sh
#
# УНІВЕРСАЛЬНИЙ ЛАУНЧЕР.
# Визначає ОС і делегує роботу відповідному платформному скрипту:
#   • Linux / macOS / WSL        -> update-and-redeploy.sh   (через bash)
#   • Windows (Git Bash / MSYS / -> update-and-redeploy.ps1  (через powershell/pwsh)
#     Cygwin)
#
# Єдина команда на будь-якому хості змішаного парку клієнтів.
#
# Команди (однакові для всіх ОС):
#   ./update.sh                одноразова перевірка нових комітів + редеплой
#   ./update.sh install [N]    поставити на періодичний самозапуск кожні N хв (типово 5)
#   ./update.sh uninstall      прибрати періодичний самозапуск
#
# На «чистому» Windows без Git Bash запускай .ps1 напряму:
#   powershell -ExecutionPolicy Bypass -File .\update-and-redeploy.ps1 [-Install [-IntervalMinutes N]] [-Uninstall]
#
set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
SH="${DIR}/update-and-redeploy.sh"
PS="${DIR}/update-and-redeploy.ps1"

CMD="${1:-run}"
ARG="${2:-}"

find_pwsh() {
    for c in pwsh powershell pwsh.exe powershell.exe; do
        if command -v "$c" >/dev/null 2>&1; then
            echo "$c"
            return 0
        fi
    done
    return 1
}

run_linux() {
    [ -f "$SH" ] || { echo "ERROR: не знайдено ${SH}" >&2; exit 1; }
    case "$CMD" in
        run|"")    exec bash "$SH" ;;
        install)   if [ -n "$ARG" ]; then exec bash "$SH" install "$ARG"; else exec bash "$SH" install; fi ;;
        uninstall) exec bash "$SH" uninstall ;;
        -h|--help|help) exec bash "$SH" --help ;;
        *) echo "невідома команда: '$CMD' (run | install [N] | uninstall)" >&2; exit 2 ;;
    esac
}

run_windows() {
    [ -f "$PS" ] || { echo "ERROR: не знайдено ${PS}" >&2; exit 1; }
    PW="$(find_pwsh)" || { echo "ERROR: не знайдено powershell/pwsh у PATH." >&2; exit 1; }
    BASE="-NoProfile -ExecutionPolicy Bypass -File"
    case "$CMD" in
        run|"")    exec "$PW" $BASE "$PS" ;;
        install)   if [ -n "$ARG" ]; then exec "$PW" $BASE "$PS" -Install -IntervalMinutes "$ARG"; else exec "$PW" $BASE "$PS" -Install; fi ;;
        uninstall) exec "$PW" $BASE "$PS" -Uninstall ;;
        -h|--help|help) exec "$PW" $BASE "$PS" -? ;;
        *) echo "невідома команда: '$CMD' (run | install [N] | uninstall)" >&2; exit 2 ;;
    esac
}

case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW*|MSYS*|CYGWIN*) run_windows ;;   # Windows під bash-середовищем
    *)                    run_linux   ;;   # Linux / macOS / WSL
esac
