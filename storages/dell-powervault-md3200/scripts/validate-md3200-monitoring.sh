#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Uso: $0 <IP_A> <IP_B>" >&2
  exit 1
fi
IP_A="$1"
IP_B="$2"

for path in \
  /usr/bin/SMcli \
  /usr/lib/zabbix/externalscripts/dell_md3200.py \
  /usr/lib/zabbix/externalscripts/dell_md3200_cache.py \
  /usr/local/sbin/dell-md3200-cache-update; do
  [[ -e "$path" ]] || { echo "ERRO: ausente: $path" >&2; exit 1; }
done

systemctl is-enabled dell-md3200-cache.timer
systemctl is-active dell-md3200-cache.timer
systemctl start dell-md3200-cache.service

runuser -u zabbix -- \
  /usr/lib/zabbix/externalscripts/dell_md3200_cache.py \
  health "$IP_A" "$IP_B" 300 | python3 -c '
import json,sys
d=json.load(sys.stdin)
for key, value in (
    ("available", d.get("available")),
    ("return_code", d.get("return_code")),
    ("storage_health", d.get("storage",{}).get("health")),
    ("cache_age", d.get("cache_age")),
    ("cache_stale", d.get("cache_stale")),
    ("errors", d.get("errors","")),
):
    print("%s = %s" % (key, value))
if d.get("available") != 1 or d.get("return_code") != 0 or d.get("cache_stale") != 0:
    raise SystemExit(1)
'

find /var/lib/zabbix/md3200-cache -maxdepth 3 -type f -printf '%M %u:%g %s bytes %p\n'
