#!/usr/bin/env bash
set -euo pipefail
umask 022

VERSION="2026.08.07.7"

BASE="${BC_BASE:-/home/suporte}"
TOMCAT="${BC_TOMCAT:-/var/lib/tomcat9}"
CTX="$TOMCAT/conf/Catalina/localhost/ROOT.xml"
WEB="$TOMCAT/webapps/ROOT"
CSS="$WEB/css/main.css"
ASSETS="$WEB/images/backup-cloud"
LOGO="$ASSETS/backup-cloud-logo.png"
RAW="${BC_RAW_BASE:-https://raw.githubusercontent.com/bkpcloud-app/snoc/main/assets/backup-cloud/gestao-movel/branding/web}"
TEST_MODE="${BC_TEST_MODE:-0}"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BASE/BACKUP-CLOUD-GESTAO-MOVEL-BRANDING-BACKUP-$STAMP"
TMP="$(mktemp -d /tmp/bc-mdm-branding.XXXXXX)"

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

fail() { echo "ERRO: $*" >&2; exit 1; }

rollback() {
  echo "ROLLBACK: restaurando backup..."
  [ -f "$BACKUP/ROOT.xml" ] && cp -a "$BACKUP/ROOT.xml" "$CTX"
  [ -f "$BACKUP/main.css" ] && cp -a "$BACKUP/main.css" "$CSS"
  rm -rf "$ASSETS"
  [ -d "$BACKUP/backup-cloud-assets" ] && cp -a "$BACKUP/backup-cloud-assets" "$ASSETS"
  if [ "$TEST_MODE" != "1" ]; then
    systemctl restart tomcat9 >/dev/null 2>&1 || true
  fi
  echo "ROLLBACK concluído."
}

need() { command -v "$1" >/dev/null 2>&1 || fail "comando ausente: $1"; }

decode_logo() {
  local url="$1"
  local out="$2"
  local src="$TMP/logo.b64"

  curl -fLsS --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 90 "$url" -o "$src" \
    || fail "não foi possível baixar o logo Backup Cloud"

  python3 - "$src" "$out" <<'PY'
from pathlib import Path
import base64
import re
import struct
import sys

src = Path(sys.argv[1])
out = Path(sys.argv[2])

try:
    text = src.read_text(encoding="ascii")
except Exception as exc:
    raise SystemExit(f"logo não é texto Base64 válido: {exc}")

payload = re.sub(r"\s+", "", text)
if len(payload) < 100:
    raise SystemExit("logo Base64 vazio ou incompleto")
if not re.fullmatch(r"[A-Za-z0-9+/]*={0,2}", payload):
    raise SystemExit("logo Base64 contém caracteres inválidos")

# Corrige somente padding ausente. Qualquer corrupção real é barrada pelos testes PNG abaixo.
payload += "=" * ((-len(payload)) % 4)

try:
    data = base64.b64decode(payload, validate=True)
except Exception as exc:
    raise SystemExit(f"falha ao decodificar logo: {exc}")

signature = b"\x89PNG\r\n\x1a\n"
if not data.startswith(signature):
    raise SystemExit("logo decodificado não é PNG")
if len(data) < 33 or data[12:16] != b"IHDR":
    raise SystemExit("PNG sem IHDR válido")
width, height = struct.unpack(">II", data[16:24])
if width < 100 or height < 30:
    raise SystemExit(f"dimensão inesperada do logo: {width}x{height}")
if b"IEND" not in data[-32:]:
    raise SystemExit("PNG incompleto: IEND ausente")

out.write_bytes(data)
print(f"   Logo OK: {width}x{height} | {len(data)} bytes")
PY
}

if [ "$TEST_MODE" != "1" ]; then
  [ "$(id -u)" = "0" ] || fail "execute como root"
fi

for c in curl python3 cp rm mkdir install; do need "$c"; done
[ -s "$CTX" ] || fail "arquivo não encontrado: $CTX"
[ -s "$CSS" ] || fail "arquivo não encontrado: $CSS"

if [ "$TEST_MODE" != "1" ]; then
  need systemctl
  systemctl is-active --quiet tomcat9 || fail "tomcat9 não está ativo"
  systemctl is-active --quiet nginx || fail "nginx não está ativo"
fi

echo "============================================================"
echo " BACKUP CLOUD | GESTÃO MÓVEL"
echo " Instalador: $VERSION"
echo "============================================================"

echo "[1/5] Pré-validando logo - nenhuma alteração no servidor"
decode_logo "$RAW/backup-cloud-logo-dark-transparent.png.b64" "$TMP/logo.png"

echo "[2/5] Validando configuração atual"
python3 - "$CTX" <<'PY'
import sys
import xml.etree.ElementTree as ET
ET.parse(sys.argv[1])
print("   ROOT.xml: XML válido")
PY

echo "[3/5] Criando backup"
mkdir -p "$BACKUP"
cp -a "$CTX" "$BACKUP/ROOT.xml"
cp -a "$CSS" "$BACKUP/main.css"
[ -d "$ASSETS" ] && cp -a "$ASSETS" "$BACKUP/backup-cloud-assets"
echo "   $BACKUP"

echo "[4/5] Aplicando identidade Backup Cloud"
install -d -m 0755 "$ASSETS"
install -m 0644 "$TMP/logo.png" "$LOGO"

if ! python3 - "$CTX" <<'PY'
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

values = {
    "rebranding.name": "Gestão Móvel",
    "rebranding.vendor.name": "Backup Cloud",
    "rebranding.logo": "/images/backup-cloud/backup-cloud-logo.png",
    "rebranding.mobile.name": "Gestão Móvel",
}

def replace_value(match, value):
    tag = match.group(0)
    if re.search(r'\bvalue\s*=\s*["\'][^"\']*["\']', tag):
        return re.sub(
            r'(\bvalue\s*=\s*)["\'][^"\']*["\']',
            lambda m: m.group(1) + '"' + value + '"',
            tag,
            count=1,
        )
    close = "/>" if tag.rstrip().endswith("/>") else ">"
    body = tag.rstrip()
    body = body[:-2] if close == "/>" else body[:-1]
    return body + ' value="' + value + '"' + close

for name, value in values.items():
    pattern = re.compile(
        r'<Parameter\b(?=[^>]*\bname\s*=\s*["\']' + re.escape(name) + r'["\'])[^>]*?/?>',
        re.I,
    )
    if pattern.search(text):
        text = pattern.sub(lambda m, v=value: replace_value(m, v), text, count=1)
    else:
        new = f'    <Parameter name="{name}" value="{value}" override="false"/>\n'
        if "</Context>" not in text:
            raise SystemExit("ROOT.xml sem fechamento </Context>")
        text = text.replace("</Context>", new + "</Context>", 1)

path.write_text(text, encoding="utf-8")
ET.parse(path)
print("   Rebranding nativo: OK")
PY
then
  rollback
  fail "falha ao aplicar rebranding; backup restaurado"
fi

if ! python3 - "$CSS" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="ignore")

markers = [
    ("/* === DDM GESTAO MOVEL - INICIO === */", "/* === DDM GESTAO MOVEL - FIM === */"),
    ("/* === DDM GESTAO MOVEL - PRODUCAO - INICIO === */", "/* === DDM GESTAO MOVEL - PRODUCAO - FIM === */"),
    ("/* === DDM POLIMENTO PRODUCAO - INICIO === */", "/* === DDM POLIMENTO PRODUCAO - FIM === */"),
    ("/* === BACKUP CLOUD GESTAO MOVEL - INICIO === */", "/* === BACKUP CLOUD GESTAO MOVEL - FIM === */"),
]
for start, end in markers:
    text = re.sub(re.escape(start) + r".*?" + re.escape(end), "", text, flags=re.S)

branding = r'''
/* === BACKUP CLOUD GESTAO MOVEL - INICIO === */
:root{--bc-navy:#0B1323;--bc-dark:#111827;--bc-purple:#3E4095;--bc-purple2:#5659C7;--bc-blue:#2563EB;--bc-slate:#CBD5E1}
.header{background:linear-gradient(90deg,var(--bc-navy),var(--bc-dark) 58%,#171a35)!important;border-color:var(--bc-navy)!important;box-shadow:0 2px 12px rgba(4,9,20,.24)!important}
.header a,.header .logo-text a{color:#fff!important}
.btn-primary,.login .btn-default{background:linear-gradient(90deg,var(--bc-blue),var(--bc-purple2))!important;border-color:var(--bc-blue)!important;color:#fff!important;border-radius:7px!important;font-weight:600!important}
.login-logo{max-width:660px!important;margin:44px auto 17px!important;display:flex!important;flex-direction:column!important;align-items:center!important;gap:8px!important;position:relative!important;z-index:2!important}
.login-logo img{width:330px!important;height:auto!important;max-height:150px!important;object-fit:contain!important;margin:0!important;filter:drop-shadow(0 7px 22px rgba(0,0,0,.25))}
.login-logo .logo{color:#f8fafc!important;font-size:26px!important;font-weight:500!important;text-shadow:0 2px 10px rgba(0,0,0,.4)}
.login-logo::before{content:"";position:fixed;inset:0;z-index:-2;background:radial-gradient(circle at 18% 25%,rgba(86,89,199,.32),transparent 27%),radial-gradient(circle at 76% 72%,rgba(37,99,235,.20),transparent 31%),linear-gradient(125deg,#070d19 0%,#0b1323 42%,#151735 70%,#090d18 100%)}
.login-logo::after{content:"Backup Cloud  •  Gestão Móvel";color:var(--bc-slate);font-size:13px;letter-spacing:.35px}
.login{width:480px!important;border:1px solid rgba(148,163,184,.18)!important;border-top:2px solid var(--bc-purple2)!important;border-radius:12px!important;overflow:hidden!important;position:relative!important;z-index:2!important;box-shadow:0 22px 58px rgba(0,0,0,.34)!important}
.login .panel-body{background:rgba(17,24,39,.94)!important;padding:31px 36px!important}
.login label{color:#e5e7eb!important;font-weight:500!important}
.login .form-control{height:43px!important;color:#f8fafc!important;background:rgba(9,16,30,.86)!important;border-color:#334155!important;border-radius:7px!important;box-shadow:none!important}
.login .form-control:focus{border-color:var(--bc-blue)!important;box-shadow:0 0 0 3px rgba(37,99,235,.17)!important}
@media(max-width:760px){.login-logo{width:calc(100% - 28px)!important;margin-top:28px!important}.login-logo img{width:min(310px,82vw)!important}.login{width:calc(100% - 28px)!important;margin:auto!important}.login .panel-body{padding:25px 22px!important}}
/* === BACKUP CLOUD GESTAO MOVEL - FIM === */
'''

path.write_text(text.rstrip() + "\n\n" + branding.strip() + "\n", encoding="utf-8")
saved = path.read_text(encoding="utf-8")
if saved.count("/* === BACKUP CLOUD GESTAO MOVEL - INICIO === */") != 1:
    raise SystemExit("bloco CSS Backup Cloud não ficou único")
print("   CSS Backup Cloud: OK")
PY
then
  rollback
  fail "falha ao aplicar CSS; backup restaurado"
fi

if [ "$TEST_MODE" != "1" ]; then
  if ! systemctl restart tomcat9; then
    rollback
    fail "falha ao reiniciar tomcat9; backup restaurado"
  fi

  ok=0
  for _ in $(seq 1 90); do
    code="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/ 2>/dev/null || true)"
    case "$code" in
      200|301|302|303|307|308|401|403) ok=1; break ;;
    esac
    sleep 1
  done

  if [ "$ok" != "1" ]; then
    rollback
    fail "aplicação não respondeu corretamente; backup restaurado"
  fi
fi

echo "[5/5] Conferência final"
if ! python3 - "$CTX" "$CSS" "$LOGO" <<'PY'
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

ctx, css, logo = map(Path, sys.argv[1:])
ET.parse(ctx)

if not logo.is_file() or logo.stat().st_size < 1000:
    raise SystemExit(f"logo ausente ou inválido: {logo}")
if not logo.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"):
    raise SystemExit("logo final não é PNG")

c = css.read_text(encoding="utf-8")
if c.count("/* === BACKUP CLOUD GESTAO MOVEL - INICIO === */") != 1:
    raise SystemExit("CSS final inválido")

x = ctx.read_text(encoding="utf-8")
required = [
    'name="rebranding.name" value="Gestão Móvel"',
    'name="rebranding.vendor.name" value="Backup Cloud"',
    'name="rebranding.logo" value="/images/backup-cloud/backup-cloud-logo.png"',
]
for item in required:
    if item not in x:
        raise SystemExit(f"parâmetro final ausente: {item}")

print("   Arquivos e configuração: OK")
PY
then
  rollback
  fail "conferência final falhou; backup restaurado"
fi

echo "============================================================"
echo " SUCESSO - BACKUP CLOUD | GESTÃO MÓVEL"
echo " Backup: $BACKUP"
echo " Versão: $VERSION"
echo "============================================================"
