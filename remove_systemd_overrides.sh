#!/bin/bash
# Скрипт для удаления systemd drop-in override.conf для сервисов

set -e

SERVICES=(
  "dcservice.service"
  "kesl.service"
  "klnagent64.service"
  "kaspersky-agent-check.service"
  "kaspersky-agent-check.timer"
)

LOG="/var/log/remove_overrides.log"
BACKUP_DIR="/root/systemd_override_backups_$(date +%Y%m%d_%H%M%S)"

echo "=== [$(date)] Удаление systemd override.conf для сервисов ===" | tee -a "$LOG"
echo "Резервные копии будут сохранены в $BACKUP_DIR" | tee -a "$LOG"
mkdir -p "$BACKUP_DIR"

for svc in "${SERVICES[@]}"; do
  DIR="/etc/systemd/system/$svc.d"
  FILE="$DIR/override.conf"
  if [ -f "$FILE" ]; then
    echo "--- [$svc] ---" | tee -a "$LOG"
    mkdir -p "$BACKUP_DIR/$svc.d"
    cp "$FILE" "$BACKUP_DIR/$svc.d/override.conf" && echo "Backup: $FILE" | tee -a "$LOG"
    rm -f "$FILE" && echo "Удалён: $FILE" | tee -a "$LOG"
    # Удалить пустую директорию
    rmdir --ignore-fail-on-non-empty "$DIR" 2>/dev/null && echo "Удалена пустая директория: $DIR" | tee -a "$LOG"
  else
    echo "--- [$svc] --- override.conf не найден, пропущено." | tee -a "$LOG"
  fi
done

systemctl daemon-reload
echo "systemctl daemon-reload выполнен." | tee -a "$LOG"

# Перезапуск сервисов (если активны)
for svc in "${SERVICES[@]}"; do
  if systemctl is-active --quiet "$svc"; then
    systemctl restart "$svc"
    echo "Перезапущен: $svc" | tee -a "$LOG"
  fi
done

echo "=== [$(date)] Удаление завершено ===" | tee -a "$LOG"
echo "Резервные копии override.conf сохранены в $BACKUP_DIR"
