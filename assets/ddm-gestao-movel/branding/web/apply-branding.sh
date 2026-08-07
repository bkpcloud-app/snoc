#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

BASE="/home/suporte"
FQDN="mobgw.bkpcloud.app.br"
PUBLIC_URL="https://${FQDN}:9091"

TOMCAT_BASE="/var/lib/tomcat9"
CTX="${TOMCAT_BASE}/conf/Catalina/localhost/ROOT.xml"
WEBROOT="${TOMCAT_BASE}/webapps/ROOT"
INDEX="${WEBROOT}/index.html"
CSS="${WEBROOT}/css/ddm-branding.css"
BRAND_DIR="${TOMCAT_BASE}/work/ddm-branding"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${BASE}/DDM-MDM-BRANDING-BACKUP-${STAMP}"

fail() {
    echo "ERRO: $*" >&2
    exit 1
}

wait_port() {
    local port="$1"
    local timeout="$2"
    local i
    for ((i=0; i<timeout; i++)); do
        if ss -H -lnt "sport = :${port}" | grep -q .; then
            return 0
        fi
        sleep 1
    done
    return 1
}

[[ "$(id -u)" -eq 0 ]] || fail "execute como root"
[[ -s "$CTX" ]] || fail "ROOT.xml ausente: $CTX"
[[ -s "$INDEX" ]] || fail "index.html ausente: $INDEX"
systemctl is-active --quiet tomcat9 || fail "tomcat9 inativo"
systemctl is-active --quiet nginx || fail "nginx inativo"

mkdir -p "$BACKUP"
cp -a "$CTX" "$BACKUP/ROOT.xml"
cp -a "$INDEX" "$BACKUP/index.html"
[[ -f "$CSS" ]] && cp -a "$CSS" "$BACKUP/ddm-branding.css" || true

echo "Backup: $BACKUP"

install -d -o tomcat -g tomcat -m 0755 "$BRAND_DIR"

printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=' \
    | base64 -d > "${BRAND_DIR}/logo.png"
chown tomcat:tomcat "${BRAND_DIR}/logo.png"
chmod 0644 "${BRAND_DIR}/logo.png"

python3 - "$CTX" "$BRAND_DIR/logo.png" <<'PYXML'
import sys
import xml.etree.ElementTree as ET

path, logo = sys.argv[1:]
tree = ET.parse(path)
root = tree.getroot()

values = {
    "base.url": "https://mobgw.bkpcloud.app.br:9091",
    "swagger.host": "mobgw.bkpcloud.app.br:9091",
    "mqtt.server.uri": "mobgw.bkpcloud.app.br:31000",
    "rebranding.name": "DDM Gestão Móvel",
    "rebranding.vendor.name": "DDMTI Soluções",
    "rebranding.vendor.link": "#",
    "rebranding.logo": logo,
    "rebranding.mobile.name": "DDM Gestão Móvel",
    "rebranding.signup.link": "",
    "rebranding.terms.link": "",
}

params = {
    p.get("name"): p
    for p in root.findall("Parameter")
    if p.get("name")
}

for name, value in values.items():
    node = params.get(name)
    if node is None:
        node = ET.SubElement(root, "Parameter")
        node.set("name", name)
        params[name] = node
    node.set("value", value)

ET.indent(tree, space="    ")
tree.write(path, encoding="UTF-8", xml_declaration=True)
ET.parse(path)

for name in values:
    node = params[name]
    print(f"{name}={node.get('value')}")
PYXML

echo
echo "Reiniciando Tomcat para carregar o rebranding..."
systemctl restart tomcat9
wait_port 8080 180 || {
    journalctl -u tomcat9 -n 120 --no-pager
    fail "Tomcat não voltou na porta 8080"
}

for i in $(seq 1 60); do
    [[ -s "$INDEX" ]] && break
    sleep 1
done
[[ -s "$INDEX" ]] || fail "index.html não reapareceu após restart"

cat > "$CSS" <<'CSS'
:root {
    --ddm-orange: #f58220;
    --ddm-orange-dark: #df6d0f;
    --ddm-yellow: #ffc928;
    --ddm-graphite: #30343a;
    --ddm-muted: #6b7077;
    --ddm-bg: #f4f6f8;
    --ddm-white: #ffffff;
}

body {
    background: var(--ddm-bg) !important;
    color: var(--ddm-graphite);
}

.header {
    background: linear-gradient(90deg, var(--ddm-yellow) 0%, var(--ddm-orange) 100%) !important;
    border: 0 !important;
    box-shadow: 0 2px 10px rgba(0,0,0,.12);
}

.header .logo-text a,
.header .logo-text a:active,
.header .logo-text a:hover,
.header a {
    color: #fff !important;
}

.header .logo-text a {
    font-weight: 700 !important;
    letter-spacing: .2px;
}

.header .open a,
.header .open .dropdown-menu {
    background-color: var(--ddm-orange) !important;
}

.header .open .dropdown-menu a:hover {
    background-color: var(--ddm-orange-dark) !important;
}

.login-logo {
    max-width: 520px !important;
    margin: 64px auto 18px auto !important;
    display: flex;
    align-items: center;
    justify-content: center;
    white-space: normal !important;
}

.login-logo img {
    display: none !important;
}

.login-logo::before {
    content: "";
    display: inline-block;
    width: 74px;
    height: 74px;
    min-width: 74px;
    margin-right: 16px;
    border-radius: 50%;
    background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'%3E%3Cdefs%3E%3ClinearGradient id='g' x1='0' y1='0' x2='1' y2='1'%3E%3Cstop stop-color='%23ffd12e'/%3E%3Cstop offset='1' stop-color='%23ff7f27'/%3E%3C/linearGradient%3E%3C/defs%3E%3Ccircle cx='50' cy='50' r='49' fill='url(%23g)'/%3E%3Cg fill='none' stroke='white' stroke-width='4' stroke-linecap='round' stroke-linejoin='round'%3E%3Cpath d='M2 25h20l10-10h10'/%3E%3Ccircle cx='47' cy='15' r='4'/%3E%3Cpath d='M2 38h33'/%3E%3Ccircle cx='41' cy='38' r='4'/%3E%3Cpath d='M2 51h25l11 11h11'/%3E%3Ccircle cx='55' cy='62' r='4'/%3E%3Cpath d='M2 64h17l12 12h9'/%3E%3Ccircle cx='46' cy='76' r='4'/%3E%3Cpath d='M2 77h10'/%3E%3Ccircle cx='18' cy='77' r='4'/%3E%3C/g%3E%3C/svg%3E");
    background-size: cover;
    background-position: center;
    box-shadow: 0 8px 24px rgba(245,130,32,.24);
}

.login-logo .logo {
    margin: 0 !important;
    padding: 0 !important;
    max-height: none !important;
    color: var(--ddm-graphite) !important;
    font-size: 32px !important;
    font-weight: 650;
    line-height: 1.08;
}

.login {
    width: 520px !important;
    border: 0 !important;
    border-radius: 12px !important;
    overflow: hidden;
    box-shadow: 0 12px 36px rgba(34,40,49,.12);
}

.login .panel-body {
    background: #fff !important;
    padding: 34px !important;
}

.login .form-control {
    height: 44px;
    border-radius: 7px;
    border-color: #d9dde2;
    box-shadow: none;
}

.login .form-control:focus {
    border-color: var(--ddm-orange);
    box-shadow: 0 0 0 3px rgba(245,130,32,.12);
}

.btn-default,
.btn-primary {
    background: var(--ddm-orange) !important;
    border-color: var(--ddm-orange) !important;
    color: #fff !important;
    border-radius: 7px !important;
}

.btn-default:hover,
.btn-default:focus,
.btn-primary:hover,
.btn-primary:focus {
    background: var(--ddm-orange-dark) !important;
    border-color: var(--ddm-orange-dark) !important;
    color: #fff !important;
}

a,
.action-link {
    color: var(--ddm-orange) !important;
}

.login-footer {
    border-top: 0 !important;
    color: var(--ddm-muted) !important;
    background: transparent !important;
}

.panel-danger > .panel-heading {
    background-color: #fff1ed !important;
    color: #a64222 !important;
    border-color: #ffd4c7 !important;
}

@media (max-width: 600px) {
    .login {
        width: calc(100% - 28px) !important;
    }

    .login-logo {
        width: calc(100% - 28px);
        margin-top: 32px !important;
    }

    .login-logo::before {
        width: 58px;
        height: 58px;
        min-width: 58px;
    }

    .login-logo .logo {
        font-size: 26px !important;
    }
}
CSS

python3 - "$INDEX" <<'PYHTML'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

text = re.sub(
    r"<title>.*?</title>",
    "<title>DDM Gestão Móvel</title>",
    text,
    count=1,
    flags=re.I | re.S,
)

text = re.sub(
    r"\s*<link[^>]+href=['\"]css/ddm-branding\.css[^>]*>\s*",
    "\n",
    text,
    flags=re.I,
)

branding_link = (
    "\n    <link rel='stylesheet' type='text/css' "
    "href='css/ddm-branding.css?v=1'>"
)

needle = "<link rel='stylesheet' type='text/css' href='css/main.css'>"
if needle not in text:
    raise SystemExit("Não encontrei o link css/main.css no index.html")

text = text.replace(needle, needle + branding_link, 1)

text = re.sub(
    r'<link\s+href="images/favicon\.ico"\s+rel="icon"\s+type="image/x-icon"\s*/>',
    """<link rel="icon" type="image/svg+xml" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'%3E%3Cdefs%3E%3ClinearGradient id='g' x1='0' y1='0' x2='1' y2='1'%3E%3Cstop stop-color='%23ffd12e'/%3E%3Cstop offset='1' stop-color='%23ff7f27'/%3E%3C/linearGradient%3E%3C/defs%3E%3Ccircle cx='32' cy='32' r='30' fill='url(%23g)'/%3E%3Ctext x='32' y='40' text-anchor='middle' font-family='Arial,sans-serif' font-size='24' font-weight='700' fill='white'%3EDDM%3C/text%3E%3C/svg%3E'>""",
    text,
    count=1,
    flags=re.I,
)

marker = "ddmBrandingV1"
if marker not in text:
    script = """\n    <script>
    if (document.cookie.indexOf('ddmBrandingV1=1') === -1) {
        document.cookie = 'rebranding=; Max-Age=0; path=/';
        document.cookie = 'ddmBrandingV1=1; Max-Age=31536000; path=/; SameSite=Lax';
    }
    </script>"""
    text = text.replace("</head>", script + "\n</head>", 1)

path.write_text(text, encoding="utf-8")
PYHTML

chown root:tomcat "$CSS" "$INDEX"
chmod 0644 "$CSS" "$INDEX"

echo
echo "Validando..."
python3 -c 'import xml.etree.ElementTree as ET; ET.parse("/var/lib/tomcat9/conf/Catalina/localhost/ROOT.xml"); print("ROOT.xml: OK")'
grep -q 'DDM Gestão Móvel' "$INDEX" || fail "título DDM não encontrado"
grep -q 'ddm-branding.css' "$INDEX" || fail "CSS DDM não referenciado"
[[ -s "$CSS" ]] || fail "CSS DDM vazio"

NAME_JSON="$(curl -fsS http://127.0.0.1:8080/rest/public/name)"
echo "Rebranding API: $NAME_JSON"
printf '%s' "$NAME_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("status")=="OK"; assert d.get("data",{}).get("appName")=="DDM Gestão Móvel"' \
    || fail "API ainda não retornou DDM Gestão Móvel"

HTTP="$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/)"
HTTPS="$(curl -sS --resolve "${FQDN}:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://${FQDN}/")"

[[ "$HTTP" =~ ^(200|301|302)$ ]] || fail "HTTP local inesperado: $HTTP"
[[ "$HTTPS" =~ ^(200|301|302)$ ]] || fail "HTTPS local inesperado: $HTTPS"

echo
echo "============================================================"
echo " DDM GESTÃO MÓVEL - BRANDING APLICADO"
echo "============================================================"
echo "URL       : ${PUBLIC_URL}"
echo "HTTP      : ${HTTP}"
echo "HTTPS     : ${HTTPS}"
echo "Nome      : DDM Gestão Móvel"
echo "Fornecedor: DDMTI Soluções"
echo "Backup    : ${BACKUP}"
echo "============================================================"
