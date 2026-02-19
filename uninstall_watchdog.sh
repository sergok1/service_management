#!/bin/bash
# Полностью удаляет watchdog: останавливает таймер, удаляет юниты и файлы.
# Запускать с sudo.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "❌ Запустите с sudo." >&2
  exit 1
fi

INSTALL_DIR="/opt/services_management"
SYSTEMD_DIR="/etc/systemd/system"

echo "=== Удаление watchdog ==="

if systemctl is-active --quiet services-watchdog.timer 2>/dev/null; then
  systemctl stop services-watchdog.timer
  echo "  ✓ Таймер остановлен"
fi

if systemctl is-enabled --quiet services-watchdog.timer 2>/dev/null; then
  systemctl disable services-watchdog.timer
  echo "  ✓ Автозапуск таймера отключён"
fi

for f in services-watchdog.service services-watchdog.timer; do
  if [[ -f "$SYSTEMD_DIR/$f" ]]; then
    rm -f "$SYSTEMD_DIR/$f"
    echo "  ✓ Удалён $SYSTEMD_DIR/$f"
  fi
done

systemctl daemon-reload
echo "  ✓ systemd перезагружен"

if [[ -d "$INSTALL_DIR" ]]; then
  rm -rf "$INSTALL_DIR"
  echo "  ✓ Удалён $INSTALL_DIR"
fi

echo ""
echo "✅ Watchdog полностью удалён."
echo "   Лог остался: /var/log/services_management_watchdog.log"
