#!/bin/bash
# Применяет ограничения ресурсов для сервисов через systemd drop-in
#
# Логика лимитов:
#   CPUWeight    — относительный приоритет CPU между сервисами (1-10000, default=100).
#                  Работает только при конкуренции за CPU.
#   CPUQuota     — жёсткий потолок CPU (% от одного ядра). Действует даже на idle-системе.
#   Nice         — приоритет планировщика (-20..19, выше число = ниже приоритет).
#   MemoryHigh   — мягкий лимит: ядро начинает рекламировать (reclaim) память.
#   MemoryMax    — жёсткий лимит: при превышении OOM killer убьёт процесс.
#                  Зазор между MemoryHigh и MemoryMax даёт процессу время среагировать.
#   IOWeight     — относительный приоритет I/O (1-10000, default=100).
#   IOSchedulingClass   — класс I/O планировщика (best-effort рекомендуется;
#                         idle на практике плохо работает с async writes).
#   IOSchedulingPriority — приоритет внутри класса (0=высший, 7=низший).
#   LimitNOFILE  — лимит файловых дескрипторов (рекомендация Kaspersky для klnagent64).

set -euo pipefail

# --- Проверка прав ---
if [[ $EUID -ne 0 ]]; then
  echo "❌ Этот скрипт необходимо запускать с правами root (sudo)." >&2
  exit 1
fi

LOG="/var/log/services_management.log"
ERRORS=0

declare -A configs

# --- si.service (SIAGENT) ---
# Тяжёлый агент: множество дочерних процессов (traffic_parser, netfilter, x11monitor и др.)
# Агрессивные лимиты CPU/RAM, минимальный I/O приоритет
configs[si.service]="CPUWeight=10
CPUQuota=30%
Nice=19
MemoryMax=2G
MemoryHigh=1536M
IOWeight=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7"

# --- dcservice.service (ManageEngine UEMS Agent) ---
# Периодически сканирует систему, может давать всплески CPU.
# IOSchedulingClass=best-effort вместо idle (idle не работает для async writes)
configs[dcservice.service]="CPUWeight=15
CPUQuota=20%
Nice=19
MemoryMax=1745M
MemoryHigh=1400M
IOWeight=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7"

# --- kesl.service (Kaspersky Endpoint Security) ---
# Самый ресурсоёмкий из Kaspersky-сервисов.
# Дополнительно рекомендуется настроить встроенные лимиты:
#   /var/opt/kaspersky/kesl/common/kesl.ini → [General] ScanMemoryLimit=2048
#   kesl-control --set-settings <ODS task ID> ScanPriority=Idle
configs[kesl.service]="CPUWeight=30
CPUQuota=35%
Nice=15
MemoryMax=1924M
MemoryHigh=1536M
IOWeight=20
IOSchedulingClass=best-effort
IOSchedulingPriority=6"

# --- klnagent64.service (Kaspersky Network Agent) ---
# Лёгкий агент связи с KSC. Низкое потребление RAM, но может открывать много fd.
# LimitNOFILE рекомендован документацией Kaspersky.
# Также можно включить low resource consumption mode в политике KSC.
configs[klnagent64.service]="CPUWeight=50
CPUQuota=25%
Nice=10
MemoryMax=350M
MemoryHigh=256M
IOWeight=30
IOSchedulingClass=best-effort
IOSchedulingPriority=5
LimitNOFILE=4096:8192"

# --- kaspersky-agent-check.service ---
# Периодическая проверка состояния агентов (запускается таймером).
# Кратковременный процесс — лимиты мягкие.
configs[kaspersky-agent-check.service]="CPUWeight=20
CPUQuota=20%
Nice=19
MemoryMax=361M
MemoryHigh=256M
IOWeight=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7"

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
