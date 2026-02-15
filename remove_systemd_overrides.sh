#!/bin/bash
# Удаляет systemd drop-in override.conf для сервисов и откатывает ограничения

set -euo pipefail

# --- Проверка прав ---
if [[ $EUID -ne 0 ]]; then
  echo "❌ Этот скрипт необходимо запускать с правами root (sudo)." >&2
  exit 1
fi

SERVICES=(
  "si.service"
  "dcservice.service"
  "kesl.service"
  "klnagent64.service"
  "kaspersky-agent-check.service"
  "kaspersky-agent-check.timer"
)

LOG="/var/log/services_management.log"
BACKUP_DIR="/root/systemd_override_backups_$(date +%Y%m%d_%H%M%S)"
ERRORS=0

echo "=== [$(date)] Удаление systemd override.conf ===" | tee -a "$LOG"
echo "Резервные копии: $BACKUP_DIR" | tee -a "$LOG"
mkdir -p "$BACKUP_DIR"

for svc in "${SERVICES[@]}"; do
  DIR="/etc/systemd/system/$svc.d"
  FILE="$DIR/override.conf"

  if [[ -f "$FILE" ]]; then
    echo "--- [$svc] ---" | tee -a "$LOG"

    mkdir -p "$BACKUP_DIR/$svc.d"
    cp "$FILE" "$BACKUP_DIR/$svc.d/override.conf" && \
      echo "  ✓ Бэкап: $BACKUP_DIR/$svc.d/override.conf" | tee -a "$LOG" || {
      echo "  ✗ Ошибка создания бэкапа" | tee -a "$LOG"
      ((ERRORS++))
      continue
    }

    rm -f "$FILE" && echo "  ✓ Удалён: $FILE" | tee -a "$LOG" || {
      echo "  ✗ Ошибка удаления" | tee -a "$LOG"
      ((ERRORS++))
    }

    # Удалить пустую директорию
    rmdir --ignore-fail-on-non-empty "$DIR" 2>/dev/null && \
      echo "  ✓ Удалена пустая директория: $DIR" | tee -a "$LOG" || true
  else
    echo "--- [$svc] --- override.conf не найден, пропущено." | tee -a "$LOG"
  fi
done

echo "Перезагрузка конфигурации systemd..." | tee -a "$LOG"
systemctl daemon-reload

# Перезапуск активных сервисов
for svc in "${SERVICES[@]}"; do
  if systemctl is-active --quiet "$svc"; then
    systemctl restart "$svc" && echo "  ✓ $svc перезапущен" | tee -a "$LOG" || {
      echo "  ✗ Ошибка перезапуска $svc" | tee -a "$LOG"
      ((ERRORS++))
    }
  fi
done

echo "=== [$(date)] Удаление завершено (ошибок: $ERRORS) ===" | tee -a "$LOG"

if [[ $ERRORS -gt 0 ]]; then
  echo "⚠️  Были ошибки, проверьте лог: $LOG"
  exit 1
fi
