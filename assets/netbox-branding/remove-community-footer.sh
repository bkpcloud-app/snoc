#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

APP="/opt/netbox/netbox"
VENV="/opt/netbox/venv"
PLUGIN="/opt/netbox/local/ddm-netbox-branding/ddm_netbox_branding"
CSS="$PLUGIN/static/ddm_netbox_branding/ddm-branding.css"
TEMPLATE_CONTENT="$PLUGIN/template_content.py"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/opt/netbox/backups/ddm-netbox-branding-footer-${STAMP}"
FQDN="inventory.bkpcloud.app.br"

fail(){ echo "ERRO: $*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || fail "execute como root"
[[ -x "$VENV/bin/python" ]] || fail "venv do NetBox nao encontrado"
[[ -f "$CSS" ]] || fail "CSS do branding nao encontrado"
[[ -f "$TEMPLATE_CONTENT" ]] || fail "template_content.py do branding nao encontrado"

cd "$APP"
VERSION="$($VENV/bin/python manage.py shell -c 'from django.conf import settings; print(settings.VERSION)' 2>/dev/null | tail -n1)"
[[ "$VERSION" == "4.6.5" ]] || fail "ajuste homologado para NetBox 4.6.5; detectado: $VERSION"

for svc in netbox netbox-rq nginx; do
  systemctl is-active --quiet "$svc" || fail "servico $svc nao esta ativo"
done

mkdir -p "$BACKUP"
cp -a "$CSS" "$BACKUP/ddm-branding.css"
cp -a "$TEMPLATE_CONTENT" "$BACKUP/template_content.py"

echo "Backup: $BACKUP"

if ! grep -q 'DDM HIDE NETBOX COMMUNITY FOOTER' "$CSS"; then
cat >> "$CSS" <<'EOF'

/* DDM HIDE NETBOX COMMUNITY FOOTER
 * NetBox 4.6.5: oculta somente o bloco de release/Cloud/Enterprise
 * no rodape da barra lateral. Nao remove nem altera funcionalidade.
 */
#sidebar-menu > .text-muted.text-center.fs-5.my-3.px-3 {
    display: none !important;
}
EOF
fi

# Cache-bust do CSS/JS/favicon injetados pelo plugin.
python3 - "$TEMPLATE_CONTENT" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
t = p.read_text(encoding="utf-8")
t = re.sub(r'\?v=1\.0\.\d+', '?v=1.0.1', t)
p.write_text(t, encoding="utf-8")
PY

echo "[1/4] Validando configuracao..."
"$VENV/bin/python" manage.py check

echo "[2/4] Atualizando arquivos estaticos..."
"$VENV/bin/python" manage.py collectstatic --no-input >/dev/null

grep -q 'DDM HIDE NETBOX COMMUNITY FOOTER' "$APP/static/ddm_netbox_branding/ddm-branding.css" || fail "regra nao chegou ao static"

echo "[3/4] Reiniciando NetBox para cache-bust do head..."
systemctl restart netbox netbox-rq
sleep 4
systemctl is-active --quiet netbox || fail "netbox nao voltou"
systemctl is-active --quiet netbox-rq || fail "netbox-rq nao voltou"

echo "[4/4] Validando..."
HTTP="$(curl -sS -H "Host: $FQDN" -o /tmp/ddm-netbox-home.html -w '%{http_code}' http://127.0.0.1:8001/)"
[[ "$HTTP" =~ ^(200|301|302)$ ]] || fail "NetBox respondeu HTTP $HTTP"
grep -q 'ddm-branding.css?v=1.0.1' /tmp/ddm-netbox-home.html || fail "cache-bust 1.0.1 nao apareceu no HTML"
HTTPS="$(curl -ksS --resolve "$FQDN:443:127.0.0.1" -o /tmp/ddm-branding.css -w '%{http_code}' "https://$FQDN/static/ddm_netbox_branding/ddm-branding.css?v=1.0.1")"
[[ "$HTTPS" == "200" ]] || fail "CSS HTTPS respondeu $HTTPS"
grep -q 'DDM HIDE NETBOX COMMUNITY FOOTER' /tmp/ddm-branding.css || fail "CSS HTTPS ainda nao contem a regra"

echo
echo "============================================================"
echo " DDMTI - RODAPE NETBOX COMMUNITY OCULTADO"
echo "============================================================"
echo "NetBox      : $VERSION"
echo "App HTTP    : $HTTP"
echo "Static HTTPS: $HTTPS"
echo "Backup      : $BACKUP"
echo "Alteracao   : somente apresentacao via plugin DDMTI"
echo "============================================================"
