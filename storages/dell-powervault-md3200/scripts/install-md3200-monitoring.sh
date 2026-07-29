#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "ERRO: execute como root." >&2
  exit 1
fi
if [[ $# -lt 2 ]]; then
  echo "Uso: $0 <IP_A> <IP_B>" >&2
  exit 1
fi

IP_A="$1"
IP_B="$2"
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXT="/usr/lib/zabbix/externalscripts"
CONF_DIR="/etc/zabbix/dell-md3200.d"
CACHE_ROOT="/var/lib/zabbix/md3200-cache"
SMCLI="/usr/bin/SMcli"

id zabbix >/dev/null 2>&1 || { echo "ERRO: usuário zabbix não existe" >&2; exit 1; }
[[ -x "$SMCLI" ]] || { echo "ERRO: SMcli não encontrado em $SMCLI" >&2; exit 1; }

for file in \
  "$BASE/collectors/dell_md3200.py" \
  "$BASE/collectors/dell_md3200_cache.py" \
  "$BASE/scripts/dell-md3200-cache-update.sh" \
  "$BASE/systemd/dell-md3200-cache.service" \
  "$BASE/systemd/dell-md3200-cache.timer"; do
  [[ -f "$file" ]] || { echo "ERRO: arquivo ausente: $file" >&2; exit 1; }
done

install -d -o root -g zabbix -m 0750 "$EXT"
install -d -o root -g zabbix -m 0750 "$CONF_DIR"
install -d -o zabbix -g zabbix -m 0750 "$CACHE_ROOT"
install -d -o zabbix -g zabbix -m 0750 /var/lib/zabbix

install -o root -g zabbix -m 0750 "$BASE/collectors/dell_md3200.py" "$EXT/dell_md3200.py"
install -o root -g zabbix -m 0750 "$BASE/collectors/dell_md3200_cache.py" "$EXT/dell_md3200_cache.py"
install -o root -g root -m 0755 "$BASE/scripts/dell-md3200-cache-update.sh" /usr/local/sbin/dell-md3200-cache-update
install -o root -g root -m 0644 "$BASE/systemd/dell-md3200-cache.service" /etc/systemd/system/dell-md3200-cache.service
install -o root -g root -m 0644 "$BASE/systemd/dell-md3200-cache.timer" /etc/systemd/system/dell-md3200-cache.timer

key="$(printf '%s__%s' "$IP_A" "$IP_B" | sed 's/[^A-Za-z0-9_.-]/_/g')"
conf="$CONF_DIR/$key.conf"
cat > "$conf" <<CONF
IP_A='$IP_A'
IP_B='$IP_B'
SMCLI='$SMCLI'
HEALTH_INTERVAL=120
PERFORMANCE_INTERVAL=300
INVENTORY_INTERVAL=1800
HEALTH_TIMEOUT=120
PERFORMANCE_TIMEOUT=120
INVENTORY_TIMEOUT=180
CONF
chown root:zabbix "$conf"
chmod 0640 "$conf"
install -d -o zabbix -g zabbix -m 0750 "$CACHE_ROOT/$key"

mkdir -p /etc/systemd/system/dell-md3200-cache.service.d
cat > /etc/systemd/system/dell-md3200-cache.service.d/override.conf <<'OVERRIDE'
[Service]
Environment=HOME=/var/lib/zabbix
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
OVERRIDE

systemctl daemon-reload
systemctl enable --now dell-md3200-cache.timer
systemctl start dell-md3200-cache.service

runuser -u zabbix -- "$EXT/dell_md3200_cache.py" health "$IP_A" "$IP_B" 300 | python3 -c '
import json,sys
d=json.load(sys.stdin)
print("available=%s" % d.get("available"))
print("return_code=%s" % d.get("return_code"))
print("storage_health=%s" % d.get("storage",{}).get("health"))
print("cache_age=%s" % d.get("cache_age"))
print("cache_stale=%s" % d.get("cache_stale"))
print("errors=%s" % d.get("errors",""))
if d.get("available") != 1 or d.get("cache_stale") != 0:
    raise SystemExit(1)
'

echo "Instalação concluída."
