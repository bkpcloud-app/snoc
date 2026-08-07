#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

APP="/opt/netbox/netbox"
VENV="/opt/netbox/venv"
PLUGIN_ROOT="/opt/netbox/local/ddm-netbox-branding"
PKG="${PLUGIN_ROOT}/ddm_netbox_branding"
STATIC="${PKG}/static/ddm_netbox_branding"
INIT="${PKG}/__init__.py"
TC="${PKG}/template_content.py"
FQDN="inventory.bkpcloud.app.br"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/opt/netbox/backups/backup-cloud-netbox-branding-${STAMP}"
TMPDIR="$(mktemp -d /tmp/backup-cloud-netbox.XXXXXX)"
RAW="https://raw.githubusercontent.com/bkpcloud-app/snoc/main/assets/backup-cloud/gestao-movel/branding/web"

fail(){ echo "ERRO: $*" >&2; exit 1; }
cleanup(){ rm -rf "$TMPDIR"; }
trap cleanup EXIT

[[ "$(id -u)" -eq 0 ]] || fail "execute como root"
[[ -x "$VENV/bin/python" ]] || fail "venv do NetBox nao encontrado"
[[ -d "$PKG" ]] || fail "plugin de branding atual nao encontrado"
[[ -f "$INIT" ]] || fail "__init__.py do plugin nao encontrado"
[[ -f "$TC" ]] || fail "template_content.py do plugin nao encontrado"
command -v curl >/dev/null 2>&1 || fail "curl ausente"
command -v base64 >/dev/null 2>&1 || fail "base64 ausente"

cd "$APP"
VERSION="$($VENV/bin/python manage.py shell -c 'from django.conf import settings; print(settings.VERSION)' 2>/dev/null | tail -n1)"
[[ "$VERSION" == "4.6.5" ]] || fail "ajuste homologado para NetBox 4.6.5; detectado: $VERSION"

for svc in netbox netbox-rq nginx; do
  systemctl is-active --quiet "$svc" || fail "servico $svc nao esta ativo"
done

mkdir -p "$BACKUP"
cp -a "$PKG" "$BACKUP/plugin-anterior"
echo "Backup: $BACKUP"

decode_asset(){
  local src="$1" dst="$2" tmp="$3"
  curl -fsSL "$src" -o "$tmp"
  base64 -d "$tmp" > "$dst"
  [[ -s "$dst" ]] || fail "asset vazio: $src"
}

decode_asset "$RAW/backup-cloud-logo-dark-transparent.png.b64" "$TMPDIR/backup-cloud-logo.png" "$TMPDIR/logo.b64"
decode_asset "$RAW/backup-cloud-icon.png.b64" "$TMPDIR/backup-cloud-icon.png" "$TMPDIR/icon.b64"
decode_asset "$RAW/backup-cloud-favicon.ico.b64" "$TMPDIR/backup-cloud-favicon.ico" "$TMPDIR/favicon.b64"

python3 - "$TMPDIR/backup-cloud-logo.png" "$TMPDIR/backup-cloud-icon.png" "$TMPDIR/backup-cloud-favicon.ico" <<'PY'
from pathlib import Path
import sys
logo, icon, fav = map(Path, sys.argv[1:])
for p, minimum, label in [(logo, 5000, 'logo'), (icon, 2000, 'icone')]:
    data = p.read_bytes()
    if not data.startswith(b'\x89PNG\r\n\x1a\n') or len(data) < minimum:
        raise SystemExit(f'{label} PNG invalido: {p}')
data = fav.read_bytes()
if len(data) < 1000 or data[:4] != b'\x00\x00\x01\x00':
    raise SystemExit(f'favicon ICO invalido: {fav}')
print('Assets Backup Cloud: OK')
PY

install -m 0644 "$TMPDIR/backup-cloud-logo.png" "$STATIC/backup-cloud-logo.png"
install -m 0644 "$TMPDIR/backup-cloud-icon.png" "$STATIC/backup-cloud-icon.png"
install -m 0644 "$TMPDIR/backup-cloud-favicon.ico" "$STATIC/backup-cloud-favicon.ico"

cat > "$INIT" <<'PY'
from netbox.plugins import PluginConfig


class BackupCloudNetBoxBrandingConfig(PluginConfig):
    name = "ddm_netbox_branding"
    verbose_name = "Backup Cloud Branding"
    description = "Identidade visual Backup Cloud para NetBox"
    version = "2.0.0"
    author = "Backup Cloud"
    min_version = "4.6.0"
    max_version = "4.6.99"


config = BackupCloudNetBoxBrandingConfig
PY

cat > "$TC" <<'PY'
from django.templatetags.static import static
from django.utils.html import format_html
from netbox.plugins.templates import PluginTemplateExtension


class BackupCloudGlobalBranding(PluginTemplateExtension):
    def head(self):
        css = static("ddm_netbox_branding/backup-cloud-branding.css")
        js = static("ddm_netbox_branding/backup-cloud-branding.js")
        favicon = static("ddm_netbox_branding/backup-cloud-favicon.ico")
        return format_html(
            '<link rel="stylesheet" href="{}?v=2.0.0">'
            '<link rel="icon" type="image/x-icon" href="{}?v=2.0.0">'
            '<script defer src="{}?v=2.0.0"></script>'
            '<style id="backup-cloud-hide-netbox-release">'
            '#sidebar-menu > .text-muted.text-center.fs-5.my-3.px-3{{display:none!important;}}'
            '</style>',
            css, favicon, js
        )


template_extensions = [BackupCloudGlobalBranding]
PY

cat > "$STATIC/backup-cloud-branding.css" <<'CSS'
/* Backup Cloud - NetBox Branding 2.0 */
:root,
[data-bs-theme="light"],
[data-bs-theme="dark"] {
  --bc-navy:#0B1323;
  --bc-surface:#111827;
  --bc-surface-2:#172033;
  --bc-purple:#3E4095;
  --bc-purple-light:#5659C7;
  --bc-blue:#2563EB;
  --bc-cyan:#06B6D4;
  --bc-gray:#8C8D90;
  --bc-light:#E5E7EB;
  --bc-white:#FFFFFF;
  --tblr-primary:#3E4095;
  --tblr-primary-rgb:62,64,149;
  --tblr-link-color:#2563EB;
  --tblr-link-hover-color:#5659C7;
}

/* Barra lateral */
.navbar-vertical {
  background:linear-gradient(180deg,var(--bc-navy) 0%,var(--bc-surface) 100%)!important;
  border-right:3px solid var(--bc-purple-light)!important;
}
.navbar-vertical .nav-link,
.navbar-vertical .nav-link .nav-link-icon,
.navbar-vertical .navbar-brand {color:#e5e7eb!important}
.navbar-vertical .nav-link.active,
.navbar-vertical .nav-item.active>.nav-link,
.navbar-vertical .nav-link:hover {color:#fff!important;background:rgba(86,89,199,.14)!important}
.navbar-vertical .nav-link.active .nav-link-icon,
.navbar-vertical .nav-link:hover .nav-link-icon {color:var(--bc-cyan)!important}

/* Cabeçalho */
header.navbar {
  background:var(--bc-surface)!important;
  border-bottom:2px solid rgba(86,89,199,.65)!important;
}
header.navbar .form-control:focus,
.form-control:focus {border-color:var(--bc-blue)!important;box-shadow:0 0 0 .2rem rgba(37,99,235,.14)!important}

/* Acoes e cor primaria */
.btn-primary,
.bg-primary {
  background:linear-gradient(90deg,var(--bc-blue),var(--bc-purple-light))!important;
  border-color:var(--bc-blue)!important;
  color:#fff!important;
}
.btn-primary:hover,.btn-primary:focus,.btn-primary:active {
  background:linear-gradient(90deg,#1d4ed8,var(--bc-purple))!important;
  border-color:#1d4ed8!important;
}
.text-primary {color:var(--bc-cyan)!important}
a:not(.btn):not(.nav-link):not(.dropdown-item) {color:var(--bc-blue)}
a:not(.btn):not(.nav-link):not(.dropdown-item):hover {color:var(--bc-purple-light)}
.form-check-input:checked,.page-item.active .page-link {background-color:var(--bc-purple)!important;border-color:var(--bc-purple)!important}

/* Logo */
.navbar-brand-image.backup-cloud-brand-image {
  width:220px!important;
  height:auto!important;
  max-width:100%!important;
  max-height:62px!important;
  object-fit:contain!important;
}
.page-center img.logo.backup-cloud-brand-image {
  width:min(390px,84vw)!important;
  height:auto!important;
  max-height:none!important;
  object-fit:contain!important;
}

/* Login */
.page-center {
  background:
    radial-gradient(circle at top right,rgba(86,89,199,.18),transparent 34%),
    radial-gradient(circle at bottom left,rgba(6,182,212,.10),transparent 38%),
    var(--bc-navy)!important;
}
.page-center .card {
  border:1px solid rgba(148,163,184,.16)!important;
  border-top:3px solid var(--bc-purple-light)!important;
  border-radius:12px!important;
  box-shadow:0 18px 48px rgba(0,0,0,.28)!important;
}
.page-center .netbox-edition {color:#aeb7c7!important;margin-top:8px}

/* Cards, tabelas e detalhes */
.card {border-radius:9px}
.card-header {border-bottom-color:rgba(86,89,199,.20)}
.table-hover tbody tr:hover {--tblr-table-hover-bg:rgba(86,89,199,.055)}
.badge.bg-primary {background:var(--bc-purple)!important}

@media(max-width:991.98px){
  .navbar-brand-image.backup-cloud-brand-image{width:178px!important;max-height:50px!important}
}
CSS

cat > "$STATIC/backup-cloud-branding.js" <<'JS'
(() => {
  "use strict";
  const logo = "/static/ddm_netbox_branding/backup-cloud-logo.png?v=2.0.0";
  const apply = () => {
    document.querySelectorAll('img[src*="logo_netbox_dark_teal"],img[src*="logo_netbox_bright_teal"],img.ddm-brand-image').forEach(img => {
      img.src = logo;
      img.alt = "Backup Cloud";
      img.removeAttribute("height");
      img.classList.remove("ddm-brand-image");
      img.classList.add("backup-cloud-brand-image");
    });
    document.querySelectorAll(".netbox-edition").forEach(el => el.textContent = "Inventário de Infraestrutura");
    if (document.title) {
      document.title = document.title
        .replace(/\s*\|\s*NetBox\s*$/i, " | Backup Cloud")
        .replace(/\s*\|\s*DDMTI\s*$/i, " | Backup Cloud");
    }
  };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", apply); else apply();
  document.addEventListener("htmx:afterSwap", apply);
})();
JS

# Remove fontes visuais DDMTI antigas do source do plugin.
rm -f "$STATIC/ddm-branding.css" "$STATIC/ddm-branding.js" "$STATIC/ddm-brand.svg" "$STATIC/ddm-favicon.svg"

echo "[1/5] Validando plugin Backup Cloud..."
$VENV/bin/python manage.py check
$VENV/bin/python manage.py shell -c 'import ddm_netbox_branding as p; print("PLUGIN=" + p.config.verbose_name + " VERSION=" + p.config.version)' | tail -n1

echo "[2/5] Publicando arquivos estaticos..."
$VENV/bin/python manage.py collectstatic --no-input >/dev/null
[[ -s "$APP/static/ddm_netbox_branding/backup-cloud-branding.css" ]] || fail "CSS Backup Cloud nao publicado"
[[ -s "$APP/static/ddm_netbox_branding/backup-cloud-logo.png" ]] || fail "logo Backup Cloud nao publicada"
[[ -s "$APP/static/ddm_netbox_branding/backup-cloud-favicon.ico" ]] || fail "favicon Backup Cloud nao publicado"
rm -f "$APP/static/ddm_netbox_branding/ddm-branding.css" "$APP/static/ddm_netbox_branding/ddm-branding.js" "$APP/static/ddm_netbox_branding/ddm-brand.svg" "$APP/static/ddm_netbox_branding/ddm-favicon.svg"

echo "[3/5] Reiniciando NetBox..."
systemctl restart netbox netbox-rq
sleep 4
systemctl is-active --quiet netbox || fail "netbox nao voltou"
systemctl is-active --quiet netbox-rq || fail "netbox-rq nao voltou"

echo "[4/5] Validando HTML..."
HTTP="$(curl -sS -H "Host: $FQDN" -o /tmp/backup-cloud-netbox.html -w '%{http_code}' http://127.0.0.1:8001/)"
[[ "$HTTP" =~ ^(200|301|302)$ ]] || fail "NetBox respondeu HTTP $HTTP"
grep -q 'backup-cloud-branding.css' /tmp/backup-cloud-netbox.html || fail "CSS Backup Cloud nao apareceu no HTML"
grep -q 'backup-cloud-favicon.ico' /tmp/backup-cloud-netbox.html || fail "favicon Backup Cloud nao apareceu no HTML"
if grep -q 'ddm-branding.css' /tmp/backup-cloud-netbox.html; then fail "HTML ainda referencia CSS DDMTI antigo"; fi

echo "[5/5] Validando HTTPS..."
HTTPS_CSS="$(curl -ksS --resolve "$FQDN:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$FQDN/static/ddm_netbox_branding/backup-cloud-branding.css?v=2.0.0")"
HTTPS_LOGO="$(curl -ksS --resolve "$FQDN:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$FQDN/static/ddm_netbox_branding/backup-cloud-logo.png?v=2.0.0")"
[[ "$HTTPS_CSS" == "200" ]] || fail "CSS HTTPS respondeu $HTTPS_CSS"
[[ "$HTTPS_LOGO" == "200" ]] || fail "logo HTTPS respondeu $HTTPS_LOGO"

cat > /root/rollback-backup-cloud-netbox-branding.sh <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
rm -rf "$PKG"
cp -a "$BACKUP/plugin-anterior" "$PKG"
cd "$APP"
"$VENV/bin/python" manage.py check
"$VENV/bin/python" manage.py collectstatic --no-input >/dev/null
systemctl restart netbox netbox-rq
echo "Branding anterior restaurado a partir de: $BACKUP"
EOF
chmod 700 /root/rollback-backup-cloud-netbox-branding.sh

echo
echo "============================================================"
echo " BACKUP CLOUD NETBOX BRANDING - CONCLUIDO"
echo "============================================================"
echo "NetBox       : $VERSION"
echo "Marca        : Backup Cloud"
echo "Produto      : Inventario de Infraestrutura"
echo "App HTTP     : $HTTP"
echo "CSS HTTPS    : $HTTPS_CSS"
echo "Logo HTTPS   : $HTTPS_LOGO"
echo "Backup       : $BACKUP"
echo "Rollback     : /root/rollback-backup-cloud-netbox-branding.sh"
echo "Core NetBox  : intacto"
echo "============================================================"
