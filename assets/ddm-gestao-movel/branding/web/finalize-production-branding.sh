#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

BASE="/home/suporte"
TOMCAT_BASE="/var/lib/tomcat9"
CTX="${TOMCAT_BASE}/conf/Catalina/localhost/ROOT.xml"
WEBROOT="${TOMCAT_BASE}/webapps/ROOT"
MAINCSS="${WEBROOT}/css/main.css"
BRAND_DIR="${TOMCAT_BASE}/work/ddm-branding"
LOGO="${BRAND_DIR}/ddm-login-icon.png"
ASSET_B64="https://raw.githubusercontent.com/bkpcloud-app/snoc/main/assets/ddm-gestao-movel/branding/web/ddm-login-icon.png.b64"
FQDN="mobgw.bkpcloud.app.br"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${BASE}/DDM-MDM-FINAL-BRANDING-BACKUP-${STAMP}"
TMP_B64="/tmp/ddm-login-icon-${STAMP}.b64"
TMP_PNG="/tmp/ddm-login-icon-${STAMP}.png"

fail() {
    echo "ERRO: $*" >&2
    exit 1
}

wait_port() {
    local port="$1" timeout="$2" i
    for ((i=0; i<timeout; i++)); do
        ss -H -lnt "sport = :${port}" | grep -q . && return 0
        sleep 1
    done
    return 1
}

cleanup() {
    rm -f "$TMP_B64" "$TMP_PNG"
}
trap cleanup EXIT

[[ "$(id -u)" -eq 0 ]] || fail "execute como root"
[[ -s "$CTX" ]] || fail "ROOT.xml ausente: $CTX"
[[ -s "$MAINCSS" ]] || fail "main.css ausente: $MAINCSS"
command -v curl >/dev/null || fail "curl ausente"
command -v python3 >/dev/null || fail "python3 ausente"
command -v base64 >/dev/null || fail "base64 ausente"
systemctl is-active --quiet tomcat9 || fail "tomcat9 inativo"
systemctl is-active --quiet nginx || fail "nginx inativo"

# Baixa e valida o ativo antes de alterar qualquer configuração.
curl -fsSL "$ASSET_B64" -o "$TMP_B64"
base64 -d "$TMP_B64" > "$TMP_PNG"
python3 - "$TMP_PNG" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
data = p.read_bytes()
if len(data) < 1000 or not data.startswith(b"\x89PNG\r\n\x1a\n"):
    raise SystemExit("PNG DDM inválido")
print(f"Logo DDM: OK ({len(data)} bytes)")
PY

mkdir -p "$BACKUP"
cp -a "$CTX" "$BACKUP/ROOT.xml"
cp -a "$MAINCSS" "$BACKUP/main.css"
[[ -f "$LOGO" ]] && cp -a "$LOGO" "$BACKUP/ddm-login-icon.png" || true

echo "Backup: $BACKUP"

install -d -o tomcat -g tomcat -m 0755 "$BRAND_DIR"
install -o tomcat -g tomcat -m 0644 "$TMP_PNG" "$LOGO"

# Rebranding nativo do Headwind. Não toca em index.html nem em JavaScript.
python3 - "$CTX" "$LOGO" <<'PY'
import sys
import xml.etree.ElementTree as ET

path, logo = sys.argv[1:]
tree = ET.parse(path)
root = tree.getroot()

values = {
    "base.url": "https://mobgw.bkpcloud.app.br",
    "swagger.host": "mobgw.bkpcloud.app.br",
    "mqtt.server.uri": "mobgw.bkpcloud.app.br:31000",
    "rebranding.name": "DDM Gestão Móvel",
    "rebranding.vendor.name": "DDMTI Soluções",
    "rebranding.vendor.link": "#",
    "rebranding.logo": logo,
    "rebranding.mobile.name": "DDM Gestão Móvel",
}

params = {p.get("name"): p for p in root.findall("Parameter") if p.get("name")}
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

for name, expected in values.items():
    actual = params[name].get("value")
    if actual != expected:
        raise SystemExit(f"Falha em {name}: {actual!r}")
    print(f"{name}={actual}")
PY

# Remove qualquer bloco DDM anterior e aplica somente CSS seguro no main.css já nativo.
python3 - "$MAINCSS" <<'PY'
from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")

patterns = [
    ("/* === DDM GESTAO MOVEL - INICIO === */", "/* === DDM GESTAO MOVEL - FIM === */"),
    ("/* === DDM GESTAO MOVEL - PRODUCAO - INICIO === */", "/* === DDM GESTAO MOVEL - PRODUCAO - FIM === */"),
]
for start, end in patterns:
    s = re.sub(re.escape(start) + r".*?" + re.escape(end), "", s, flags=re.S)

css = r'''

/* === DDM GESTAO MOVEL - PRODUCAO - INICIO === */

body {
    background-color: #f5f6f8 !important;
    color: #30343a;
}

/* Login: identidade discreta e institucional */
.login-logo {
    max-width: 520px !important;
    margin: 48px auto 20px auto !important;
    display: flex !important;
    align-items: center !important;
    justify-content: center !important;
    gap: 16px;
    white-space: normal !important;
}

.login-logo img {
    width: 72px !important;
    height: 72px !important;
    object-fit: contain !important;
    margin: 0 !important;
    padding: 0 !important;
}

.login-logo .logo {
    margin: 0 !important;
    padding: 0 !important;
    max-height: none !important;
    color: #34383d !important;
    font-size: 30px !important;
    font-weight: 600 !important;
    line-height: 1.1 !important;
    letter-spacing: -0.2px;
}

.login {
    width: 500px !important;
    border: 1px solid #e1e4e8 !important;
    border-top: 3px solid #e8842b !important;
    border-radius: 9px !important;
    overflow: hidden;
    box-shadow: 0 10px 28px rgba(24, 31, 38, 0.08) !important;
}

.login .panel-body {
    background: #ffffff !important;
    padding: 32px 38px !important;
}

.login label {
    color: #34383d !important;
    font-weight: 600 !important;
}

.login .form-control {
    height: 43px !important;
    border-color: #d7dbe0 !important;
    border-radius: 6px !important;
    box-shadow: none !important;
}

.login .form-control:focus {
    border-color: #e8842b !important;
    box-shadow: 0 0 0 3px rgba(232, 132, 43, 0.11) !important;
}

.login .btn-default {
    background: #e8842b !important;
    border-color: #e8842b !important;
    color: #ffffff !important;
    border-radius: 6px !important;
    font-weight: 600 !important;
    padding: 8px 24px !important;
    box-shadow: none !important;
}

.login .btn-default:hover,
.login .btn-default:focus,
.login .btn-default:active {
    background: #d87420 !important;
    border-color: #d87420 !important;
    color: #ffffff !important;
}

.login .action-link {
    color: #cf721f !important;
}

.login .action-link:hover,
.login .action-link:focus {
    color: #ad5d18 !important;
}

/* Rodapé comercial: remove o texto genérico da plataforma sem alterar o HTML */
.login-footer {
    border-top: 1px solid #e7e9ec !important;
    background: #ffffff !important;
    color: #747980 !important;
    font-size: 13px !important;
    padding-top: 11px !important;
}

.login-footer > * {
    display: none !important;
}

.login-footer::after {
    content: "DDM Gestão Móvel  •  DDMTI Soluções";
    color: #747980 !important;
}

/* Painel autenticado */
.header {
    background-color: #30343a !important;
    border-color: #30343a !important;
    box-shadow: 0 2px 8px rgba(20, 24, 28, 0.16);
}

.header .logo-text a,
.header .logo-text a:active,
.header .logo-text a:hover,
.header a {
    color: #ffffff !important;
}

.header .logo-text a {
    font-weight: 600 !important;
}

.header .open a,
.header .open .dropdown-menu {
    background-color: #30343a !important;
}

.header .open .dropdown-menu a:hover {
    background-color: #41474e !important;
}

.btn-primary {
    background-color: #e8842b !important;
    border-color: #e8842b !important;
    color: #ffffff !important;
}

.btn-primary:hover,
.btn-primary:focus,
.btn-primary:active {
    background-color: #d87420 !important;
    border-color: #d87420 !important;
}

.nav-tabs > li.active > a,
.nav-tabs > li.active > a:hover,
.nav-tabs > li.active > a:focus {
    border-top: 3px solid #e8842b !important;
}

@media (max-width: 600px) {
    .login {
        width: calc(100% - 28px) !important;
    }

    .login-logo {
        width: calc(100% - 28px) !important;
        margin-top: 30px !important;
        gap: 12px;
    }

    .login-logo img {
        width: 58px !important;
        height: 58px !important;
    }

    .login-logo .logo {
        font-size: 25px !important;
    }
}

/* === DDM GESTAO MOVEL - PRODUCAO - FIM === */
'''

p.write_text(s.rstrip() + css + "\n", encoding="utf-8")
PY

chown root:tomcat "$MAINCSS"
chmod 0644 "$MAINCSS"

# Reinicia apenas porque o rebranding.logo é parâmetro de contexto do Tomcat.
systemctl restart tomcat9
wait_port 8080 180 || {
    journalctl -u tomcat9 -n 120 --no-pager
    cp -a "$BACKUP/ROOT.xml" "$CTX"
    cp -a "$BACKUP/main.css" "$MAINCSS"
    systemctl restart tomcat9 || true
    fail "Tomcat não voltou; ROOT.xml e main.css restaurados"
}

sleep 3

echo
echo "===== VALIDACAO FINAL ====="
python3 -c 'import xml.etree.ElementTree as ET; ET.parse("/var/lib/tomcat9/conf/Catalina/localhost/ROOT.xml"); print("ROOT.xml       : OK")'

grep -q 'DDM GESTAO MOVEL - PRODUCAO - INICIO' "$MAINCSS" || fail "CSS DDM não aplicado"
echo "CSS produção   : OK"

NAME_JSON="$(curl -fsS http://127.0.0.1:8080/rest/public/name)"
printf '%s' "$NAME_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("status")=="OK"; assert d.get("data",{}).get("appName")=="DDM Gestão Móvel"; assert d.get("data",{}).get("vendorName")=="DDMTI Soluções"' \
    || fail "API de rebranding inválida"
echo "Rebranding API : OK"

curl -fsS http://127.0.0.1:8080/rest/public/logo -o /tmp/ddm-logo-check.png
python3 - <<'PY'
from pathlib import Path
p=Path('/tmp/ddm-logo-check.png')
d=p.read_bytes()
assert d.startswith(b'\x89PNG\r\n\x1a\n') and len(d) > 1000
print(f"Logo API       : OK ({len(d)} bytes)")
p.unlink(missing_ok=True)
PY

HTTP="$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/)"
LOGIN="$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/app/components/main/view/login.html)"
HTTPS="$(curl -sS --resolve "${FQDN}:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://${FQDN}/")"

[[ "$HTTP" == "200" ]] || fail "index Tomcat HTTP=$HTTP"
[[ "$LOGIN" == "200" ]] || fail "login.html HTTP=$LOGIN"
[[ "$HTTPS" =~ ^(200|301|302)$ ]] || fail "HTTPS Nginx HTTP=$HTTPS"

echo "Index Tomcat   : HTTP $HTTP"
echo "Login template : HTTP $LOGIN"
echo "HTTPS Nginx    : HTTP $HTTPS"

echo
echo "============================================================"
echo " DDM GESTAO MOVEL - BRANDING FINAL DE PRODUCAO APLICADO"
echo "============================================================"
echo "URL        : https://${FQDN}/#/login"
echo "Nome       : DDM Gestão Móvel"
echo "Fornecedor : DDMTI Soluções"
echo "HTTPS      : 443"
echo "MQTT       : 31000"
echo "Backup     : ${BACKUP}"
echo "index.html : NAO ALTERADO"
echo "JavaScript : NAO ALTERADO"
echo "============================================================"
