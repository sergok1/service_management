#!/bin/bash
# Удаляет systemd drop-in override.conf для сервисов и откатывает ограничения

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
BACKUP_BASE="/root/systemd_override_backups"
BACKUP_DIR="${BACKUP_BASE}_$(date +%Y%m%d_%H%M%S)"
MAX_BACKUPS=5  # хранить не более N последних бэкапов
ERRORS=0
FOUND=0

echo "=== [$(date)] Удаление systemd override.conf ===" | tee -a "$LOG"

# --- Проверяем, есть ли что удалять ---
for svc in "${SERVICES[@]}"; do
  if [[ -f "/etc/systemd/system/$svc.d/override.conf" ]]; then
    ((FOUND++))
  fi
done

if [[ $FOUND -eq 0 ]]; then
  echo "Нет override.conf для удаления, ничего делать не нужно." | tee -a "$LOG"
  echo "=== [$(date)] Удаление завершено (нечего удалять) ===" | tee -a "$LOG"
  exit 0
fi

# --- Создаём бэкап только если есть что бэкапить ---
echo "Резервные копии: $BACKUP_DIR" | tee -a "$LOG"
mkdir -p "$BACKUP_DIR"

for svc in "${SERVICES[@]}"; do
  DIR="/etc/systemd/system/$svc.d"
  FILE="$DIR/override.conf"

  if [[ -f "$FILE" ]]; then
    echo "--- [$svc] ---" | tee -a "$LOG"

    mkdir -p "$BACKUP_DIR/$svc.d"
    if cp "$FILE" "$BACKUP_DIR/$svc.d/override.conf"; then
      echo "  ✓ Бэкап: $BACKUP_DIR/$svc.d/override.conf" | tee -a "$LOG"
    else
      echo "  ✗ Ошибка создания бэкапа" | tee -a "$LOG"
      ((ERRORS++))
      continue
    fi

    if rm -f "$FILE"; then
      echo "  ✓ Удалён: $FILE" | tee -a "$LOG"
    else
      echo "  ✗ Ошибка удаления" | tee -a "$LOG"
      ((ERRORS++))
    fi

    # Удалить пустую директорию
    rmdir --ignore-fail-on-non-empty "$DIR" 2>/dev/null && \
      echo "  ✓ Удалена пустая директория: $DIR" | tee -a "$LOG" || true

    echo "" | tee -a "$LOG"
  else
    echo "--- [$svc] --- override.conf не найден, пропущено." | tee -a "$LOG"
  fi
done

echo "Перезагрузка конфигурации systemd..." | tee -a "$LOG"
systemctl daemon-reload

# --- Перезапуск активных сервисов ---
for svc in "${SERVICES[@]}"; do
  if systemctl is-active --quiet "$svc"; then
    if systemctl restart "$svc"; then
      echo "  ✓ $svc перезапущен" | tee -a "$LOG"
    else
      echo "  ✗ Ошибка перезапуска $svc" | tee -a "$LOG"
      ((ERRORS++))
    fi
  fi
done

# --- Очистка старых бэкапов (оставляем последние MAX_BACKUPS) ---
old_backups=$(ls -1dt ${BACKUP_BASE}_* 2>/dev/null | tail -n +$((MAX_BACKUPS + 1)))
if [[ -n "$old_backups" ]]; then
  echo "" | tee -a "$LOG"
  echo "Очистка старых бэкапов (оставляем последние $MAX_BACKUPS):" | tee -a "$LOG"
  while IFS= read -r dir; do
    rm -rf "$dir" && echo "  ✓ Удалён: $dir" | tee -a "$LOG"
  done <<< "$old_backups"
fi

echo "" | tee -a "$LOG"
echo "=== [$(date)] Удаление завершено (ошибок: $ERRORS) ===" | tee -a "$LOG"

if [[ $ERRORS -gt 0 ]]; then
  echo "⚠️  Были ошибки, проверьте лог: $LOG"
  exit 1
fi
