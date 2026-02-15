#!/bin/bash
# Применяет ограничения ресурсов для сервисов через systemd drop-in
#
# Логика лимитов:
#   CPUWeight    — относительный приоритет CPU между сервисами (1-10000, default=100).
#                  Работает только при конкуренции за CPU. 1 = минимальный приоритет.
#   CPUQuota     — жёсткий потолок CPU (% от одного ядра). Действует даже на idle-системе.
#   Nice         — приоритет планировщика (-20..19). 19 = минимальный приоритет.
#                  Каждый шаг nice ≈ 1.25x разницы в CPU-времени (CFS scheduler).
#                  Nice=19 получает ~15x меньше CPU чем Nice=0 (дефолт).
#   MemoryHigh   — мягкий лимит: ядро начинает reclaim памяти, процесс замедляется.
#   MemoryMax    — жёсткий лимит: при превышении OOM killer убьёт процесс.
#                  ВАЖНО: слишком низкий MemoryMax → OOM-kill → restart loop.
#                  Зазор MemoryHigh..MemoryMax даёт процессу время среагировать.
#   IOWeight     — относительный приоритет I/O (1-10000, default=100). 1 = минимальный.
#   IOSchedulingClass   — best-effort рекомендуется (idle не работает для async writes).
#   IOSchedulingPriority — приоритет внутри класса (0=высший, 7=низший).
#   LimitNOFILE  — лимит файловых дескрипторов.

set -euo pipefail

# --- Проверка прав ---
if [[ $EUID -ne 0 ]]; then
  echo "❌ Этот скрипт необходимо запускать с правами root (sudo)." >&2
  exit 1
fi

LOG="/var/log/services_management.log"
ERRORS=0

# --- Проверка существования юнита ---
unit_exists() {
  systemctl list-unit-files --no-pager --no-legend "$1" 2>/dev/null | grep -q "$1"
}

declare -A configs

# --- si.service (SIAGENT) ---
# Тяжёлый агент: множество дочерних процессов (traffic_parser, netfilter, x11monitor и др.)
# Максимально агрессивные лимиты: минимальный CPUWeight, Nice=19, CPUQuota=15%
configs[si.service]="CPUWeight=1
CPUQuota=15%
Nice=19
MemoryMax=1536M
MemoryHigh=1200M
IOWeight=1
IOSchedulingClass=best-effort
IOSchedulingPriority=7"

# --- dcservice.service (ManageEngine UEMS Agent) ---
# Периодически сканирует систему, может давать всплески CPU.
# Минимальные требования: 512 МБ RAM, 1 GHz CPU.
configs[dcservice.service]="CPUWeight=1
CPUQuota=15%
Nice=19
MemoryMax=768M
MemoryHigh=512M
IOWeight=1
IOSchedulingClass=best-effort
IOSchedulingPriority=7"

# --- kesl.service (Kaspersky Endpoint Security) ---
# Самый ресурсоёмкий. Минимальные требования: 2 ГБ RAM (x64).
# MemoryMax не ниже 2G — иначе OOM-kill и restart loop.
# Дополнительно рекомендуется настроить встроенные лимиты:
#   /var/opt/kaspersky/kesl/common/kesl.ini → [General] ScanMemoryLimit=2048
#   kesl-control --set-settings <ODS task ID> ScanPriority=Idle
configs[kesl.service]="CPUWeight=1
CPUQuota=20%
Nice=19
MemoryMax=2G
MemoryHigh=1536M
IOWeight=1
IOSchedulingClass=best-effort
IOSchedulingPriority=7"

# --- klnagent64.service (Kaspersky Network Agent) ---
# Лёгкий агент связи с KSC. Низкое потребление RAM.
# Можно включить low resource consumption mode в политике KSC.
configs[klnagent64.service]="CPUWeight=1
CPUQuota=10%
Nice=19
MemoryMax=256M
MemoryHigh=192M
IOWeight=1
IOSchedulingClass=best-effort
IOSchedulingPriority=7
LimitNOFILE=4096:8192"

# --- kaspersky-agent-check.service ---
# Периодическая проверка состояния агентов (запускается таймером).
# Кратковременный процесс — жёсткие лимиты безопасны.
configs[kaspersky-agent-check.service]="CPUWeight=1
CPUQuota=10%
Nice=19
MemoryMax=256M
MemoryHigh=192M
IOWeight=1
IOSchedulingClass=best-effort
IOSchedulingPriority=7"

echo "=== [$(date)] Применение ограничений ресурсов ===" | tee -a "$LOG"

for svc in "${!configs[@]}"; do
  echo "--- [$svc] ---" | tee -a "$LOG"

  if ! unit_exists "$svc"; then
    echo "  ⚠️  Юнит не найден, пропускаю." | tee -a "$LOG"
    continue
  fi

  dir="/etc/systemd/system/$svc.d"
  mkdir -p "$dir"

  if echo -e "[Service]\n${configs[$svc]}" > "$dir/override.conf"; then
    echo "  ✓ override.conf создан: $dir/override.conf" | tee -a "$LOG"
  else
    echo "  ✗ Ошибка создания override.conf" | tee -a "$LOG"
    ((ERRORS++))
  fi
done

echo "Перезагрузка конфигурации systemd..." | tee -a "$LOG"
systemctl daemon-reload

for svc in "${!configs[@]}"; do
  if ! unit_exists "$svc"; then
    continue
  fi

  if systemctl is-active --quiet "$svc"; then
    if systemctl restart "$svc" 2>>"$LOG"; then
      echo "  ✓ $svc перезапущен" | tee -a "$LOG"
      # Проверяем, что сервис не упал после рестарта с новыми лимитами
      sleep 2
      if systemctl is-failed --quiet "$svc"; then
        echo "  ⚠️  $svc упал после перезапуска (возможно, лимиты слишком жёсткие)" | tee -a "$LOG"
        journalctl -u "$svc" -n 5 --no-pager 2>/dev/null | tee -a "$LOG"
        ((ERRORS++))
      fi
    else
      echo "  ✗ Ошибка перезапуска $svc" | tee -a "$LOG"
      ((ERRORS++))
    fi
  else
    echo "  — $svc не активен, перезапуск не требуется" | tee -a "$LOG"
  fi
done

# --- Итоговый статус ---
echo "" | tee -a "$LOG"
echo "=== Статус сервисов ===" | tee -a "$LOG"
for svc in "${!configs[@]}"; do
  if unit_exists "$svc"; then
    state=$(systemctl is-active "$svc" 2>/dev/null || true)
    printf "  %-40s %s\n" "$svc" "$state" | tee -a "$LOG"
  fi
done

echo "" | tee -a "$LOG"
echo "=== [$(date)] Ограничения применены (ошибок: $ERRORS) ===" | tee -a "$LOG"

if [[ $ERRORS -gt 0 ]]; then
  echo "⚠️  Были ошибки, проверьте лог: $LOG"
  exit 1
fi
