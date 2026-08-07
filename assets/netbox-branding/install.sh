#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

NETBOX="/opt/netbox"
APP="${NETBOX}/netbox"
VENV="${NETBOX}/venv"
CONFIG="${APP}/netbox/configuration.py"
PLUGIN_ROOT="${NETBOX}/local/ddm-netbox-branding"
PKG="${PLUGIN_ROOT}/ddm_netbox_branding"
STATIC="${PKG}/static/ddm_netbox_branding"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${NETBOX}/backups/ddm-netbox-branding-${STAMP}"
CONFIG_BAK="${BACKUP}/configuration.py"

fail() {
  echo "ERRO: $*" >&2
  exit 1
}

rollback() {
  rc=$?
  trap - ERR
  set +e
  echo
  echo "ERRO DURANTE A INSTALACAO - EXECUTANDO ROLLBACK"
  [[ -f "$CONFIG_BAK" ]] && cp -a "$CONFIG_BAK" "$CONFIG"
  "$VENV/bin/pip" uninstall -y ddm-netbox-branding >/dev/null 2>&1 || true
  rm -rf "$PLUGIN_ROOT" "$APP/static/ddm_netbox_branding"
  systemctl restart netbox >/dev/null 2>&1 || true
  systemctl restart netbox-rq >/dev/null 2>&1 || true
  echo "Rollback concluido. Backup: $BACKUP"
  exit "$rc"
}
trap rollback ERR

[[ "$(id -u)" -eq 0 ]] || fail "execute como root"
[[ -x "$VENV/bin/python" ]] || fail "venv do NetBox nao encontrado em $VENV"
[[ -f "$CONFIG" ]] || fail "configuration.py nao encontrado"
[[ -d "$APP" ]] || fail "diretorio do NetBox nao encontrado"

for svc in netbox netbox-rq nginx; do
  systemctl is-active --quiet "$svc" || fail "servico $svc nao esta ativo"
done

cd "$APP"
VERSION="$($VENV/bin/python manage.py shell -c 'from django.conf import settings; print(settings.VERSION)' 2>/dev/null | tail -n1)"
[[ "$VERSION" == "4.6.5" ]] || fail "instalador homologado para NetBox 4.6.5; detectado: $VERSION"

echo "NetBox detectado: $VERSION"

if grep -Eq '^[[:space:]]*PLUGINS[[:space:]]*=' "$CONFIG"; then
  fail "PLUGINS ja existe no configuration.py. Nada foi alterado."
fi

mkdir -p "$BACKUP"
cp -a "$CONFIG" "$CONFIG_BAK"
[[ -d "$PLUGIN_ROOT" ]] && cp -a "$PLUGIN_ROOT" "$BACKUP/plugin-anterior" || true

"$VENV/bin/pip" uninstall -y ddm-netbox-branding >/dev/null 2>&1 || true
rm -rf "$PLUGIN_ROOT"
mkdir -p "$STATIC"

cat > "$PLUGIN_ROOT/pyproject.toml" <<'EOF'
[build-system]
requires = ["setuptools>=68", "wheel"]
build-backend = "setuptools.build_meta"

[project]
name = "ddm-netbox-branding"
version = "1.0.0"
description = "Identidade visual DDMTI para NetBox"
requires-python = ">=3.12"

[tool.setuptools]
include-package-data = true

[tool.setuptools.packages.find]
where = ["."]
include = ["ddm_netbox_branding*"]

[tool.setuptools.package-data]
ddm_netbox_branding = ["static/ddm_netbox_branding/*"]
EOF

cat > "$PKG/__init__.py" <<'EOF'
from netbox.plugins import PluginConfig


class DDMNetBoxBrandingConfig(PluginConfig):
    name = "ddm_netbox_branding"
    verbose_name = "DDMTI Branding"
    description = "Identidade visual DDMTI para NetBox"
    version = "1.0.0"
    author = "DDMTI Soluções"
    min_version = "4.6.0"
    max_version = "4.6.99"


config = DDMNetBoxBrandingConfig
EOF

cat > "$PKG/template_content.py" <<'EOF'
from django.templatetags.static import static
from django.utils.html import format_html
from netbox.plugins.templates import PluginTemplateExtension


class DDMGlobalBranding(PluginTemplateExtension):
    def head(self):
        css = static("ddm_netbox_branding/ddm-branding.css")
        js = static("ddm_netbox_branding/ddm-branding.js")
        favicon = static("ddm_netbox_branding/ddm-favicon.svg")
        return format_html(
            '<link rel="stylesheet" href="{}?v=1.0.0">'
            '<link rel="icon" type="image/svg+xml" href="{}?v=1.0.0">'
            '<script defer src="{}?v=1.0.0"></script>',
            css, favicon, js
        )


template_extensions = [DDMGlobalBranding]
EOF

cat > "$STATIC/ddm-brand.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 470 110">
  <defs>
    <linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="#ffc928"/>
      <stop offset="100%" stop-color="#f58220"/>
    </linearGradient>
  </defs>
  <circle cx="55" cy="55" r="48" fill="url(#g)"/>
  <g fill="none" stroke="#fff" stroke-width="4" stroke-linecap="round" stroke-linejoin="round">
    <path d="M13 29h20l10-10h13"/><circle cx="62" cy="19" r="4" fill="#fff"/>
    <path d="M12 43h33"/><circle cx="52" cy="43" r="4" fill="#fff"/>
    <path d="M12 56h24l12 12h15"/><circle cx="69" cy="68" r="4" fill="#fff"/>
    <path d="M13 70h18l12 12h13"/><circle cx="62" cy="82" r="4" fill="#fff"/>
    <path d="M13 83h10"/><circle cx="29" cy="83" r="4" fill="#fff"/>
  </g>
  <text x="120" y="65" font-family="Arial,Helvetica,sans-serif" font-size="50" font-weight="700" letter-spacing="-1" fill="#f58220">ddm.ti</text>
  <text x="123" y="90" font-family="Arial,Helvetica,sans-serif" font-size="15" font-weight="600" letter-spacing="5" fill="#858a91">SOLUÇÕES</text>
</svg>
EOF

cat > "$STATIC/ddm-favicon.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0%" stop-color="#ffc928"/><stop offset="100%" stop-color="#f58220"/></linearGradient></defs>
  <circle cx="32" cy="32" r="30" fill="url(#g)"/>
  <text x="32" y="39" text-anchor="middle" font-family="Arial,sans-serif" font-size="20" font-weight="700" fill="#fff">DDM</text>
</svg>
EOF

cat > "$STATIC/ddm-branding.css" <<'EOF'
:root {
  --ddm-orange:#f58220;
  --ddm-orange-dark:#df6d0f;
  --ddm-yellow:#ffc928;
  --ddm-graphite:#30343a;
  --ddm-muted:#6b7077;
}

.btn-primary {background-color:var(--ddm-orange)!important;border-color:var(--ddm-orange)!important}
.btn-primary:hover,.btn-primary:focus,.btn-primary:active {background-color:var(--ddm-orange-dark)!important;border-color:var(--ddm-orange-dark)!important}
.text-primary {color:var(--ddm-orange)!important}
a:not(.btn):not(.nav-link):not(.dropdown-item) {color:var(--ddm-orange)}
a:not(.btn):not(.nav-link):not(.dropdown-item):hover {color:var(--ddm-orange-dark)}
.navbar-vertical {border-right:3px solid var(--ddm-orange)!important}
.navbar-vertical .nav-link.active,.navbar-vertical .nav-item.active>.nav-link,.navbar-vertical .nav-link:hover {color:var(--ddm-orange)!important}
header.navbar {border-bottom:2px solid rgba(245,130,32,.38)!important}
.form-control:focus {border-color:var(--ddm-orange)!important;box-shadow:0 0 0 .2rem rgba(245,130,32,.12)!important}
.form-check-input:checked,.page-item.active .page-link {background-color:var(--ddm-orange)!important;border-color:var(--ddm-orange)!important}
.navbar-brand-image.ddm-brand-image {width:210px!important;height:auto!important;max-width:100%!important;max-height:58px!important}
.page-center img.logo.ddm-brand-image {width:min(360px,82vw)!important;height:auto!important;max-height:none!important}
.page-center {background:radial-gradient(circle at top right,rgba(255,201,40,.11),transparent 34%),radial-gradient(circle at bottom left,rgba(245,130,32,.09),transparent 38%)}
.page-center .card {border:0!important;border-top:4px solid var(--ddm-orange)!important;border-radius:12px!important;box-shadow:0 14px 40px rgba(48,52,58,.12)!important}
.page-center .netbox-edition {color:var(--ddm-muted)!important;margin-top:7px}
.card {border-radius:9px}
.card-header {border-bottom-color:rgba(245,130,32,.14)}
.table-hover tbody tr:hover {--tblr-table-hover-bg:rgba(245,130,32,.045)}
[data-bs-theme="dark"] .page-center {background:radial-gradient(circle at top right,rgba(255,201,40,.07),transparent 32%),radial-gradient(circle at bottom left,rgba(245,130,32,.08),transparent 36%)}
[data-bs-theme="dark"] .page-center .card {box-shadow:0 14px 40px rgba(0,0,0,.26)!important}
@media(max-width:991.98px){.navbar-brand-image.ddm-brand-image{width:170px!important;max-height:48px!important}}
EOF

cat > "$STATIC/ddm-branding.js" <<'EOF'
(() => {
  "use strict";
  const logo = "/static/ddm_netbox_branding/ddm-brand.svg?v=1.0.0";
  const apply = () => {
    document.querySelectorAll('img[src*="logo_netbox_dark_teal"],img[src*="logo_netbox_bright_teal"]').forEach(img => {
      img.src = logo;
      img.alt = "DDMTI Soluções";
      img.removeAttribute("height");
      img.classList.add("ddm-brand-image");
    });
    document.querySelectorAll(".netbox-edition").forEach(el => el.textContent = "Inventário de Infraestrutura");
    document.title = document.title.replace(/\s*\|\s*NetBox\s*$/i, " | DDMTI");
  };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", apply); else apply();
  document.addEventListener("htmx:afterSwap", apply);
})();
EOF

echo "[1/5] Instalando plugin..."
"$VENV/bin/pip" install -e "$PLUGIN_ROOT" >/dev/null

cat >> "$CONFIG" <<'EOF'

# BEGIN DDM NETBOX BRANDING
PLUGINS = [
    "ddm_netbox_branding",
]
# END DDM NETBOX BRANDING
EOF

echo "[2/5] Validando configuracao..."
cd "$APP"
"$VENV/bin/python" manage.py check
"$VENV/bin/python" manage.py shell -c 'import ddm_netbox_branding; print("PLUGIN_DDMTI=OK")' | tail -n1

echo "[3/5] Coletando arquivos estaticos..."
"$VENV/bin/python" manage.py collectstatic --no-input >/dev/null
[[ -s "$APP/static/ddm_netbox_branding/ddm-branding.css" ]] || fail "CSS nao foi publicado"
[[ -s "$APP/static/ddm_netbox_branding/ddm-brand.svg" ]] || fail "logo nao foi publicada"

echo "[4/5] Reiniciando servicos..."
systemctl restart netbox
systemctl restart netbox-rq
sleep 4
systemctl is-active --quiet netbox || fail "netbox nao voltou"
systemctl is-active --quiet netbox-rq || fail "netbox-rq nao voltou"

echo "[5/5] Validando resposta..."
HTTP="$(curl -sS -H 'Host: inventory.bkpcloud.app.br' -o /tmp/ddm-netbox-login.html -w '%{http_code}' http://127.0.0.1:8001/login/)"
[[ "$HTTP" =~ ^(200|301|302)$ ]] || fail "NetBox respondeu HTTP $HTTP"
grep -q 'ddm-branding.css' /tmp/ddm-netbox-login.html || fail "CSS DDMTI nao apareceu no HTML"
STATIC_HTTP="$(curl -sS -H 'Host: inventory.bkpcloud.app.br' -o /dev/null -w '%{http_code}' http://127.0.0.1/static/ddm_netbox_branding/ddm-branding.css)"
[[ "$STATIC_HTTP" == "200" ]] || fail "Nginx nao entregou CSS; HTTP $STATIC_HTTP"

cat > /root/rollback-ddm-netbox-branding.sh <<'EOF'
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
    a,r=t.split(b,1); _,z=r.split(e,1); p.write_text(a.rstrip()+"\n"+z.lstrip("\n"))
PY
"$VENV/bin/pip" uninstall -y ddm-netbox-branding >/dev/null 2>&1 || true
rm -rf /opt/netbox/local/ddm-netbox-branding "$APP/static/ddm_netbox_branding"
cd "$APP"
"$VENV/bin/python" manage.py check
systemctl restart netbox netbox-rq
echo "DDMTI Branding removido."
EOF
chmod 700 /root/rollback-ddm-netbox-branding.sh

trap - ERR

echo
echo "============================================================"
echo " DDMTI NETBOX BRANDING - CONCLUIDO"
echo "============================================================"
echo "NetBox      : $VERSION"
echo "URL         : https://inventory.bkpcloud.app.br"
echo "Marca       : DDMTI Solucoes"
echo "Produto     : Inventario de Infraestrutura"
echo "App HTTP    : $HTTP"
echo "Static HTTP : $STATIC_HTTP"
echo "Backup      : $BACKUP"
echo "Rollback    : /root/rollback-ddm-netbox-branding.sh"
echo "============================================================"
