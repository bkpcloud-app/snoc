#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

BASE="/home/suporte"
FQDN="mobgw.bkpcloud.app.br"
PUBLIC_URL="https://${FQDN}"
MQTT_ENDPOINT="${FQDN}:31000"

TOMCAT_BASE="/var/lib/tomcat9"
CTX="${TOMCAT_BASE}/conf/Catalina/localhost/ROOT.xml"
WEBROOT="${TOMCAT_BASE}/webapps/ROOT"
MAINCSS="${WEBROOT}/css/main.css"
WEB_ASSET_DIR="${WEBROOT}/images/backup-cloud"
LOGO="${WEB_ASSET_DIR}/backup-cloud-logo.png"
HERO="${WEB_ASSET_DIR}/gestao-movel-login-hero.jpg"
ICON="${WEB_ASSET_DIR}/backup-cloud-icon.png"
FAVICON="${WEBROOT}/images/favicon.ico"

RAW_BASE="https://raw.githubusercontent.com/bkpcloud-app/snoc/main/assets/backup-cloud/gestao-movel/branding/web"
LOGO_B64_URL="${RAW_BASE}/backup-cloud-logo-dark-transparent.png.b64"
HERO_B64_URL="${RAW_BASE}/gestao-movel-login-hero.jpg.b64"
ICON_B64_URL="${RAW_BASE}/backup-cloud-icon.png.b64"
FAVICON_B64_URL="${RAW_BASE}/backup-cloud-favicon.ico.b64"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${BASE}/BACKUP-CLOUD-GESTAO-MOVEL-BRANDING-BACKUP-${STAMP}"
TMPDIR="$(mktemp -d /tmp/backup-cloud-branding.XXXXXX)"

fail() {
    echo "ERRO: $*" >&2
    exit 1
}

wait_port() {
    local port="$1" timeout="$2" i
    for ((i=0; i<timeout; i++)); do
        ss -H -lnt "sport = :${port}" 2>/dev/null | grep -q . && return 0
        sleep 1
    done
    return 1
}

cleanup() {
    rm -rf "$TMPDIR"
}
trap cleanup EXIT

[[ "$(id -u)" -eq 0 ]] || fail "execute como root"
[[ -s "$CTX" ]] || fail "ROOT.xml ausente: $CTX"
[[ -s "$MAINCSS" ]] || fail "main.css ausente: $MAINCSS"
command -v curl >/dev/null 2>&1 || fail "curl ausente"
command -v base64 >/dev/null 2>&1 || fail "base64 ausente"
command -v python3 >/dev/null 2>&1 || fail "python3 ausente"
command -v ss >/dev/null 2>&1 || fail "ss ausente"
systemctl is-active --quiet tomcat9 || fail "tomcat9 inativo"
systemctl is-active --quiet nginx || fail "nginx inativo"

mkdir -p "$BACKUP"
cp -a "$CTX" "$BACKUP/ROOT.xml"
cp -a "$MAINCSS" "$BACKUP/main.css"
[[ -f "$FAVICON" ]] && cp -a "$FAVICON" "$BACKUP/favicon.ico" || true
[[ -d "$WEB_ASSET_DIR" ]] && cp -a "$WEB_ASSET_DIR" "$BACKUP/backup-cloud-assets" || true

echo "Backup criado em: $BACKUP"

download_b64() {
    local url="$1" out="$2" tmp="$3"
    curl -fsSL "$url" -o "$tmp"
    base64 -d "$tmp" > "$out"
    [[ -s "$out" ]] || fail "asset vazio após decode: $url"
}

download_b64 "$LOGO_B64_URL" "$TMPDIR/logo.png" "$TMPDIR/logo.b64"
download_b64 "$HERO_B64_URL" "$TMPDIR/hero.jpg" "$TMPDIR/hero.b64"
download_b64 "$ICON_B64_URL" "$TMPDIR/icon.png" "$TMPDIR/icon.b64"
download_b64 "$FAVICON_B64_URL" "$TMPDIR/favicon.ico" "$TMPDIR/favicon.b64"

python3 - "$TMPDIR/logo.png" "$TMPDIR/hero.jpg" "$TMPDIR/icon.png" "$TMPDIR/favicon.ico" <<'PY'
from pathlib import Path
import sys
logo, hero, icon, fav = map(Path, sys.argv[1:])
checks = [
    (logo, b'\x89PNG\r\n\x1a\n', 5000, 'logo PNG'),
    (hero, b'\xff\xd8\xff', 10000, 'hero JPEG'),
    (icon, b'\x89PNG\r\n\x1a\n', 2000, 'ícone PNG'),
]
for path, sig, minimum, label in checks:
    data = path.read_bytes()
    if not data.startswith(sig) or len(data) < minimum:
        raise SystemExit(f'{label} inválido: {path}')
    print(f'{label}: OK ({len(data)} bytes)')
data = fav.read_bytes()
if len(data) < 1000 or data[:4] != b'\x00\x00\x01\x00':
    raise SystemExit(f'favicon ICO inválido: {fav}')
print(f'favicon ICO: OK ({len(data)} bytes)')
PY

install -d -o tomcat -g tomcat -m 0755 "$WEB_ASSET_DIR"
install -o root -g tomcat -m 0644 "$TMPDIR/logo.png" "$LOGO"
install -o root -g tomcat -m 0644 "$TMPDIR/hero.jpg" "$HERO"
install -o root -g tomcat -m 0644 "$TMPDIR/icon.png" "$ICON"
install -o root -g tomcat -m 0644 "$TMPDIR/favicon.ico" "$FAVICON"

# Rebranding nativo do Headwind MDM.
python3 - "$CTX" "$LOGO" <<'PY'
import sys
import xml.etree.ElementTree as ET

path, logo = sys.argv[1:]
tree = ET.parse(path)
root = tree.getroot()

values = {
    'base.url': 'https://mobgw.bkpcloud.app.br',
    'swagger.host': 'mobgw.bkpcloud.app.br',
    'mqtt.server.uri': 'mobgw.bkpcloud.app.br:31000',
    'rebranding.name': 'Gestão Móvel',
    'rebranding.vendor.name': 'Backup Cloud',
    'rebranding.vendor.link': '#',
    'rebranding.logo': logo,
    'rebranding.mobile.name': 'Gestão Móvel',
}

params = {p.get('name'): p for p in root.findall('Parameter') if p.get('name')}
for name, value in values.items():
    node = params.get(name)
    if node is None:
        node = ET.SubElement(root, 'Parameter')
        node.set('name', name)
        params[name] = node
    node.set('value', value)

ET.indent(tree, space='    ')
tree.write(path, encoding='UTF-8', xml_declaration=True)
ET.parse(path)

for name, expected in values.items():
    actual = params[name].get('value')
    if actual != expected:
        raise SystemExit(f'Falha em {name}: {actual!r}')
    print(f'{name}={actual}')
PY

# Remove os blocos visuais antigos e grava a camada Backup Cloud.
python3 - "$MAINCSS" <<'PY'
from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding='utf-8')

markers = [
    ('/* === DDM GESTAO MOVEL - INICIO === */', '/* === DDM GESTAO MOVEL - FIM === */'),
    ('/* === DDM GESTAO MOVEL - PRODUCAO - INICIO === */', '/* === DDM GESTAO MOVEL - PRODUCAO - FIM === */'),
    ('/* === DDM POLIMENTO PRODUCAO - INICIO === */', '/* === DDM POLIMENTO PRODUCAO - FIM === */'),
    ('/* === BACKUP CLOUD GESTAO MOVEL - INICIO === */', '/* === BACKUP CLOUD GESTAO MOVEL - FIM === */'),
]
for start, end in markers:
    s = re.sub(re.escape(start) + r'.*?' + re.escape(end), '', s, flags=re.S)

css = r'''

/* === BACKUP CLOUD GESTAO MOVEL - INICIO === */
:root {
    --bc-navy: #0B1323;
    --bc-surface: #111827;
    --bc-surface-2: #172033;
    --bc-purple: #3E4095;
    --bc-purple-light: #5659C7;
    --bc-blue: #2563EB;
    --bc-cyan: #06B6D4;
    --bc-gray: #8C8D90;
    --bc-light: #E5E7EB;
    --bc-white: #FFFFFF;
    --bc-success: #22C55E;
    --bc-danger: #EF4444;
}

body {
    background: #f3f4f6 !important;
    color: #1f2937;
}

/* Cabeçalho autenticado */
.header {
    background: linear-gradient(90deg, var(--bc-navy) 0%, var(--bc-surface) 58%, #171a35 100%) !important;
    border-color: var(--bc-navy) !important;
    box-shadow: 0 2px 12px rgba(4, 9, 20, .24) !important;
}

.header .logo-text a,
.header .logo-text a:active,
.header .logo-text a:hover,
.header a {
    color: var(--bc-white) !important;
}

.header .logo-text a {
    font-weight: 600 !important;
    letter-spacing: .1px !important;
}

.header .open a,
.header .open .dropdown-menu {
    background-color: var(--bc-surface) !important;
}

.header .open .dropdown-menu a:hover {
    background-color: #202a40 !important;
}

/* Ações */
.btn-primary,
.login .btn-default {
    background: linear-gradient(90deg, var(--bc-blue), var(--bc-purple-light)) !important;
    border-color: var(--bc-blue) !important;
    color: var(--bc-white) !important;
    border-radius: 7px !important;
    font-weight: 600 !important;
    box-shadow: 0 5px 16px rgba(37, 99, 235, .18) !important;
}

.btn-primary:hover,
.btn-primary:focus,
.btn-primary:active,
.login .btn-default:not([disabled]):hover,
.login .btn-default:not([disabled]):focus,
.login .btn-default:not([disabled]):active {
    background: linear-gradient(90deg, #1d4ed8, var(--bc-purple)) !important;
    border-color: #1d4ed8 !important;
    color: var(--bc-white) !important;
}

.login .btn-default[disabled],
.login .btn-default.disabled {
    opacity: .68 !important;
}

a,
.action-link,
.login .action-link {
    color: var(--bc-blue) !important;
}

a:hover,
.action-link:hover,
.login .action-link:hover {
    color: var(--bc-purple-light) !important;
}

.nav-tabs > li.active > a,
.nav-tabs > li.active > a:hover,
.nav-tabs > li.active > a:focus {
    border-top: 3px solid var(--bc-purple) !important;
}

/* Login Backup Cloud / Gestão Móvel */
.login-logo {
    max-width: 660px !important;
    margin: 46px auto 18px auto !important;
    display: flex !important;
    flex-direction: column !important;
    align-items: center !important;
    justify-content: center !important;
    gap: 9px !important;
    white-space: normal !important;
    position: relative !important;
    z-index: 2 !important;
}

.login-logo img {
    width: 330px !important;
    height: auto !important;
    max-height: 150px !important;
    object-fit: contain !important;
    margin: 0 !important;
    padding: 0 !important;
    filter: drop-shadow(0 7px 22px rgba(0, 0, 0, .22));
}

.login-logo .logo {
    margin: -7px 0 0 0 !important;
    padding: 0 !important;
    max-height: none !important;
    color: #f8fafc !important;
    font-size: 26px !important;
    font-weight: 500 !important;
    line-height: 1.1 !important;
    letter-spacing: .2px !important;
    text-shadow: 0 2px 10px rgba(0, 0, 0, .35);
}

/* O pseudo-elemento cria o fundo somente na região do login sem alterar HTML/JS. */
.login-logo::before {
    content: "";
    position: fixed;
    inset: 0;
    z-index: -2;
    background:
        linear-gradient(90deg, rgba(6, 13, 27, .18) 0%, rgba(6, 13, 27, .42) 42%, rgba(6, 13, 27, .88) 68%, rgba(6, 13, 27, .96) 100%),
        url('../images/backup-cloud/gestao-movel-login-hero.jpg') center center / cover no-repeat,
        var(--bc-navy);
}

.login-logo::after {
    content: "Backup Cloud  •  Gestão Móvel";
    color: #cbd5e1;
    font-size: 13px;
    letter-spacing: .35px;
    text-transform: none;
}

.login {
    width: 480px !important;
    border: 1px solid rgba(148, 163, 184, .18) !important;
    border-top: 2px solid var(--bc-purple-light) !important;
    border-radius: 12px !important;
    overflow: hidden !important;
    position: relative !important;
    z-index: 2 !important;
    box-shadow: 0 22px 58px rgba(0, 0, 0, .34) !important;
    backdrop-filter: blur(10px);
}

.login .panel-body {
    background: rgba(17, 24, 39, .94) !important;
    padding: 31px 36px !important;
}

.login label {
    color: #e5e7eb !important;
    font-weight: 500 !important;
}

.login .form-control {
    height: 43px !important;
    color: #f8fafc !important;
    background: rgba(9, 16, 30, .86) !important;
    border-color: #334155 !important;
    border-radius: 7px !important;
    box-shadow: none !important;
}

.login .form-control::placeholder {
    color: #7f8da3 !important;
}

.login .form-control:focus {
    border-color: var(--bc-blue) !important;
    box-shadow: 0 0 0 3px rgba(37, 99, 235, .17) !important;
}

.login-footer {
    position: relative !important;
    z-index: 2 !important;
    border-top: 0 !important;
    background: transparent !important;
    color: #9ca3af !important;
    font-size: 12px !important;
    text-shadow: 0 1px 5px rgba(0, 0, 0, .4);
}

.login-footer > * {
    display: none !important;
}

.login-footer::after {
    content: "Backup Cloud  •  Gestão Móvel" !important;
    color: #9ca3af !important;
}

.panel-danger > .panel-heading {
    background: rgba(127, 29, 29, .22) !important;
    color: #fecaca !important;
    border-color: rgba(239, 68, 68, .28) !important;
}

@media (max-width: 760px) {
    .login-logo {
        width: calc(100% - 28px) !important;
        margin-top: 28px !important;
    }

    .login-logo img {
        width: min(300px, 88vw) !important;
    }

    .login-logo .logo {
        font-size: 23px !important;
    }

    .login {
        width: calc(100% - 28px) !important;
    }

    .login .panel-body {
        padding: 26px 24px !important;
    }

    .login-logo::before {
        background:
            linear-gradient(rgba(6, 13, 27, .78), rgba(6, 13, 27, .94)),
            url('../images/backup-cloud/gestao-movel-login-hero.jpg') center center / cover no-repeat,
            var(--bc-navy);
    }
}

/* === BACKUP CLOUD GESTAO MOVEL - FIM === */
'''

p.write_text(s.rstrip() + css + '\n', encoding='utf-8')
PY

chown root:tomcat "$MAINCSS"
chmod 0644 "$MAINCSS"

# Reinício necessário para recarregar os parâmetros de rebranding do contexto.
systemctl restart tomcat9
wait_port 8080 180 || {
    echo "Tomcat não voltou. Restaurando configuração..." >&2
    cp -a "$BACKUP/ROOT.xml" "$CTX"
    cp -a "$BACKUP/main.css" "$MAINCSS"
    [[ -f "$BACKUP/favicon.ico" ]] && cp -a "$BACKUP/favicon.ico" "$FAVICON" || true
    rm -rf "$WEB_ASSET_DIR"
    [[ -d "$BACKUP/backup-cloud-assets" ]] && cp -a "$BACKUP/backup-cloud-assets" "$WEB_ASSET_DIR" || true
    systemctl restart tomcat9 || true
    journalctl -u tomcat9 -n 120 --no-pager || true
    fail "branding revertido porque o Tomcat não voltou"
}

sleep 3

echo
echo "===== VALIDACAO ====="
python3 -c 'import xml.etree.ElementTree as ET; ET.parse("/var/lib/tomcat9/conf/Catalina/localhost/ROOT.xml"); print("ROOT.xml       : OK")'
grep -q 'BACKUP CLOUD GESTAO MOVEL - INICIO' "$MAINCSS" || fail "CSS Backup Cloud não aplicado"
echo "CSS            : OK"

NAME_JSON="$(curl -fsS http://127.0.0.1:8080/rest/public/name)"
printf '%s' "$NAME_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("status")=="OK"; data=d.get("data",{}); assert data.get("appName")=="Gestão Móvel"; assert data.get("vendorName")=="Backup Cloud"' \
    || fail "API de rebranding não retornou Gestão Móvel / Backup Cloud"
echo "Rebranding API : OK"

curl -fsS http://127.0.0.1:8080/rest/public/logo -o "$TMPDIR/logo-check.png"
python3 - "$TMPDIR/logo-check.png" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
d = p.read_bytes()
assert d.startswith(b'\x89PNG\r\n\x1a\n') and len(d) > 5000
print(f'Logo API       : OK ({len(d)} bytes)')
PY

HTTP="$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/)"
HTTPS="$(curl -ksS --resolve "${FQDN}:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://${FQDN}/")"
[[ "$HTTP" == "200" ]] || fail "index Tomcat HTTP=$HTTP"
[[ "$HTTPS" =~ ^(200|301|302)$ ]] || fail "HTTPS Nginx HTTP=$HTTPS"

echo "Tomcat         : HTTP $HTTP"
echo "HTTPS          : HTTP $HTTPS"
echo
echo "============================================================"
echo " BACKUP CLOUD - GESTAO MOVEL"
echo " BRANDING APLICADO COM SUCESSO"
echo "============================================================"
echo "URL        : ${PUBLIC_URL}/#/login"
echo "Produto    : Gestão Móvel"
echo "Marca      : Backup Cloud"
echo "HTTPS      : 443"
echo "MQTT       : ${MQTT_ENDPOINT}"
echo "Backup     : ${BACKUP}"
echo "HTML/JS    : não alterados"
echo "============================================================"
