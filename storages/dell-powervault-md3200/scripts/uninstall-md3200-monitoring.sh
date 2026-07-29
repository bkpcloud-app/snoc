#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "ERRO: execute como root." >&2
  exit 1
fi

systemctl disable --now dell-md3200-cache.timer 2>/dev/null || true
systemctl stop dell-md3200-cache.service 2>/dev/null || true

rm -f /etc/systemd/system/dell-md3200-cache.timer
rm -f /etc/systemd/system/dell-md3200-cache.service
rm -rf /etc/systemd/system/dell-md3200-cache.service.d
rm -f /usr/local/sbin/dell-md3200-cache-update
rm -f /usr/lib/zabbix/externalscripts/dell_md3200.py
rm -f /usr/lib/zabbix/externalscripts/dell_md3200_cache.py
rm -rf /etc/zabbix/dell-md3200.d
rm -rf /var/lib/zabbix/md3200-cache

systemctl daemon-reload
systemctl reset-failed

echo "Coletor e cache removidos. O Dell MDSM/SMcli não foi desinstalado."
