#!/usr/bin/env bash
set -Eeuo pipefail

BASE="/home/suporte"
TOMCAT_BASE="/var/lib/tomcat9"
CTX="${TOMCAT_BASE}/conf/Catalina/localhost/ROOT.xml"
WEBROOT="${TOMCAT_BASE}/webapps/ROOT"
MAINCSS="${WEBROOT}/css/main.css"
FAVICON="${WEBROOT}/images/favicon.ico"
WEB_ASSET_DIR="${WEBROOT}/images/backup-cloud"

fail(){ echo "ERRO: $*" >&2; exit 1; }
[[ "$(id -u)" -eq 0 ]] || fail "execute como root"

BACKUP="${1:-}"
if [[ -z "$BACKUP" ]]; then
    BACKUP="$(find "$BASE" -maxdepth 1 -type d -name 'BACKUP-CLOUD-GESTAO-MOVEL-BRANDING-BACKUP-*' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2-)"
fi

[[ -n "$BACKUP" && -d "$BACKUP" ]] || fail "backup não encontrado"
[[ -s "$BACKUP/ROOT.xml" ]] || fail "ROOT.xml ausente no backup"
[[ -s "$BACKUP/main.css" ]] || fail "main.css ausente no backup"

cp -a "$BACKUP/ROOT.xml" "$CTX"
cp -a "$BACKUP/main.css" "$MAINCSS"
[[ -f "$BACKUP/favicon.ico" ]] && cp -a "$BACKUP/favicon.ico" "$FAVICON" || true
rm -rf "$WEB_ASSET_DIR"
[[ -d "$BACKUP/backup-cloud-assets" ]] && cp -a "$BACKUP/backup-cloud-assets" "$WEB_ASSET_DIR" || true

chown root:tomcat "$MAINCSS"
chmod 0644 "$MAINCSS"

systemctl restart tomcat9
for _ in $(seq 1 180); do
    ss -H -lnt 'sport = :8080' 2>/dev/null | grep -q . && break
    sleep 1
done
ss -H -lnt 'sport = :8080' 2>/dev/null | grep -q . || fail "Tomcat não voltou na porta 8080"

echo "Rollback concluído usando: $BACKUP"
