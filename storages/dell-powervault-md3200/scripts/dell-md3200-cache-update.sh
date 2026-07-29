#!/usr/bin/env bash
set -euo pipefail

CONF_DIR="/etc/zabbix/dell-md3200.d"
CACHE_ROOT="/var/lib/zabbix/md3200-cache"
COLLECTOR="/usr/lib/zabbix/externalscripts/dell_md3200.py"
LOCK_FILE="/var/lib/zabbix/md3200-cache/.collector.lock"
LOG_TAG="dell-md3200-cache"

mkdir -p "$CACHE_ROOT"
exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

now_epoch() { date +%s; }
safe_component() { printf '%s' "$1" | sed 's/[^A-Za-z0-9_.-]/_/g'; }

collect_if_due() {
    local mode="$1" interval="$2" timeout="$3" out_dir="$4"
    local out tmp age now rc
    out="$out_dir/$mode.json"
    tmp="$out.tmp.$$"
    age=999999
    now="$(now_epoch)"

    if [[ -s "$out" ]]; then
        age=$(( now - $(stat -c %Y "$out") ))
    fi
    (( age >= interval )) || return 0

    logger -t "$LOG_TAG" "Starting $mode collection for $IP_A/$IP_B (cache age ${age}s)"
    set +e
    "$COLLECTOR" "$mode" "$IP_A" "$IP_B" "$SMCLI" "$timeout" >"$tmp" 2>"$tmp.stderr"
    rc=$?
    set -e

    if (( rc != 0 )); then
        logger -t "$LOG_TAG" "Collector process failed mode=$mode rc=$rc: $(tr '\n' ' ' <"$tmp.stderr" 2>/dev/null)"
        rm -f "$tmp" "$tmp.stderr"
        return 0
    fi

    if ! python3 - "$tmp" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as handle:
    data = json.load(handle)
if not isinstance(data, dict) or data.get('mode') not in ('health', 'inventory', 'performance'):
    raise SystemExit(1)
PY
    then
        logger -t "$LOG_TAG" "Invalid JSON generated for mode=$mode"
        rm -f "$tmp" "$tmp.stderr"
        return 0
    fi

    chmod 0640 "$tmp"
    mv -f "$tmp" "$out"
    rm -f "$tmp.stderr"
    logger -t "$LOG_TAG" "Completed $mode collection for $IP_A/$IP_B"
}

shopt -s nullglob
configs=("$CONF_DIR"/*.conf)
for conf in "${configs[@]}"; do
    unset IP_A IP_B SMCLI HEALTH_INTERVAL PERFORMANCE_INTERVAL INVENTORY_INTERVAL HEALTH_TIMEOUT PERFORMANCE_TIMEOUT INVENTORY_TIMEOUT
    # shellcheck disable=SC1090
    source "$conf"
    : "${IP_A:?IP_A missing in $conf}"
    : "${IP_B:?IP_B missing in $conf}"
    : "${SMCLI:=/usr/bin/SMcli}"
    : "${HEALTH_INTERVAL:=120}"
    : "${PERFORMANCE_INTERVAL:=300}"
    : "${INVENTORY_INTERVAL:=1800}"
    : "${HEALTH_TIMEOUT:=120}"
    : "${PERFORMANCE_TIMEOUT:=120}"
    : "${INVENTORY_TIMEOUT:=180}"

    key="$(safe_component "$IP_A")__$(safe_component "$IP_B")"
    out_dir="$CACHE_ROOT/$key"
    mkdir -p "$out_dir"
    chmod 0750 "$out_dir"

    # Deliberadamente serial: o SMcli não se comporta bem com sessões concorrentes.
    collect_if_due health "$HEALTH_INTERVAL" "$HEALTH_TIMEOUT" "$out_dir"
    collect_if_due performance "$PERFORMANCE_INTERVAL" "$PERFORMANCE_TIMEOUT" "$out_dir"
    collect_if_due inventory "$INVENTORY_INTERVAL" "$INVENTORY_TIMEOUT" "$out_dir"
done
