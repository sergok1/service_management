#!/bin/bash
# Размаскировать, включить автозапуск и запустить сервисы

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

echo "=== [$(date)] Включение сервисов ===" | tee -a "$LOG"

for svc in "${SERVICES[@]}"; do
  echo "--- [$svc] ---" | tee -a "$LOG"

  # Проверяем, существует ли юнит
  if ! systemctl list-unit-files "$svc" &>/dev/null; then
    echo "⚠️  Юнит $svc не найден, пропускаю." | tee -a "$LOG"
    continue
  fi

  # Снимаем маску (если была замаскирована)
  systemctl unmask "$svc" 2>>"$LOG" && echo "  ✓ Маска снята" | tee -a "$LOG" || {
    echo "  ✗ Ошибка снятия маски" | tee -a "$LOG"
    ((ERRORS++))
  }

  # Включаем автозапуск
  systemctl enable "$svc" 2>>"$LOG" && echo "  ✓ Автозапуск включён" | tee -a "$LOG" || {
    echo "  ✗ Ошибка включения автозапуска" | tee -a "$LOG"
    ((ERRORS++))
  }

  # Запускаем
  systemctl start "$svc" 2>>"$LOG" && echo "  ✓ Запущен" | tee -a "$LOG" || {
    echo "  ✗ Ошибка запуска" | tee -a "$LOG"
    ((ERRORS++))
  }

  systemctl status "$svc" --no-pager 2>&1 | tee -a "$LOG"
  echo "" | tee -a "$LOG"
done

echo "=== [$(date)] Включение завершено (ошибок: $ERRORS) ===" | tee -a "$LOG"

if [[ $ERRORS -gt 0 ]]; then
  echo "⚠️  Были ошибки, проверьте лог: $LOG"
  exit 1
fi
