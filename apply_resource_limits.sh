#!/bin/bash
# применяет оптимальные настройки для сервисов

declare -A configs
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

for svc in "${!configs[@]}"; do
  dir="/etc/systemd/system/$svc.d"
  sudo mkdir -p "$dir"
  echo -e "[Service]\n${configs[$svc]}" | sudo tee "$dir/override.conf"
done

sudo systemctl daemon-reload
for svc in "${!configs[@]}"; do
  sudo systemctl restart "$svc"
done

echo "✅ Ограничения применены и сервисы перезапущены."
