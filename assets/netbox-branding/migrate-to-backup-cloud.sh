#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

VERSION="2026.08.07.1"
APP="/opt/netbox/netbox"
VENV="/opt/netbox/venv"
CONFIG="$APP/netbox/configuration.py"
PLUGIN_ROOT="/opt/netbox/local/ddm-netbox-branding"
PKG="${PLUGIN_ROOT}/ddm_netbox_branding"
STATIC="${PKG}/static/ddm_netbox_branding"
INIT="${PKG}/__init__.py"
TC="${PKG}/template_content.py"
FQDN="inventory.bkpcloud.app.br"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/opt/netbox/backups/backupcloud-netbox-branding-${STAMP}"
TMPDIR="$(mktemp -d /tmp/backupcloud-netbox.XXXXXX)"
RAW="${BC_RAW_BASE:-https://raw.githubusercontent.com/bkpcloud-app/snoc/main/assets/backup-cloud/gestao-movel/branding/web}"
LOGO_B64="$RAW/backup-cloud-logo-dark-transparent.png.b64"
LOGO_FILE="$STATIC/backupcloud-logo.png"
CHANGED=0

fail(){ echo "ERRO: $*" >&2; exit 1; }
cleanup(){ rm -rf "$TMPDIR"; }
rollback(){
  rc=$?
  trap - ERR
  set +e
  if [[ "$CHANGED" == "1" && -d "$BACKUP/plugin-anterior" ]]; then
    echo "ROLLBACK: restaurando branding anterior..."
    rm -rf "$PKG"
    cp -a "$BACKUP/plugin-anterior" "$PKG"
    [[ -f "$BACKUP/configuration.py" ]] && cp -a "$BACKUP/configuration.py" "$CONFIG"
    cd "$APP"
    "$VENV/bin/python" manage.py collectstatic --no-input >/dev/null 2>&1 || true
    systemctl restart netbox netbox-rq >/dev/null 2>&1 || true
    echo "ROLLBACK concluido: $BACKUP"
  fi
  exit "$rc"
}
trap cleanup EXIT
trap rollback ERR

[[ "$(id -u)" -eq 0 ]] || fail "execute como root"
[[ -x "$VENV/bin/python" ]] || fail "venv do NetBox nao encontrado"
[[ -f "$CONFIG" ]] || fail "configuration.py nao encontrado"
[[ -d "$PKG" ]] || fail "plugin de branding atual nao encontrado"
[[ -f "$INIT" ]] || fail "__init__.py do plugin nao encontrado"
[[ -f "$TC" ]] || fail "template_content.py do plugin nao encontrado"
for c in curl python3 grep install cp rm mkdir; do command -v "$c" >/dev/null || fail "comando ausente: $c"; done

cd "$APP"
NETBOX_VERSION="$($VENV/bin/python manage.py shell -c 'from django.conf import settings; print(settings.VERSION)' 2>/dev/null | tail -n1)"
[[ "$NETBOX_VERSION" == "4.6.5" ]] || fail "ajuste homologado para NetBox 4.6.5; detectado: $NETBOX_VERSION"

for svc in netbox netbox-rq nginx; do
  systemctl is-active --quiet "$svc" || fail "servico $svc nao esta ativo"
done

echo "============================================================"
echo " BACKUPCLOUD | INVENTARIO"
echo " Instalador: $VERSION"
echo " NetBox: $NETBOX_VERSION"
echo "============================================================"

echo "[1/7] Pre-validando logo - nenhuma alteracao ainda"
curl -fLsS --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 60 "$LOGO_B64" -o "$TMPDIR/logo.b64"
python3 - "$TMPDIR/logo.b64" "$TMPDIR/backupcloud-logo.png" <<'PY'
from pathlib import Path
import base64,re,struct,sys
src,dst=map(Path,sys.argv[1:])
s=re.sub(r'\s+','',src.read_text(encoding='ascii'))
if not re.fullmatch(r'[A-Za-z0-9+/]*={0,2}',s) or len(s)%4:
    raise SystemExit('Base64 da logo invalido')
data=base64.b64decode(s,validate=True)
if not data.startswith(b'\x89PNG\r\n\x1a\n') or data[12:16] != b'IHDR' or b'IEND' not in data[-32:]:
    raise SystemExit('logo PNG invalida')
w,h=struct.unpack('>II',data[16:24])
if w < 300 or h < 100:
    raise SystemExit(f'dimensoes inesperadas da logo: {w}x{h}')
dst.write_bytes(data)
print(f'   Logo OK: {w}x{h} | {len(data)} bytes')
PY

echo "[2/7] Criando backup"
mkdir -p "$BACKUP"
cp -a "$PKG" "$BACKUP/plugin-anterior"
cp -a "$CONFIG" "$BACKUP/configuration.py"
CHANGED=1
echo "   $BACKUP"

echo "[3/7] Aplicando identidade BackupCloud"
install -d -m 0755 "$STATIC"
install -m 0644 "$TMPDIR/backupcloud-logo.png" "$LOGO_FILE"

cat > "$INIT" <<'PY'
from netbox.plugins import PluginConfig


class BackupCloudNetBoxBrandingConfig(PluginConfig):
    name = "ddm_netbox_branding"
    verbose_name = "BackupCloud | Inventário"
    description = "Identidade visual BackupCloud para o produto Inventário"
    version = "3.0.0"
    author = "BackupCloud"
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
        css = static("ddm_netbox_branding/backupcloud-branding.css")
        js = static("ddm_netbox_branding/backupcloud-branding.js")
        logo = static("ddm_netbox_branding/backupcloud-logo.png")
        return format_html(
            '<link rel="stylesheet" href="{}?v=3.0.0">'
            '<link rel="icon" type="image/png" href="{}?v=3.0.0">'
            '<script defer src="{}?v=3.0.0"></script>'
            '<style id="backupcloud-netbox-release">'
            '#sidebar-menu > .text-muted.text-center.fs-5.my-3.px-3{{display:none!important;}}'
            '</style>',
            css, logo, js
        )


template_extensions = [BackupCloudGlobalBranding]
PY

cat > "$STATIC/backupcloud-branding.css" <<'CSS'
/* === BACKUPCLOUD INVENTARIO FINAL - INICIO === */
:root,
[data-bs-theme="light"],
[data-bs-theme="dark"]{
  --bc-bg:#111a2c;
  --bc-bg2:#182640;
  --bc-panel:#243552;
  --bc-panel2:#1d2c47;
  --bc-purple:#5659c7;
  --bc-blue:#3578f6;
  --bc-text:#e8eef9;
  --bc-muted:#aebbd0;
  --bc-border:rgba(148,163,184,.28);
  --tblr-primary:#5659c7;
  --tblr-primary-rgb:86,89,199;
  --tblr-link-color:#64b5f6;
  --tblr-link-hover-color:#91c9ff;
}

body{
  color:var(--bc-text)!important;
  background:
    radial-gradient(circle at 16% 22%,rgba(86,89,199,.30),transparent 31%),
    radial-gradient(circle at 82% 70%,rgba(53,120,246,.18),transparent 34%),
    linear-gradient(135deg,var(--bc-bg) 0%,var(--bc-bg2) 52%,#25295c 100%) fixed!important;
}

.navbar-vertical{
  background:linear-gradient(180deg,#111a2c 0%,#182640 65%,#20264d 100%)!important;
  border-right:1px solid rgba(148,163,184,.20)!important;
  box-shadow:4px 0 18px rgba(4,9,20,.15)!important;
}
.navbar-vertical .nav-link,
.navbar-vertical .nav-link .nav-link-icon,
.navbar-vertical .navbar-brand{color:#dfe8f5!important}
.navbar-vertical .nav-link:hover,
.navbar-vertical .nav-link.active,
.navbar-vertical .nav-item.active>.nav-link{
  color:#fff!important;
  background:rgba(86,89,199,.18)!important;
}
.navbar-vertical .nav-link:hover .nav-link-icon,
.navbar-vertical .nav-link.active .nav-link-icon{color:#91c9ff!important}

header.navbar{
  background:linear-gradient(90deg,#111a2c,#182640 60%,#25295c)!important;
  border-bottom:1px solid rgba(148,163,184,.18)!important;
  box-shadow:0 2px 12px rgba(4,9,20,.20)!important;
}
header.navbar a,header.navbar button{color:#f8fbff!important}

.page-wrapper,.page-body,.container-xl,.container-fluid,.container{background:transparent!important}

.card,.modal-content,.dropdown-menu{
  background:rgba(36,53,82,.94)!important;
  color:var(--bc-text)!important;
  border:1px solid var(--bc-border)!important;
  border-radius:10px!important;
  box-shadow:0 12px 32px rgba(0,0,0,.16)!important;
}
.card-header,.modal-header,.modal-footer{border-color:rgba(148,163,184,.20)!important}
.card-title,.card-header,.modal-title,label,.form-label{color:#edf4ff!important}
.text-secondary,.text-muted,.help-text,.form-hint{color:var(--bc-muted)!important}

.table{--tblr-table-color:#dfe8f5;--tblr-table-bg:transparent;color:#dfe8f5!important}
.table>:not(caption)>*>*{background:transparent!important;border-color:rgba(148,163,184,.18)!important;color:#dfe8f5!important}
.table-hover>tbody>tr:hover>*{background:rgba(255,255,255,.045)!important;color:#fff!important}
.table a{color:#64b5f6!important}

.form-control,.form-select,.ts-control,input.form-control,textarea.form-control{
  background:#f8fafc!important;
  color:#26364e!important;
  border:1px solid #bac8da!important;
  border-radius:6px!important;
  box-shadow:none!important;
}
.form-control::placeholder{color:#6b7b91!important}
.form-control:focus,.form-select:focus,.ts-control:focus-within{
  border-color:#6e8cff!important;
  box-shadow:0 0 0 3px rgba(86,89,199,.15)!important;
}

.btn-primary,.bg-primary{
  background:linear-gradient(90deg,var(--bc-blue),var(--bc-purple))!important;
  border-color:transparent!important;
  color:#fff!important;
}
.btn-primary:hover,.btn-primary:focus,.btn-primary:active{
  background:linear-gradient(90deg,#2669e8,#4a4db5)!important;
  color:#fff!important;
}
.form-check-input:checked,.page-item.active .page-link{
  background-color:var(--bc-purple)!important;
  border-color:var(--bc-purple)!important;
}

a:not(.btn):not(.nav-link):not(.dropdown-item){color:#64b5f6}
a:not(.btn):not(.nav-link):not(.dropdown-item):hover{color:#91c9ff}

.navbar-brand-image.backupcloud-brand-image{
  width:205px!important;
  max-width:100%!important;
  max-height:56px!important;
  height:auto!important;
  object-fit:contain!important;
}

.page-center{
  background:
    radial-gradient(circle at 16% 22%,rgba(86,89,199,.34),transparent 31%),
    radial-gradient(circle at 82% 70%,rgba(53,120,246,.22),transparent 34%),
    linear-gradient(135deg,var(--bc-bg) 0%,var(--bc-bg2) 52%,#25295c 100%) fixed!important;
}
.page-center img.logo.backupcloud-brand-image{
  width:min(360px,68vw)!important;
  max-width:360px!important;
  max-height:none!important;
  height:auto!important;
  margin:0 auto 8px!important;
  background:transparent!important;
  box-shadow:none!important;
}
.page-center .card{
  width:min(500px,calc(100vw - 28px))!important;
  background:rgba(36,53,82,.94)!important;
  border:1px solid rgba(153,170,205,.46)!important;
  border-top:2px solid #7377e6!important;
  box-shadow:0 20px 52px rgba(0,0,0,.24)!important;
}
.page-center .netbox-edition{
  color:#cfd7e6!important;
  font-size:14px!important;
  letter-spacing:.26em!important;
  text-transform:uppercase!important;
  font-weight:500!important;
  margin-top:4px!important;
}

.badge.bg-primary{background:var(--bc-purple)!important}

@media(max-width:991.98px){
  .navbar-brand-image.backupcloud-brand-image{width:165px!important;max-height:48px!important}
}
@media(max-width:760px){
  .page-center img.logo.backupcloud-brand-image{width:min(320px,72vw)!important}
  .page-center .netbox-edition{font-size:12px!important;letter-spacing:.20em!important}
}
/* === BACKUPCLOUD INVENTARIO FINAL - FIM === */
CSS

cat > "$STATIC/backupcloud-branding.js" <<'JS'
(() => {
  "use strict";
  const logo = "/static/ddm_netbox_branding/backupcloud-logo.png?v=3.0.0";
  const apply = () => {
    document.querySelectorAll('img[src*="logo_netbox_dark_teal"],img[src*="logo_netbox_bright_teal"],img.ddm-brand-image,img.backup-cloud-brand-image').forEach(img => {
      img.src = logo;
      img.alt = "BackupCloud";
      img.removeAttribute("height");
      img.classList.remove("ddm-brand-image","backup-cloud-brand-image");
      img.classList.add("backupcloud-brand-image");
    });

    document.querySelectorAll(".netbox-edition").forEach(el => {
      el.textContent = "Inventário";
    });

    if (document.title) {
      document.title = document.title
        .replace(/\s*\|\s*NetBox\s*$/i, " | BackupCloud | Inventário")
        .replace(/\s*\|\s*DDMTI\s*$/i, " | BackupCloud | Inventário")
        .replace(/\s*\|\s*Backup Cloud\s*$/i, " | BackupCloud | Inventário");
      if (!/BackupCloud/i.test(document.title)) {
        document.title = document.title + " | BackupCloud | Inventário";
      }
    }
  };

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", apply);
  } else {
    apply();
  }
  document.addEventListener("htmx:afterSwap", apply);
})();
JS

rm -f \
  "$STATIC/ddm-branding.css" \
  "$STATIC/ddm-branding.js" \
  "$STATIC/ddm-brand.svg" \
  "$STATIC/ddm-favicon.svg" \
  "$STATIC/backup-cloud-branding.css" \
  "$STATIC/backup-cloud-branding.js" \
  "$STATIC/backup-cloud-logo.png" \
  "$STATIC/backup-cloud-icon.png" \
  "$STATIC/backup-cloud-favicon.ico"

echo "[4/7] Validando plugin e publicando estaticos"
"$VENV/bin/python" manage.py check
"$VENV/bin/python" manage.py shell -c 'import ddm_netbox_branding as p; print("PLUGIN=" + p.config.verbose_name + " VERSION=" + p.config.version)' | tail -n1
"$VENV/bin/python" manage.py collectstatic --no-input >/dev/null
[[ -s "$APP/static/ddm_netbox_branding/backupcloud-branding.css" ]] || fail "CSS BackupCloud nao publicado"
[[ -s "$APP/static/ddm_netbox_branding/backupcloud-branding.js" ]] || fail "JS BackupCloud nao publicado"
[[ -s "$APP/static/ddm_netbox_branding/backupcloud-logo.png" ]] || fail "logo BackupCloud nao publicada"

# remove sobras antigas do diretório final de static
rm -f \
  "$APP/static/ddm_netbox_branding/ddm-branding.css" \
  "$APP/static/ddm_netbox_branding/ddm-branding.js" \
  "$APP/static/ddm_netbox_branding/ddm-brand.svg" \
  "$APP/static/ddm_netbox_branding/ddm-favicon.svg" \
  "$APP/static/ddm_netbox_branding/backup-cloud-branding.css" \
  "$APP/static/ddm_netbox_branding/backup-cloud-branding.js" \
  "$APP/static/ddm_netbox_branding/backup-cloud-logo.png" \
  "$APP/static/ddm_netbox_branding/backup-cloud-icon.png" \
  "$APP/static/ddm_netbox_branding/backup-cloud-favicon.ico"

echo "[5/7] Reiniciando NetBox"
systemctl restart netbox netbox-rq
sleep 4
systemctl is-active --quiet netbox || fail "netbox nao voltou"
systemctl is-active --quiet netbox-rq || fail "netbox-rq nao voltou"

echo "[6/7] Validando HTML e arquivos estaticos"
HTTP="$(curl -sS -H "Host: $FQDN" -o "$TMPDIR/netbox.html" -w '%{http_code}' http://127.0.0.1:8001/)"
[[ "$HTTP" =~ ^(200|301|302)$ ]] || fail "NetBox respondeu HTTP $HTTP"
grep -q 'backupcloud-branding.css' "$TMPDIR/netbox.html" || fail "CSS BackupCloud nao apareceu no HTML"
grep -q 'backupcloud-branding.js' "$TMPDIR/netbox.html" || fail "JS BackupCloud nao apareceu no HTML"
if grep -Eq 'ddm-branding|backup-cloud-branding' "$TMPDIR/netbox.html"; then fail "HTML ainda referencia branding antigo"; fi

STATIC_CSS="$(curl -ksS --resolve "$FQDN:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$FQDN/static/ddm_netbox_branding/backupcloud-branding.css?v=3.0.0")"
STATIC_JS="$(curl -ksS --resolve "$FQDN:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$FQDN/static/ddm_netbox_branding/backupcloud-branding.js?v=3.0.0")"
STATIC_LOGO="$(curl -ksS --resolve "$FQDN:443:127.0.0.1" -o "$TMPDIR/live-logo.png" -w '%{http_code}' "https://$FQDN/static/ddm_netbox_branding/backupcloud-logo.png?v=3.0.0")"
[[ "$STATIC_CSS" == "200" ]] || fail "CSS HTTPS respondeu $STATIC_CSS"
[[ "$STATIC_JS" == "200" ]] || fail "JS HTTPS respondeu $STATIC_JS"
[[ "$STATIC_LOGO" == "200" ]] || fail "logo HTTPS respondeu $STATIC_LOGO"
python3 - "$TMPDIR/live-logo.png" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); data=p.read_bytes()
if not data.startswith(b'\x89PNG\r\n\x1a\n') or b'IEND' not in data[-32:]:
    raise SystemExit('logo servida por HTTPS invalida')
print('   HTTPS: CSS + JS + logo OK')
PY

echo "[7/7] Criando rollback"
cat > /root/rollback-backupcloud-netbox-branding.sh <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
APP="$APP"
VENV="$VENV"
CONFIG="$CONFIG"
PKG="$PKG"
BACKUP="$BACKUP"
rm -rf "\$PKG"
cp -a "\$BACKUP/plugin-anterior" "\$PKG"
cp -a "\$BACKUP/configuration.py" "\$CONFIG"
cd "\$APP"
"\$VENV/bin/python" manage.py check
"\$VENV/bin/python" manage.py collectstatic --no-input >/dev/null
systemctl restart netbox netbox-rq
echo "Branding anterior restaurado: \$BACKUP"
EOF
chmod 700 /root/rollback-backupcloud-netbox-branding.sh

CHANGED=0
trap - ERR

echo
echo "============================================================"
echo " SUCESSO - BACKUPCLOUD | INVENTARIO"
echo "============================================================"
echo "NetBox      : $NETBOX_VERSION"
echo "Marca       : BackupCloud"
echo "Produto     : Inventario"
echo "App HTTP    : $HTTP"
echo "CSS HTTPS   : $STATIC_CSS"
echo "JS HTTPS    : $STATIC_JS"
echo "Logo HTTPS  : $STATIC_LOGO"
echo "Backup      : $BACKUP"
echo "Rollback    : /root/rollback-backupcloud-netbox-branding.sh"
echo "Core NetBox : intacto"
echo "============================================================"
