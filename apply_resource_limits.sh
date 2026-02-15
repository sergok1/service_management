#!/bin/bash
# Применяет ограничения ресурсов для сервисов через systemd drop-in

set -euo pipefail

# --- Проверка прав ---
if [[ $EUID -ne 0 ]]; then
  echo "❌ Этот скрипт необходимо запускать с правами root (sudo)." >&2
  exit 1
fi

LOG="/var/log/services_management.log"
ERRORS=0

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

echo "=== [$(date)] Применение ограничений ресурсов ===" | tee -a "$LOG"

for svc in "${!configs[@]}"; do
  echo "--- [$svc] ---" | tee -a "$LOG"

  dir="/etc/systemd/system/$svc.d"
  mkdir -p "$dir"

  echo -e "[Service]\n${configs[$svc]}" > "$dir/override.conf" && \
    echo "  ✓ override.conf создан: $dir/override.conf" | tee -a "$LOG" || {
    echo "  ✗ Ошибка создания override.conf" | tee -a "$LOG"
    ((ERRORS++))
  }
done

echo "Перезагрузка конфигурации systemd..." | tee -a "$LOG"
systemctl daemon-reload

for svc in "${!configs[@]}"; do
  if systemctl is-active --quiet "$svc"; then
    systemctl restart "$svc" && echo "  ✓ $svc перезапущен" | tee -a "$LOG" || {
      echo "  ✗ Ошибка перезапуска $svc" | tee -a "$LOG"
      ((ERRORS++))
    }
  else
    echo "  — $svc не активен, перезапуск не требуется" | tee -a "$LOG"
  fi
done

echo "=== [$(date)] Ограничения применены (ошибок: $ERRORS) ===" | tee -a "$LOG"

if [[ $ERRORS -gt 0 ]]; then
  echo "⚠️  Были ошибки, проверьте лог: $LOG"
  exit 1
fi
