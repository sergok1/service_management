#!/bin/bash
# Устанавливает watchdog: копирует файлы и активирует systemd timer.
# Запускать с sudo.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "❌ Запустите с sudo." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/services_management"
SYSTEMD_DIR="/etc/systemd/system"

echo "=== Установка watchdog ==="

mkdir -p "$INSTALL_DIR"

for f in watchdog.sh watchdog.conf services.conf; do
  cp "$SCRIPT_DIR/$f" "$INSTALL_DIR/$f"
  echo "  ✓ $f → $INSTALL_DIR/$f"
done
chmod +x "$INSTALL_DIR/watchdog.sh"

for f in services-watchdog.service services-watchdog.timer; do
  cp "$SCRIPT_DIR/systemd/$f" "$SYSTEMD_DIR/$f"
  echo "  ✓ $f → $SYSTEMD_DIR/$f"
done

systemctl daemon-reload
systemctl enable --now services-watchdog.timer
echo ""
echo "✅ Watchdog установлен и запущен."
echo "   Таймер: каждые 60 минут + через 2 мин после загрузки"
echo "   Лог:    /var/log/services_management_watchdog.log"
echo "   Статус: systemctl status services-watchdog.timer"
echo ""

echo "--- Тестовый запуск ---"
"$INSTALL_DIR/watchdog.sh" && echo "✅ Тест пройден" || echo "⚠️  Обнаружены проблемы (см. выше)"
