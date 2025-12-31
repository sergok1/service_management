#!/bin/bash
# apply_resource_limits.sh — Применить ограничения ресурсов для сервисов мониторинга

declare -A configs

configs[si.service]="CPUWeight=30
CPUQuota=35%
Nice=15
MemoryMax=2G
MemoryHigh=1.5G
IOWeight=20
IOSchedulingClass=best-effort
IOSchedulingPriority=7"

configs[dcservice.service]="CPUWeight=20
CPUQuota=22%
Nice=19
MemoryMax=1745M
MemoryHigh=1476M
IOWeight=10
IOSchedulingClass=idle"

configs[kesl.service]="CPUWeight=40
CPUQuota=37%
Nice=12
MemoryMax=1924M
MemoryHigh=1628M
IOWeight=20
IOSchedulingClass=best-effort
IOSchedulingPriority=7"

configs[klnagent64.service]="CPUWeight=60
CPUQuota=30%
Nice=5
MemoryMax=277M
MemoryHigh=234M
IOWeight=50
IOSchedulingClass=best-effort
IOSchedulingPriority=4"

configs[kaspersky-agent-check.service]="CPUWeight=40
CPUQuota=25%
Nice=12
MemoryMax=361M
MemoryHigh=305M
IOWeight=20
IOSchedulingClass=best-effort
IOSchedulingPriority=6"

LOG="/var/log/apply_resource_limits.log"
echo "=== [$(date)] Применение ограничений ресурсов ===" | tee -a "$LOG"

for svc in "${!configs[@]}"; do
  dir="/etc/systemd/system/$svc.d"
  echo "--- [$svc] ---" | tee -a "$LOG"
  sudo mkdir -p "$dir"
  echo -e "[Service]\n${configs[$svc]}" | sudo tee "$dir/override.conf" | tee -a "$LOG"
done

sudo systemctl daemon-reload
echo "systemctl daemon-reload выполнен" | tee -a "$LOG"

for svc in "${!configs[@]}"; do
  if systemctl is-active --quiet "$svc"; then
    sudo systemctl restart "$svc"
    echo "Перезапущен: $svc" | tee -a "$LOG"
  else
    echo "Сервис $svc не активен, пропущено" | tee -a "$LOG"
  fi
done

echo "✅ Ограничения применены" | tee -a "$LOG"
echo "=== [$(date)] Применение завершено ===" | tee -a "$LOG"
