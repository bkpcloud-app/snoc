#!/usr/bin/env bash
set -Eeuo pipefail
umask 022
APP="${BC_NETBOX_APP:-/opt/netbox/netbox}"
VENV="${BC_NETBOX_VENV:-/opt/netbox/venv}"
PKG="${BC_NETBOX_PKG:-/opt/netbox/local/ddm-netbox-branding/ddm_netbox_branding}"
SRC="$PKG/static/ddm_netbox_branding/backupcloud-branding.css"
TC="$PKG/template_content.py"
BACKUP_BASE="${BC_BACKUP_BASE:-/opt/netbox/backups}"
TEST_MODE="${BC_TEST_MODE:-0}"
BACKUP="${1:-}"
if [[ -z "$BACKUP" ]]; then
  BACKUP="$(ls -1dt "$BACKUP_BASE"/backupcloud-netbox-product-hierarchy-v4-* 2>/dev/null | head -n1 || true)"
fi
[[ -n "$BACKUP" && -d "$BACKUP" ]] || { echo "ERRO: backup nao encontrado" >&2; exit 1; }
[[ -f "$BACKUP/backupcloud-branding.css" ]] || { echo "ERRO: CSS ausente no backup" >&2; exit 1; }
[[ -f "$BACKUP/template_content.py" ]] || { echo "ERRO: template_content.py ausente no backup" >&2; exit 1; }
cp -a "$BACKUP/backupcloud-branding.css" "$SRC"
cp -a "$BACKUP/template_content.py" "$TC"
if [[ "$TEST_MODE" != "1" ]]; then
  cd "$APP"
  "$VENV/bin/python" manage.py check
  "$VENV/bin/python" manage.py collectstatic --no-input >/dev/null
  systemctl restart netbox netbox-rq
  systemctl is-active --quiet netbox
  systemctl is-active --quiet netbox-rq
fi
echo "ROLLBACK OK: $BACKUP"
