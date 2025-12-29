#!/bin/bash
# Включить автозапуск и запустить сервисы

SERVICES=(
  "dcservice.service"
  "kesl.service"
  "klnagent64.service"
  "kaspersky-agent-check"
  "kaspersky-agent-check.service"
  "kaspersky-agent-check.timer"
)

LOG="/var/log/services_management.log"
echo "=== [$(date)] Включение сервисов ===" | tee -a "$LOG"

for svc in "${SERVICES[@]}"; do
  echo "--- [$svc] ---" | tee -a "$LOG"
  sudo systemctl enable "$svc" 2>>"$LOG"
  sudo systemctl start "$svc" 2>>"$LOG"
  sudo systemctl status "$svc" --no-pager | tee -a "$LOG"
done

echo "=== [$(date)] Включение завершено ===" | tee -a "$LOG"
