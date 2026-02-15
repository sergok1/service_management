#!/bin/bash
# Остановить, отключить автозапуск и замаскировать сервисы

set -euo pipefail

# --- Проверка прав ---
if [[ $EUID -ne 0 ]]; then
  echo "❌ Этот скрипт необходимо запускать с правами root (sudo)." >&2
  exit 1
fi

SERVICES=(
  "dcservice.service"
  "kesl.service"
  "klnagent64.service"
  "kaspersky-agent-check.service"
  "kaspersky-agent-check.timer"
)

LOG="/var/log/services_management.log"
ERRORS=0

echo "=== [$(date)] Отключение сервисов ===" | tee -a "$LOG"

for svc in "${SERVICES[@]}"; do
  echo "--- [$svc] ---" | tee -a "$LOG"

  # Проверяем, существует ли юнит
  if ! systemctl list-unit-files "$svc" &>/dev/null; then
    echo "⚠️  Юнит $svc не найден, пропускаю." | tee -a "$LOG"
    continue
  fi

  # Останавливаем (игнорируем ошибку, если уже остановлен)
  if systemctl is-active --quiet "$svc"; then
    systemctl stop "$svc" 2>>"$LOG" && echo "  ✓ Остановлен" | tee -a "$LOG" || {
      echo "  ✗ Ошибка остановки" | tee -a "$LOG"
      ((ERRORS++))
    }
  else
    echo "  — Уже остановлен" | tee -a "$LOG"
  fi

  # Отключаем автозапуск
  systemctl disable "$svc" 2>>"$LOG" && echo "  ✓ Автозапуск отключён" | tee -a "$LOG" || {
    echo "  ✗ Ошибка отключения автозапуска" | tee -a "$LOG"
    ((ERRORS++))
  }

  # Маскируем — предотвращает запуск по зависимости
  systemctl mask "$svc" 2>>"$LOG" && echo "  ✓ Замаскирован" | tee -a "$LOG" || {
    echo "  ✗ Ошибка маскировки" | tee -a "$LOG"
    ((ERRORS++))
  }

  systemctl status "$svc" --no-pager 2>&1 | tee -a "$LOG"
  echo "" | tee -a "$LOG"
done

echo "=== [$(date)] Отключение завершено (ошибок: $ERRORS) ===" | tee -a "$LOG"

if [[ $ERRORS -gt 0 ]]; then
  echo "⚠️  Были ошибки, проверьте лог: $LOG"
  exit 1
fi
