#!/bin/bash
# Остановить и отключить автозапуск сервисов

SERVICES=(
  "dcservice.service"
  "kesl.service"
  "klnagent64.service"
  "kaspersky-agent-check"
  "kaspersky-agent-check.service"
  "kaspersky-agent-check.timer"
)

LOG="/var/log/services_management.log"
echo "=== [$(date)] Отключение сервисов ===" | tee -a "$LOG"

for svc in "${SERVICES[@]}"; do
  echo "--- [$svc] ---" | tee -a "$LOG"
  sudo systemctl stop "$svc" 2>>"$LOG"
  sudo systemctl disable "$svc" 2>>"$LOG"
  sudo systemctl status "$svc" --no-pager | tee -a "$LOG"
done

echo "=== [$(date)] Отключение завершено ===" | tee -a "$LOG"
