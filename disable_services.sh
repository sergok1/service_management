#!/bin/bash
# Остановить, отключить автозапуск и замаскировать сервисы

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
STOP_TIMEOUT=60  # секунд на остановку одного сервиса
UNIT_BACKUP_DIR="/var/lib/services_management/unit_backups"

# --- Проверка существования юнита ---
unit_exists() {
  systemctl list-unit-files --no-pager --no-legend "$1" 2>/dev/null | grep -q "$1"
}

echo "=== [$(date)] Отключение сервисов ===" | tee -a "$LOG"

# Обратный порядок: сначала таймеры, потом сервисы
# (при отключении таймер нужно остановить до сервиса, чтобы он не перезапустил его)
for (( i=${#SERVICES[@]}-1; i>=0; i-- )); do
  svc="${SERVICES[$i]}"
  echo "--- [$svc] ---" | tee -a "$LOG"

  if ! unit_exists "$svc"; then
    echo "  ⚠️  Юнит не найден, пропускаю." | tee -a "$LOG"
    continue
  fi

  # Останавливаем с таймаутом; если graceful stop не помог — kill
  if systemctl is-active --quiet "$svc"; then
    if timeout "$STOP_TIMEOUT" systemctl stop "$svc" 2>>"$LOG"; then
      echo "  ✓ Остановлен" | tee -a "$LOG"
    else
      echo "  ⚠️  Graceful stop не удался (${STOP_TIMEOUT}с), принудительное завершение..." | tee -a "$LOG"
      if systemctl kill --signal=SIGKILL "$svc" 2>>"$LOG"; then
        echo "  ✓ Принудительно остановлен (SIGKILL)" | tee -a "$LOG"
      else
        echo "  ✗ Не удалось остановить даже принудительно" | tee -a "$LOG"
        ERRORS=$((ERRORS + 1))
      fi
    fi
  else
    echo "  — Уже остановлен" | tee -a "$LOG"
  fi

  # Отключаем автозапуск
  if systemctl disable "$svc" 2>>"$LOG"; then
    echo "  ✓ Автозапуск отключён" | tee -a "$LOG"
  else
    echo "  ✗ Ошибка отключения автозапуска" | tee -a "$LOG"
    ERRORS=$((ERRORS + 1))
  fi

  # Маскируем — предотвращает запуск по зависимости.
  # systemctl mask создаёт симлинк /etc/systemd/system/<unit> -> /dev/null,
  # но если там уже лежит реальный файл (не симлинк), mask откажет.
  # В этом случае перемещаем файл в бэкап, чтобы mask прошёл.
  unit_file="/etc/systemd/system/$svc"
  if [[ -f "$unit_file" && ! -L "$unit_file" ]]; then
    mkdir -p "$UNIT_BACKUP_DIR"
    if mv "$unit_file" "$UNIT_BACKUP_DIR/$svc"; then
      echo "  ✓ Unit-файл перемещён в бэкап: $UNIT_BACKUP_DIR/$svc" | tee -a "$LOG"
      systemctl daemon-reload
    else
      echo "  ✗ Не удалось переместить unit-файл в бэкап" | tee -a "$LOG"
      ERRORS=$((ERRORS + 1))
    fi
  fi

  if systemctl mask "$svc" 2>>"$LOG"; then
    echo "  ✓ Замаскирован" | tee -a "$LOG"
  else
    echo "  ✗ Ошибка маскировки" | tee -a "$LOG"
    ERRORS=$((ERRORS + 1))
  fi

  systemctl reset-failed "$svc" 2>/dev/null || true

  echo "" | tee -a "$LOG"
done

# --- Проверка оставшихся процессов ---
echo "=== Проверка оставшихся процессов ===" | tee -a "$LOG"
remaining=$(pgrep -af 'siagent|traffic_parser|netfilter|x11monitor|sid_lookup|dcservice' 2>/dev/null || true)
if [[ -z "$remaining" ]]; then
  echo "✅ Все процессы остановлены" | tee -a "$LOG"
else
  echo "⚠️  Обнаружены оставшиеся процессы:" | tee -a "$LOG"
  echo "$remaining" | tee -a "$LOG"
fi

# --- Итоговый статус ---
echo "" | tee -a "$LOG"
echo "=== Статус сервисов ===" | tee -a "$LOG"
for svc in "${SERVICES[@]}"; do
  if unit_exists "$svc"; then
    state=$(systemctl is-active "$svc" 2>/dev/null || true)
    enabled=$(systemctl is-enabled "$svc" 2>/dev/null || true)
    printf "  %-40s active=%-10s enabled=%s\n" "$svc" "$state" "$enabled" | tee -a "$LOG"
  fi
done

echo "" | tee -a "$LOG"
echo "=== [$(date)] Отключение завершено (ошибок: $ERRORS) ===" | tee -a "$LOG"

if [[ $ERRORS -gt 0 ]]; then
  echo "⚠️  Были ошибки, проверьте лог: $LOG"
  exit 1
fi
