#!/usr/bin/env bash
set -Eeuo pipefail
umask 022
TOMCAT="${BC_TOMCAT:-/var/lib/tomcat9}"
BACKUP_BASE="${BC_BACKUP_BASE:-/home/suporte}"
TEST_MODE="${BC_TEST_MODE:-0}"
BACKUP="${1:-}"
if [[ -z "$BACKUP" ]]; then
  BACKUP="$(ls -1dt "$BACKUP_BASE"/BACKUP-CLOUD-GESTAO-MOVEL-HIERARCHY-* 2>/dev/null | head -n1 || true)"
fi
[[ -n "$BACKUP" && -d "$BACKUP" ]] || { echo "ERRO: backup nao encontrado" >&2; exit 1; }
for rel in webapps/ROOT/css/main.css webapps/ROOT/app/components/main/view/login.html webapps/ROOT/index.html webapps/ROOT/app/app.js; do
  [[ -f "$BACKUP/$rel" ]] || { echo "ERRO: ausente no backup: $rel" >&2; exit 1; }
done
for rel in webapps/ROOT/css/main.css webapps/ROOT/app/components/main/view/login.html webapps/ROOT/index.html webapps/ROOT/app/app.js; do
  cp -a "$BACKUP/$rel" "$TOMCAT/$rel"
done
if [[ "$TEST_MODE" != "1" ]]; then
  systemctl restart tomcat9
  systemctl is-active --quiet tomcat9
fi
echo "ROLLBACK OK: $BACKUP"
