#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

VERSION="2026.08.07.5"

BASE="${BC_BASE:-/home/suporte}"
FQDN="mobgw.bkpcloud.app.br"
TOMCAT="${BC_TOMCAT:-/var/lib/tomcat9}"
CTX="$TOMCAT/conf/Catalina/localhost/ROOT.xml"
WEB="$TOMCAT/webapps/ROOT"
CSS="$WEB/css/main.css"
ASSETS="$WEB/images/backup-cloud"
LOGO="$ASSETS/backup-cloud-logo.png"
HERO="$ASSETS/gestao-movel-login-hero.jpg"
ICON="$ASSETS/backup-cloud-icon.png"
FAVICON="$WEB/images/favicon.ico"

RAW="${BC_RAW_BASE:-https://raw.githubusercontent.com/bkpcloud-app/snoc/main/assets/backup-cloud/gestao-movel/branding/web}"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BASE/BACKUP-CLOUD-GESTAO-MOVEL-BRANDING-BACKUP-$STAMP"
TMP="$(mktemp -d /tmp/bc-mdm-branding.XXXXXX)"
CHANGED=0

cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

wait8080() {
  local i
  for i in $(seq 1 90); do
    if ss -H -lnt 'sport = :8080' 2>/dev/null | grep -q .; then
      return 0
    fi
    sleep 1
  done
  return 1
}

rollback() {
  CHANGED=0
  echo
  echo "ROLLBACK: restaurando $BACKUP"

  cp -a "$BACKUP/ROOT.xml" "$CTX"
  cp -a "$BACKUP/main.css" "$CSS"

  if [[ -f "$BACKUP/favicon.ico" ]]; then
    cp -a "$BACKUP/favicon.ico" "$FAVICON"
  fi

  rm -rf "$ASSETS"
  if [[ -d "$BACKUP/backup-cloud-assets" ]]; then
    cp -a "$BACKUP/backup-cloud-assets" "$ASSETS"
  fi

  systemctl restart tomcat9 || true
  wait8080 || true
  echo "ROLLBACK concluído."
}

die() {
  echo "ERRO: $*" >&2
  if [[ "$CHANGED" -eq 1 && -d "$BACKUP" ]]; then
    rollback
  fi
  exit 1
}

on_error() {
  local rc=$?
  if [[ "$CHANGED" -eq 1 && -d "$BACKUP" ]]; then
    rollback
  fi
  exit "$rc"
}
trap on_error ERR

[[ "$(id -u)" -eq 0 ]] || die "execute como root"

for c in curl python3 ss systemctl grep install cp rm mkdir; do
  command -v "$c" >/dev/null 2>&1 || die "$c ausente"
done

[[ -s "$CTX" ]] || die "ROOT.xml ausente: $CTX"
[[ -s "$CSS" ]] || die "main.css ausente: $CSS"
systemctl is-active --quiet tomcat9 || die "tomcat9 inativo"
systemctl is-active --quiet nginx || die "nginx inativo"

echo "============================================================"
echo " BACKUP CLOUD | GESTÃO MÓVEL"
echo " Instalador de branding: $VERSION"
echo "============================================================"
echo "[1/6] Baixando e validando ativos (nenhuma alteração ainda)"

decode_asset() {
  local url="$1"
  local out="$2"
  local kind="$3"
  local expected_sha="$4"
  local txt="$TMP/$(basename "$out").b64"

  echo " - $(basename "$out")"

  curl -fL \
    --retry 3 \
    --retry-delay 1 \
    --connect-timeout 10 \
    --max-time 90 \
    -sS \
    "$url" \
    -o "$txt" || die "falha ao baixar: $url"

  python3 - "$txt" "$out" "$kind" "$expected_sha" <<'PY'
from pathlib import Path
import base64
import hashlib
import re
import sys

src = Path(sys.argv[1])
out = Path(sys.argv[2])
kind = sys.argv[3]
expected_sha = sys.argv[4]

try:
    text = src.read_text(encoding="ascii")
except Exception as exc:
    raise SystemExit(f"arquivo base64 não é ASCII válido: {exc}")

payload = re.sub(r"\s+", "", text)

if not payload:
    raise SystemExit("arquivo base64 vazio")

try:
    data = base64.b64decode(payload, validate=True)
except Exception as exc:
    raise SystemExit(f"base64 inválido: {exc}")

digest = hashlib.sha256(data).hexdigest()
if digest != expected_sha:
    raise SystemExit(
        f"SHA-256 divergente: {digest} != {expected_sha}"
    )

if kind == "png":
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise SystemExit("assinatura PNG inválida")
    if not data.endswith(b"IEND\xaeB`\x82"):
        raise SystemExit("PNG incompleto")
elif kind == "jpg":
    if not data.startswith(b"\xff\xd8\xff"):
        raise SystemExit("assinatura JPEG inválida")
    if not data.endswith(b"\xff\xd9"):
        raise SystemExit("JPEG incompleto")
else:
    raise SystemExit(f"tipo não suportado: {kind}")

out.write_bytes(data)
print(f"   OK | {len(data)} bytes | SHA256 {digest[:12]}...")
PY
}

decode_asset \
  "$RAW/backup-cloud-logo-dark-transparent.png.b64" \
  "$TMP/logo.png" \
  png \
  "dfda9dec257ea683f9b3ed5a6fe0e56bdb275f20a4fe27d719b0a28b409ed704"

decode_asset \
  "$RAW/gestao-movel-login-hero.jpg.b64" \
  "$TMP/hero.jpg" \
  jpg \
  "944107da6f8b097ab45c5b86f9840ace45fc4bc4c674d5b25d948183ebcb0ce9"

decode_asset \
  "$RAW/backup-cloud-icon.png.b64" \
  "$TMP/icon.png" \
  png \
  "7c0cf9a4a969a9b0b123921d684cfaaa14bfbf2a6c4b00496fb34874b8d9668f"

python3 - "$TMP/icon.png" "$TMP/favicon.ico" <<'PY'
from pathlib import Path
import struct
import sys

icon_path = Path(sys.argv[1])
favicon_path = Path(sys.argv[2])
data = icon_path.read_bytes()

if not data.startswith(b"\x89PNG\r\n\x1a\n") or len(data) < 24:
    raise SystemExit("ícone PNG inválido para favicon")

width, height = struct.unpack(">II", data[16:24])

entry = struct.pack(
    "<BBBBHHII",
    0 if width >= 256 else width,
    0 if height >= 256 else height,
    0,
    0,
    1,
    32,
    len(data),
    22,
)

favicon = struct.pack("<HHH", 0, 1, 1) + entry + data
favicon_path.write_bytes(favicon)

if favicon[:4] != b"\x00\x00\x01\x00" or len(favicon) < 1000:
    raise SystemExit("favicon gerado inválido")

print(f" - favicon.ico: OK | {len(favicon)} bytes")
PY

echo "[2/6] Criando backup"
mkdir -p "$BACKUP"
cp -a "$CTX" "$BACKUP/ROOT.xml"
cp -a "$CSS" "$BACKUP/main.css"

if [[ -f "$FAVICON" ]]; then
  cp -a "$FAVICON" "$BACKUP/favicon.ico"
fi

if [[ -d "$ASSETS" ]]; then
  cp -a "$ASSETS" "$BACKUP/backup-cloud-assets"
fi

echo " - Backup: $BACKUP"

echo "[3/6] Instalando ativos"
install -d -o tomcat -g tomcat -m 0755 "$ASSETS"
install -o root -g tomcat -m 0644 "$TMP/logo.png" "$LOGO"
install -o root -g tomcat -m 0644 "$TMP/hero.jpg" "$HERO"
install -o root -g tomcat -m 0644 "$TMP/icon.png" "$ICON"
install -o root -g tomcat -m 0644 "$TMP/favicon.ico" "$FAVICON"
CHANGED=1

echo "[4/6] Aplicando marca e identidade visual"

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
    "rebranding.name": "Gestão Móvel",
    "rebranding.vendor.name": "Backup Cloud",
    "rebranding.vendor.link": "#",
    "rebranding.logo": logo,
    "rebranding.mobile.name": "Gestão Móvel",
}

params = {
    node.get("name"): node
    for node in root.findall("Parameter")
    if node.get("name")
}

for name, value in values.items():
    node = params.get(name)
    if node is None:
        node = ET.SubElement(root, "Parameter")
        node.set("name", name)
        params[name] = node
    node.set("value", value)

if hasattr(ET, "indent"):
    ET.indent(tree, space="    ")

tree.write(path, encoding="UTF-8", xml_declaration=True)

check = ET.parse(path).getroot()
saved = {
    node.get("name"): node.get("value")
    for node in check.findall("Parameter")
    if node.get("name")
}

for name, expected in values.items():
    actual = saved.get(name)
    if actual != expected:
        raise SystemExit(
            f"falha ao gravar {name}: esperado={expected!r} atual={actual!r}"
        )
    print(f" - {name}={actual}")
PY

python3 - "$CSS" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

blocks = [
    ("/* === DDM GESTAO MOVEL - INICIO === */", "/* === DDM GESTAO MOVEL - FIM === */"),
    ("/* === DDM GESTAO MOVEL - PRODUCAO - INICIO === */", "/* === DDM GESTAO MOVEL - PRODUCAO - FIM === */"),
    ("/* === DDM POLIMENTO PRODUCAO - INICIO === */", "/* === DDM POLIMENTO PRODUCAO - FIM === */"),
    ("/* === BACKUP CLOUD GESTAO MOVEL - INICIO === */", "/* === BACKUP CLOUD GESTAO MOVEL - FIM === */"),
]

for start, end in blocks:
    text = re.sub(
        re.escape(start) + r".*?" + re.escape(end),
        "",
        text,
        flags=re.S,
    )

branding = r"""
/* === BACKUP CLOUD GESTAO MOVEL - INICIO === */
:root{
  --bc-navy:#0B1323;
  --bc-dark:#111827;
  --bc-purple:#3E4095;
  --bc-purple2:#5659C7;
  --bc-blue:#2563EB;
  --bc-white:#FFFFFF;
}

body{
  background:#f3f4f6!important;
  color:#1f2937;
}

.header{
  background:linear-gradient(90deg,var(--bc-navy),var(--bc-dark) 58%,#171a35)!important;
  border-color:var(--bc-navy)!important;
  box-shadow:0 2px 12px rgba(4,9,20,.24)!important;
}

.header a,
.header .logo-text a{
  color:#fff!important;
}

.header .logo-text a{
  font-weight:600!important;
}

.btn-primary,
.login .btn-default{
  background:linear-gradient(90deg,var(--bc-blue),var(--bc-purple2))!important;
  border-color:var(--bc-blue)!important;
  color:#fff!important;
  border-radius:7px!important;
  font-weight:600!important;
}

.btn-primary:hover,
.btn-primary:focus,
.btn-primary:active,
.login .btn-default:not([disabled]):hover,
.login .btn-default:not([disabled]):focus,
.login .btn-default:not([disabled]):active{
  background:linear-gradient(90deg,#1d4ed8,var(--bc-purple))!important;
  border-color:#1d4ed8!important;
  color:#fff!important;
}

a,
.action-link,
.login .action-link{
  color:var(--bc-blue)!important;
}

.login-logo{
  max-width:660px!important;
  margin:44px auto 17px!important;
  display:flex!important;
  flex-direction:column!important;
  align-items:center!important;
  gap:8px!important;
  position:relative!important;
  z-index:2!important;
}

.login-logo img{
  width:330px!important;
  height:auto!important;
  max-height:150px!important;
  object-fit:contain!important;
  margin:0!important;
  filter:drop-shadow(0 7px 22px rgba(0,0,0,.25));
}

.login-logo .logo{
  color:#f8fafc!important;
  font-size:26px!important;
  font-weight:500!important;
  text-shadow:0 2px 10px rgba(0,0,0,.4);
}

.login-logo::before{
  content:"";
  position:fixed;
  inset:0;
  z-index:-1;
  background:
    linear-gradient(90deg,rgba(6,13,27,.16),rgba(6,13,27,.48) 48%,rgba(6,13,27,.94) 76%),
    url('../images/backup-cloud/gestao-movel-login-hero.jpg') center center/cover no-repeat,
    var(--bc-navy);
}

.login-logo::after{
  content:"Backup Cloud  •  Gestão Móvel";
  color:#cbd5e1;
  font-size:13px;
  letter-spacing:.35px;
}

.login{
  width:480px!important;
  border:1px solid rgba(148,163,184,.18)!important;
  border-top:2px solid var(--bc-purple2)!important;
  border-radius:12px!important;
  overflow:hidden!important;
  position:relative!important;
  z-index:2!important;
  box-shadow:0 22px 58px rgba(0,0,0,.34)!important;
}

.login .panel-body{
  background:rgba(17,24,39,.94)!important;
  padding:31px 36px!important;
}

.login label{
  color:#e5e7eb!important;
  font-weight:500!important;
}

.login .form-control{
  height:43px!important;
  color:#f8fafc!important;
  background:rgba(9,16,30,.86)!important;
  border-color:#334155!important;
  border-radius:7px!important;
  box-shadow:none!important;
}

.login .form-control::placeholder{
  color:#7f8da3!important;
}

.login .form-control:focus{
  border-color:var(--bc-blue)!important;
  box-shadow:0 0 0 3px rgba(37,99,235,.17)!important;
}

.login-footer{
  position:relative!important;
  z-index:2!important;
  border-top:0!important;
  background:transparent!important;
  color:#9ca3af!important;
  font-size:12px!important;
}

.login-footer>*{
  display:none!important;
}

.login-footer::after{
  content:"Backup Cloud  •  Gestão Móvel"!important;
  color:#9ca3af!important;
}

@media(max-width:760px){
  .login-logo{
    width:calc(100% - 28px)!important;
    margin-top:28px!important;
  }

  .login-logo img{
    width:min(310px,82vw)!important;
  }

  .login{
    width:calc(100% - 28px)!important;
    margin:auto!important;
  }

  .login .panel-body{
    padding:25px 22px!important;
  }
}
/* === BACKUP CLOUD GESTAO MOVEL - FIM === */
"""

path.write_text(
    text.rstrip() + "\n\n" + branding.strip() + "\n",
    encoding="utf-8",
)

saved = path.read_text(encoding="utf-8")

if saved.count("/* === BACKUP CLOUD GESTAO MOVEL - INICIO === */") != 1:
    raise SystemExit("bloco Backup Cloud duplicado ou ausente")

if "DDM GESTAO MOVEL - INICIO" in saved or "DDM POLIMENTO PRODUCAO - INICIO" in saved:
    raise SystemExit("bloco visual antigo DDM ainda presente")

print(" - CSS Backup Cloud aplicado e validado")
PY

echo "[5/6] Reiniciando Tomcat e validando aplicação"

systemctl restart tomcat9

if ! wait8080; then
  die "Tomcat não abriu a porta 8080 em 90 segundos"
fi

HTTP_CODE="$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/ || true)"

case "$HTTP_CODE" in
  200|301|302|303|307|308|401|403)
    ;;
  *)
    die "HTTP local inválido após reinício: ${HTTP_CODE:-sem resposta}"
    ;;
esac

systemctl is-active --quiet tomcat9 || die "tomcat9 ficou inativo"
systemctl is-active --quiet nginx || die "nginx ficou inativo"

echo "[6/6] Conferência final"

python3 - "$CTX" "$CSS" "$LOGO" "$HERO" "$ICON" "$FAVICON" <<'PY'
from pathlib import Path
import hashlib
import sys
import xml.etree.ElementTree as ET

ctx, css, logo, hero, icon, favicon = map(Path, sys.argv[1:])

expected_hashes = {
    logo: "dfda9dec257ea683f9b3ed5a6fe0e56bdb275f20a4fe27d719b0a28b409ed704",
    hero: "944107da6f8b097ab45c5b86f9840ace45fc4bc4c674d5b25d948183ebcb0ce9",
    icon: "7c0cf9a4a969a9b0b123921d684cfaaa14bfbf2a6c4b00496fb34874b8d9668f",
}

for path, expected in expected_hashes.items():
    if not path.is_file():
        raise SystemExit(f"asset ausente: {path}")
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if digest != expected:
        raise SystemExit(f"asset alterado/corrompido: {path}")
    print(f" - {path.name}: SHA256 OK")

if not favicon.is_file() or favicon.stat().st_size < 1000:
    raise SystemExit("favicon ausente ou inválido")

if favicon.read_bytes()[:4] != b"\x00\x00\x01\x00":
    raise SystemExit("favicon sem assinatura ICO")

print(" - favicon.ico: OK")

root = ET.parse(ctx).getroot()
params = {
    node.get("name"): node.get("value")
    for node in root.findall("Parameter")
    if node.get("name")
}

required = {
    "rebranding.name": "Gestão Móvel",
    "rebranding.vendor.name": "Backup Cloud",
    "rebranding.logo": str(logo),
}

for name, expected in required.items():
    actual = params.get(name)
    if actual != expected:
        raise SystemExit(f"configuração inválida {name}={actual!r}")

content = css.read_text(encoding="utf-8")
if content.count("/* === BACKUP CLOUD GESTAO MOVEL - INICIO === */") != 1:
    raise SystemExit("CSS Backup Cloud inválido")

print(" - ROOT.xml: branding OK")
print(" - main.css: branding OK")
PY

CHANGED=0

echo "============================================================"
echo " SUCESSO"
echo " Produto : Gestão Móvel"
echo " Marca   : Backup Cloud"
echo " URL     : https://$FQDN"
echo " HTTP    : $HTTP_CODE"
echo " Backup  : $BACKUP"
echo " Versão  : $VERSION"
echo "============================================================"
