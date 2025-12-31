#!/bin/bash
# disable_services.sh — Остановить и отключить автозапуск сервисов мониторинга

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
echo "=== [$(date)] Отключение сервисов ===" | tee -a "$LOG"

for svc in "${SERVICES[@]}"; do
  echo "--- [$svc] ---" | tee -a "$LOG"
  sudo systemctl stop "$svc" 2>>"$LOG"
  sudo systemctl disable "$svc" 2>>"$LOG"
  sudo systemctl status "$svc" --no-pager | grep -E "Loaded|Active" | tee -a "$LOG"
done

# Проверить, что процессы SIAGENT остановлены
echo "=== Проверка процессов SIAGENT ===" | tee -a "$LOG"
remaining=$(ps aux | grep -E 'siagent|traffic_parser|netfilter|x11monitor|sid_lookup' | grep -v grep)
if [ -z "$remaining" ]; then
  echo "✅ Все процессы SIAGENT остановлены" | tee -a "$LOG"
else
  echo "⚠️ Обнаружены оставшиеся процессы:" | tee -a "$LOG"
  echo "$remaining" | tee -a "$LOG"
fi

echo "=== [$(date)] Отключение завершено ===" | tee -a "$LOG"
