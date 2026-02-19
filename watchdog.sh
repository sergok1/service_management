#!/bin/bash
# Watchdog: периодическая проверка, что наблюдательные службы остаются отключёнными.
#
# Проверяет:
#   1. Все сервисы из services.conf замаскированы и не запущены
#   2. Нет процессов от агентов мониторинга
#   3. Нет чужих пользовательских сессий
#   4. Нет новых подозрительных systemd-юнитов
#
# При обнаружении проблемы: логирует, выводит десктоп-уведомление,
# опционально автоматически маскирует/останавливает нарушителей.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICES_CONF="$SCRIPT_DIR/services.conf"
WATCHDOG_CONF="$SCRIPT_DIR/watchdog.conf"

# --- Загрузка конфигурации ---
if [[ ! -f "$WATCHDOG_CONF" ]]; then
  echo "❌ Конфигурация не найдена: $WATCHDOG_CONF" >&2
  exit 1
fi
source "$WATCHDOG_CONF"

if [[ ! -f "$SERVICES_CONF" ]]; then
  echo "❌ Список сервисов не найден: $SERVICES_CONF" >&2
  exit 1
fi

mapfile -t SERVICES < <(grep -v '^\s*#' "$SERVICES_CONF" | grep -v '^\s*$')

LOG="${WATCHDOG_LOG:-/var/log/services_management_watchdog.log}"
ALERTS=0
REPORT=""
AUTO_FIX=false

if [[ "${1:-}" == "--fix" ]]; then
  AUTO_FIX=true
fi

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
  echo "$msg" | tee -a "$LOG"
}

alert() {
  local msg="$1"
  REPORT+="  ⚠️  $msg"$'\n'
  ALERTS=$((ALERTS + 1))
  log "ALERT: $msg"
}

ok() {
  log "OK: $1"
}

# --- Десктоп-уведомление ---
# Работает и от root (через runuser), и от обычного пользователя.
notify_desktop() {
  local title="$1"
  local body="$2"
  local urgency="${3:-critical}"

  if [[ "${NOTIFY_DESKTOP:-false}" != "true" ]]; then
    return
  fi

  if ! command -v notify-send &>/dev/null; then
    return
  fi

  local target_user="${MY_USER:-}"
  if [[ -z "$target_user" ]]; then
    return
  fi

  local uid
  uid=$(id -u "$target_user" 2>/dev/null) || return

  if [[ $EUID -eq 0 ]]; then
    runuser -u "$target_user" -- env \
      DISPLAY=:0 \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
      notify-send -u "$urgency" -i dialog-warning "$title" "$body" 2>/dev/null || true
  else
    DISPLAY=:0 notify-send -u "$urgency" -i dialog-warning "$title" "$body" 2>/dev/null || true
  fi
}

log "=== Watchdog check started (fix=${AUTO_FIX}) ==="

# ============================================================
# 1. Проверка: сервисы из services.conf замаскированы и не активны
# ============================================================
log "--- Проверка статуса сервисов ---"
for svc in "${SERVICES[@]}"; do
  enabled_state=$(systemctl is-enabled "$svc" 2>/dev/null | head -1 || echo "unknown")
  active_state=$(systemctl is-active "$svc" 2>/dev/null | head -1 || echo "unknown")

  if [[ "$enabled_state" != "masked" ]]; then
    alert "$svc не замаскирован (enabled=$enabled_state)"
    if [[ "$AUTO_FIX" == true ]]; then
      log "FIX: маскирую $svc"
      systemctl stop "$svc" 2>/dev/null || true
      systemctl disable "$svc" 2>/dev/null || true

      unit_file="/etc/systemd/system/$svc"
      backup_dir="/var/lib/services_management/unit_backups"
      if [[ -f "$unit_file" && ! -L "$unit_file" ]]; then
        mkdir -p "$backup_dir"
        mv "$unit_file" "$backup_dir/$svc" 2>/dev/null || true
        systemctl daemon-reload
      fi

      systemctl mask "$svc" 2>/dev/null || true
      systemctl reset-failed "$svc" 2>/dev/null || true
      log "FIX: $svc замаскирован"
    fi
  elif [[ "$active_state" == "active" || "$active_state" == "activating" ]]; then
    alert "$svc запущен несмотря на маску (active=$active_state)"
    if [[ "$AUTO_FIX" == true ]]; then
      log "FIX: останавливаю $svc"
      systemctl stop "$svc" 2>/dev/null || true
      systemctl kill --signal=SIGKILL "$svc" 2>/dev/null || true
      systemctl reset-failed "$svc" 2>/dev/null || true
      log "FIX: $svc остановлен"
    fi
  else
    ok "$svc (enabled=$enabled_state, active=$active_state)"
  fi
done

# ============================================================
# 2. Проверка: нет процессов от агентов мониторинга
# ============================================================
log "--- Проверка процессов ---"
patterns=$(echo "$PROCESS_PATTERNS" | grep -v '^\s*#' | grep -v '^\s*$' | tr '\n' '|' | sed 's/|$//')

if [[ -n "$patterns" ]]; then
  rogue_procs=$(pgrep -af "$patterns" 2>/dev/null \
    | grep -v "watchdog\.\(sh\|conf\)" \
    | grep -v "grep" \
    | grep -v "systemctl" \
    | grep -v "journalctl" \
    | grep -v "pgrep" \
    || true)
  if [[ -n "$rogue_procs" ]]; then
    alert "Обнаружены процессы агентов мониторинга:"
    while IFS= read -r line; do
      log "  PROC: $line"
      REPORT+="    $line"$'\n'
    done <<< "$rogue_procs"

    if [[ "$AUTO_FIX" == true ]]; then
      log "FIX: завершаю процессы агентов"
      while IFS= read -r line; do
        pid=$(echo "$line" | awk '{print $1}')
        kill -9 "$pid" 2>/dev/null || true
        log "FIX: SIGKILL отправлен PID $pid"
      done <<< "$rogue_procs"
    fi
  else
    ok "Процессов агентов мониторинга не обнаружено"
  fi
fi

# ============================================================
# 3. Проверка: чужие пользовательские сессии
# ============================================================
log "--- Проверка активных сессий ---"
my_user="${MY_USER:-}"
if [[ -n "$my_user" ]]; then
  # who/last обрезают длинные имена, поэтому берём префикс до первой точки
  my_user_short="${my_user%%.*}"

  other_sessions=$(who 2>/dev/null | grep -v "^${my_user_short}" || true)
  if [[ -n "$other_sessions" ]]; then
    alert "Обнаружены сессии других пользователей:"
    while IFS= read -r line; do
      log "  SESSION: $line"
      REPORT+="    $line"$'\n'
    done <<< "$other_sessions"
  else
    ok "Чужих сессий не обнаружено"
  fi

  recent_logins=$(last -s "$(date -d '24 hours ago' '+%Y-%m-%d %H:%M')" 2>/dev/null \
    | grep -v "^${my_user_short}" \
    | grep -v "^reboot " \
    | grep -v "^$" \
    | grep -v "^wtmp " \
    | head -10 || true)
  if [[ -n "$recent_logins" ]]; then
    alert "Входы других пользователей за последние 24ч:"
    while IFS= read -r line; do
      log "  LOGIN: $line"
      REPORT+="    $line"$'\n'
    done <<< "$recent_logins"
  else
    ok "Входов других пользователей за 24ч не было"
  fi
fi

# ============================================================
# 4. Проверка: нет новых подозрительных systemd-юнитов
# ============================================================
log "--- Проверка новых юнитов ---"
safe="${SAFE_UNITS:-smartmontools|services.watchdog}"
suspicious_units=$(systemctl list-unit-files --state=enabled --no-pager --no-legend 2>/dev/null \
  | grep -iE 'monitor|agent|track|survey|watch|report|telemetry|collect|audit|inspect|spy|snoop' \
  | grep -vE "$safe" \
  || true)
if [[ -n "$suspicious_units" ]]; then
  alert "Обнаружены подозрительные enabled-юниты:"
  while IFS= read -r line; do
    log "  UNIT: $line"
    REPORT+="    $line"$'\n'
  done <<< "$suspicious_units"
else
  ok "Подозрительных новых юнитов не обнаружено"
fi

# ============================================================
# 5. Проверка: открытые сетевые порты от агентов
# ============================================================
log "--- Проверка сетевых портов ---"
suspicious_ports=$(ss -tulpn 2>/dev/null \
  | grep -iE 'siagent|dcservice|kesl|klnagent|solar|dozor' \
  || true)
if [[ -n "$suspicious_ports" ]]; then
  alert "Обнаружены сетевые порты агентов мониторинга:"
  while IFS= read -r line; do
    log "  PORT: $line"
    REPORT+="    $line"$'\n'
  done <<< "$suspicious_ports"
else
  ok "Сетевых портов агентов не обнаружено"
fi

# ============================================================
# Итог
# ============================================================
echo "" | tee -a "$LOG"
if [[ $ALERTS -gt 0 ]]; then
  log "=== Watchdog: обнаружено проблем: $ALERTS ==="
  echo "" | tee -a "$LOG"
  echo "$REPORT" | tee -a "$LOG"

  notify_desktop \
    "Watchdog: $ALERTS проблем!" \
    "$REPORT" \
    critical

  exit 1
else
  log "=== Watchdog: всё чисто ==="
  exit 0
fi
