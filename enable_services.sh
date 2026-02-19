#!/bin/bash
# Размаскировать, включить автозапуск и запустить сервисы

set -euo pipefail

# --- Проверка прав ---
if [[ $EUID -ne 0 ]]; then
  echo "❌ Этот скрипт необходимо запускать с правами root (sudo)." >&2
  exit 1
fi

# --- Загрузка списка сервисов ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$SCRIPT_DIR/services.conf"

if [[ ! -f "$CONF" ]]; then
  echo "❌ Файл конфигурации не найден: $CONF" >&2
  exit 1
fi

mapfile -t SERVICES < <(grep -v '^\s*#' "$CONF" | grep -v '^\s*$')

if [[ ${#SERVICES[@]} -eq 0 ]]; then
  echo "❌ Список сервисов пуст в $CONF" >&2
  exit 1
fi

LOG="/var/log/services_management.log"
ERRORS=0
START_SETTLE=2  # секунд ожидания после старта для проверки
UNIT_BACKUP_DIR="/var/lib/services_management/unit_backups"

# --- Проверка существования юнита ---
unit_exists() {
  systemctl list-unit-files --no-pager --no-legend "$1" 2>/dev/null | grep -q "$1"
}

echo "=== [$(date)] Включение сервисов ===" | tee -a "$LOG"

# Прямой порядок: таймеры перед сервисами (как в services.conf)
for svc in "${SERVICES[@]}"; do
  echo "--- [$svc] ---" | tee -a "$LOG"

  if ! unit_exists "$svc"; then
    echo "  ⚠️  Юнит не найден, пропускаю." | tee -a "$LOG"
    continue
  fi

  # Снимаем маску
  if systemctl unmask "$svc" 2>>"$LOG"; then
    echo "  ✓ Маска снята" | tee -a "$LOG"
  else
    echo "  ✗ Ошибка снятия маски" | tee -a "$LOG"
    ERRORS=$((ERRORS + 1))
  fi

  # Восстанавливаем unit-файл из бэкапа, если он был перемещён при маскировке
  unit_file="/etc/systemd/system/$svc"
  backup_file="$UNIT_BACKUP_DIR/$svc"
  if [[ -f "$backup_file" && ! -f "$unit_file" ]]; then
    if mv "$backup_file" "$unit_file"; then
      echo "  ✓ Unit-файл восстановлен из бэкапа" | tee -a "$LOG"
      systemctl daemon-reload
    else
      echo "  ✗ Не удалось восстановить unit-файл из бэкапа" | tee -a "$LOG"
      ERRORS=$((ERRORS + 1))
    fi
  fi

  # Включаем автозапуск
  if systemctl enable "$svc" 2>>"$LOG"; then
    echo "  ✓ Автозапуск включён" | tee -a "$LOG"
  else
    echo "  ✗ Ошибка включения автозапуска" | tee -a "$LOG"
    ERRORS=$((ERRORS + 1))
  fi

  # Запускаем
  if systemctl start "$svc" 2>>"$LOG"; then
    echo "  ✓ Запущен" | tee -a "$LOG"

    # Ждём и проверяем, что сервис не упал сразу после старта
    sleep "$START_SETTLE"
    if ! systemctl is-active --quiet "$svc"; then
      echo "  ⚠️  Сервис упал после запуска!" | tee -a "$LOG"
      journalctl -u "$svc" -n 5 --no-pager 2>/dev/null | tee -a "$LOG"
      ERRORS=$((ERRORS + 1))
    fi
  else
    echo "  ✗ Ошибка запуска" | tee -a "$LOG"
    journalctl -u "$svc" -n 5 --no-pager 2>/dev/null | tee -a "$LOG"
    ERRORS=$((ERRORS + 1))
  fi

  echo "" | tee -a "$LOG"
done

# --- Итоговый статус ---
echo "=== Статус сервисов ===" | tee -a "$LOG"
for svc in "${SERVICES[@]}"; do
  if unit_exists "$svc"; then
    state=$(systemctl is-active "$svc" 2>/dev/null || true)
    enabled=$(systemctl is-enabled "$svc" 2>/dev/null || true)
    printf "  %-40s active=%-10s enabled=%s\n" "$svc" "$state" "$enabled" | tee -a "$LOG"
  fi
done

echo "" | tee -a "$LOG"
echo "=== [$(date)] Включение завершено (ошибок: $ERRORS) ===" | tee -a "$LOG"

if [[ $ERRORS -gt 0 ]]; then
  echo "⚠️  Были ошибки, проверьте лог: $LOG"
  exit 1
fi
