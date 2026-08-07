#!/usr/bin/env bash
set -Eeuo pipefail

APP="/opt/netbox/netbox"
VENV="/opt/netbox/venv"
CONFIG="$APP/netbox/configuration.py"
STATIC="$APP/static/ddm_netbox_branding/ddm-branding.css"
FQDN="inventory.bkpcloud.app.br"

fail(){ echo "ERRO: $*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || fail "execute como root"
[[ -x "$VENV/bin/python" ]] || fail "venv do NetBox nao encontrado"
[[ -f "$CONFIG" ]] || fail "configuration.py nao encontrado"
[[ -s "$STATIC" ]] || fail "CSS DDMTI nao encontrado em $STATIC"
grep -q '# BEGIN DDM NETBOX BRANDING' "$CONFIG" || fail "bloco DDM nao encontrado no configuration.py"
grep -q 'ddm_netbox_branding' "$CONFIG" || fail "plugin DDM nao configurado"

for svc in netbox netbox-rq nginx; do
  systemctl is-active --quiet "$svc" || fail "servico $svc nao esta ativo"
done

cd "$APP"
VERSION="$($VENV/bin/python manage.py shell -c 'from django.conf import settings; print(settings.VERSION)' 2>/dev/null | tail -n1)"
[[ "$VERSION" == "4.6.5" ]] || fail "NetBox inesperado: $VERSION"

$VENV/bin/python manage.py check >/dev/null
$VENV/bin/python manage.py shell -c 'import ddm_netbox_branding' >/dev/null

APP_HTTP="$(curl -sS -H "Host: $FQDN" -o /tmp/ddm-netbox-login.html -w '%{http_code}' http://127.0.0.1:8001/login/)"
[[ "$APP_HTTP" =~ ^(200|301|302)$ ]] || fail "aplicacao respondeu HTTP $APP_HTTP"
grep -q 'ddm-branding.css' /tmp/ddm-netbox-login.html || fail "CSS DDMTI nao foi injetado no HTML"

STATIC_HTTPS="$(curl -sk --resolve "$FQDN:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$FQDN/static/ddm_netbox_branding/ddm-branding.css")"
[[ "$STATIC_HTTPS" == "200" ]] || fail "CSS via HTTPS respondeu $STATIC_HTTPS"

cat > /root/rollback-ddm-netbox-branding.sh <<'ROLLBACK'
#!/usr/bin/env bash
set -Eeuo pipefail
APP="/opt/netbox/netbox"
VENV="/opt/netbox/venv"
CONFIG="$APP/netbox/configuration.py"
python3 - "$CONFIG" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); t=p.read_text()
b="# BEGIN DDM NETBOX BRANDING"; e="# END DDM NETBOX BRANDING"
if b in t and e in t:
    a,r=t.split(b,1); _,z=r.split(e,1)
    p.write_text(a.rstrip()+"\n"+z.lstrip("\n"))
PY
"$VENV/bin/pip" uninstall -y ddm-netbox-branding >/dev/null 2>&1 || true
rm -rf /opt/netbox/local/ddm-netbox-branding "$APP/static/ddm_netbox_branding"
cd "$APP"
"$VENV/bin/python" manage.py check
systemctl restart netbox netbox-rq
echo "DDMTI Branding removido."
ROLLBACK
chmod 700 /root/rollback-ddm-netbox-branding.sh

echo
echo "============================================================"
echo " DDMTI NETBOX BRANDING - CONCLUIDO"
echo "============================================================"
echo "NetBox       : $VERSION"
echo "URL          : https://$FQDN"
echo "Marca        : DDMTI Solucoes"
echo "App HTTP     : $APP_HTTP"
echo "Static HTTPS : $STATIC_HTTPS"
echo "Rollback     : /root/rollback-ddm-netbox-branding.sh"
echo "============================================================"
