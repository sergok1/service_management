#!/bin/bash
# enable_services.sh — Включить и запустить сервисы мониторинга

SERVICES=(
  "si.service"
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
  sudo systemctl unmask "$svc" 2>>"$LOG" || echo "Сервис не был замаскирован"
  sudo systemctl enable "$svc" 2>>"$LOG"
  sudo systemctl start "$svc" 2>>"$LOG"
  sudo systemctl status "$svc" --no-pager | grep -E "Loaded|Active" | tee -a "$LOG"
done

echo "=== [$(date)] Включение завершено ===" | tee -a "$LOG"
