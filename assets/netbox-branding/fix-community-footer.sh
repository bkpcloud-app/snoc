#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

APP="/opt/netbox/netbox"
VENV="/opt/netbox/venv"
PLUGIN="/opt/netbox/local/ddm-netbox-branding/ddm_netbox_branding"
TC="$PLUGIN/template_content.py"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/opt/netbox/backups/ddm-netbox-footer-fix-${STAMP}"
FQDN="inventory.bkpcloud.app.br"

fail(){ echo "ERRO: $*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || fail "execute como root"
[[ -x "$VENV/bin/python" ]] || fail "venv do NetBox nao encontrado"
[[ -f "$TC" ]] || fail "template_content.py do branding nao encontrado"

cd "$APP"
VERSION="$($VENV/bin/python manage.py shell -c 'from django.conf import settings; print(settings.VERSION)' 2>/dev/null | tail -n1)"
[[ "$VERSION" == "4.6.5" ]] || fail "ajuste homologado para NetBox 4.6.5; detectado: $VERSION"

for svc in netbox netbox-rq nginx; do
  systemctl is-active --quiet "$svc" || fail "servico $svc nao esta ativo"
done

mkdir -p "$BACKUP"
cp -a "$TC" "$BACKUP/template_content.py"
echo "Backup: $BACKUP"

cat > "$TC" <<'PY'
from django.templatetags.static import static
from django.utils.html import format_html
from netbox.plugins.templates import PluginTemplateExtension


class DDMGlobalBranding(PluginTemplateExtension):
    def head(self):
        css = static("ddm_netbox_branding/ddm-branding.css")
        js = static("ddm_netbox_branding/ddm-branding.js")
        favicon = static("ddm_netbox_branding/ddm-favicon.svg")
        return format_html(
            '<link rel="stylesheet" href="{}?v=1.0.2">'
            '<link rel="icon" type="image/svg+xml" href="{}?v=1.0.2">'
            '<script defer src="{}?v=1.0.2"></script>'
            '<style id="ddm-hide-netbox-community">'
            '#sidebar-menu > .text-muted.text-center.fs-5.my-3.px-3{{display:none!important}}'
            '</style>',
            css, favicon, js
        )


template_extensions = [DDMGlobalBranding]
PY

echo "[1/3] Validando configuracao..."
$VENV/bin/python manage.py check

echo "[2/3] Reiniciando NetBox..."
systemctl restart netbox
sleep 4
systemctl is-active --quiet netbox || fail "netbox nao voltou"
systemctl is-active --quiet netbox-rq || fail "netbox-rq ficou inativo"

echo "[3/3] Validando HTML gerado..."
HTTP="$(curl -sS -H "Host: $FQDN" -o /tmp/ddm-netbox-footer-check.html -w '%{http_code}' http://127.0.0.1:8001/login/)"
[[ "$HTTP" =~ ^(200|301|302)$ ]] || fail "NetBox respondeu HTTP $HTTP"
grep -q 'id="ddm-hide-netbox-community"' /tmp/ddm-netbox-footer-check.html || fail "regra de ocultacao nao apareceu no HTML"
grep -q 'ddm-branding.css?v=1.0.2' /tmp/ddm-netbox-footer-check.html || fail "branding 1.0.2 nao apareceu no HTML"

HTTPS="$(curl -ksS --resolve "$FQDN:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$FQDN/login/")"
[[ "$HTTPS" =~ ^(200|301|302)$ ]] || fail "HTTPS respondeu $HTTPS"

echo
echo "============================================================"
echo " DDMTI - RODAPE NETBOX COMMUNITY REMOVIDO DA INTERFACE"
echo "============================================================"
echo "NetBox : $VERSION"
echo "App    : HTTP $HTTP"
echo "HTTPS  : $HTTPS"
echo "Backup : $BACKUP"
echo "Metodo : CSS inline via plugin DDMTI; core intacto"
echo "============================================================"
