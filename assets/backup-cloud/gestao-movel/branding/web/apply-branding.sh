#!/usr/bin/env bash
set -euo pipefail
umask 022

VERSION="2026.08.07.8"

BASE="${BC_BASE:-/home/suporte}"
TOMCAT="${BC_TOMCAT:-/var/lib/tomcat9}"
CTX="$TOMCAT/conf/Catalina/localhost/ROOT.xml"
WEB="$TOMCAT/webapps/ROOT"
CSS="$WEB/css/main.css"
ASSETS="$WEB/images/backup-cloud"
LOGO="$ASSETS/backup-cloud-logo.png"
HERO="$ASSETS/backupcloud-gestao-movel-login.jpg"
RAW="${BC_RAW_BASE:-https://raw.githubusercontent.com/bkpcloud-app/snoc/main/assets/backup-cloud/gestao-movel/branding/web}"
TEST_MODE="${BC_TEST_MODE:-0}"
HERO_SHA256="432fbabb0a10ff72ac4eeb458ea1c596eb111bb500a11b17fa2a9b18f9b1f14e"

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

decode_png() {
  local url="$1"
  local out="$2"
  local src="$TMP/logo.b64"

  curl -fLsS --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 90 "$url" -o "$src" \
    || fail "não foi possível baixar o logo BackupCloud"

  python3 - "$src" "$out" <<'PY'
from pathlib import Path
import base64
import re
import struct
import sys

src = Path(sys.argv[1])
out = Path(sys.argv[2])
text = src.read_text(encoding="ascii")
payload = re.sub(r"\s+", "", text)
if len(payload) < 100:
    raise SystemExit("logo Base64 vazio ou incompleto")
if not re.fullmatch(r"[A-Za-z0-9+/]*={0,2}", payload):
    raise SystemExit("logo Base64 contém caracteres inválidos")
payload += "=" * ((-len(payload)) % 4)
data = base64.b64decode(payload, validate=True)
if not data.startswith(b"\x89PNG\r\n\x1a\n"):
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

decode_hero() {
  local url="$1"
  local out="$2"
  local src="$TMP/hero.b64"

  curl -fLsS --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 90 "$url" -o "$src" \
    || fail "não foi possível baixar a arte aprovada do login"

  python3 - "$src" "$out" "$HERO_SHA256" <<'PY'
from pathlib import Path
import base64
import hashlib
import re
import sys

src = Path(sys.argv[1])
out = Path(sys.argv[2])
expected = sys.argv[3].lower()
text = src.read_text(encoding="ascii")
payload = re.sub(r"\s+", "", text)
if len(payload) < 1000:
    raise SystemExit("arte do login Base64 vazia ou incompleta")
if not re.fullmatch(r"[A-Za-z0-9+/]*={0,2}", payload):
    raise SystemExit("arte do login Base64 contém caracteres inválidos")
payload += "=" * ((-len(payload)) % 4)
data = base64.b64decode(payload, validate=True)
if not data.startswith(b"\xff\xd8\xff") or not data.endswith(b"\xff\xd9"):
    raise SystemExit("arte decodificada não é JPEG íntegro")
actual = hashlib.sha256(data).hexdigest()
if actual != expected:
    raise SystemExit(f"SHA-256 da arte não confere: {actual}")
out.write_bytes(data)
print(f"   Arte login OK: {len(data)} bytes | SHA-256 {actual}")
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
echo " BACKUPCLOUD | GESTÃO MÓVEL"
echo " Instalador: $VERSION"
echo "============================================================"

echo "[1/6] Pré-validando ativos - nenhuma alteração no servidor"
decode_png "$RAW/backup-cloud-logo-dark-transparent.png.b64" "$TMP/logo.png"
decode_hero "$RAW/backupcloud-gestao-movel-login.jpg.b64" "$TMP/hero.jpg"

echo "[2/6] Validando configuração atual"
python3 - "$CTX" <<'PY'
import sys
import xml.etree.ElementTree as ET
ET.parse(sys.argv[1])
print("   ROOT.xml: XML válido")
PY

echo "[3/6] Criando backup"
mkdir -p "$BACKUP"
cp -a "$CTX" "$BACKUP/ROOT.xml"
cp -a "$CSS" "$BACKUP/main.css"
[ -d "$ASSETS" ] && cp -a "$ASSETS" "$BACKUP/backup-cloud-assets"
echo "   $BACKUP"

echo "[4/6] Aplicando identidade BackupCloud"
install -d -m 0755 "$ASSETS"
install -m 0644 "$TMP/logo.png" "$LOGO"
install -m 0644 "$TMP/hero.jpg" "$HERO"

if ! python3 - "$CTX" <<'PY'
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

values = {
    "rebranding.name": "BackupCloud | Gestão Móvel",
    "rebranding.vendor.name": "BackupCloud",
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
    ("/* === BACKUPCLOUD GESTAO MOVEL - INICIO === */", "/* === BACKUPCLOUD GESTAO MOVEL - FIM === */"),
]
for start, end in markers:
    text = re.sub(re.escape(start) + r".*?" + re.escape(end), "", text, flags=re.S)

branding = r'''
/* === BACKUPCLOUD GESTAO MOVEL - INICIO === */
:root{--bc-navy:#0B1323;--bc-dark:#111827;--bc-purple:#3E4095;--bc-purple2:#5659C7;--bc-blue:#2563EB;--bc-slate:#CBD5E1}
.header{background:linear-gradient(90deg,var(--bc-navy),var(--bc-dark) 58%,#171a35)!important;border-color:var(--bc-navy)!important;box-shadow:0 2px 12px rgba(4,9,20,.24)!important}
.header a,.header .logo-text a{color:#fff!important}
.btn-primary,.login .btn-default{background:linear-gradient(90deg,var(--bc-blue),var(--bc-purple2))!important;border-color:var(--bc-blue)!important;color:#fff!important;border-radius:7px!important;font-weight:600!important}
.login-logo{width:min(720px,calc(100% - 28px))!important;aspect-ratio:1672/941!important;margin:24px auto 18px!important;display:block!important;position:relative!important;z-index:2!important;background:#0a0f18 url('/images/backup-cloud/backupcloud-gestao-movel-login.jpg') center center/cover no-repeat!important;border:1px solid rgba(148,163,184,.16)!important;border-radius:14px!important;box-shadow:0 20px 56px rgba(0,0,0,.34)!important;overflow:hidden!important}
.login-logo img,.login-logo .logo{position:absolute!important;width:1px!important;height:1px!important;opacity:0!important;overflow:hidden!important;pointer-events:none!important}
.login-logo::before{content:"";position:fixed;inset:0;z-index:-2;background:radial-gradient(circle at 18% 25%,rgba(86,89,199,.28),transparent 27%),radial-gradient(circle at 76% 72%,rgba(37,99,235,.16),transparent 31%),linear-gradient(125deg,#070d19 0%,#0b1323 42%,#151735 70%,#090d18 100%)}
.login-logo::after{content:""!important}
.login{width:480px!important;border:1px solid rgba(148,163,184,.18)!important;border-top:2px solid var(--bc-purple2)!important;border-radius:12px!important;overflow:hidden!important;position:relative!important;z-index:2!important;box-shadow:0 22px 58px rgba(0,0,0,.34)!important}
.login .panel-body{background:rgba(17,24,39,.96)!important;padding:31px 36px!important}
.login label{color:#e5e7eb!important;font-weight:500!important}
.login .form-control{height:43px!important;color:#f8fafc!important;background:rgba(9,16,30,.88)!important;border-color:#334155!important;border-radius:7px!important;box-shadow:none!important}
.login .form-control:focus{border-color:var(--bc-blue)!important;box-shadow:0 0 0 3px rgba(37,99,235,.17)!important}
@media(max-width:760px){.login-logo{width:calc(100% - 24px)!important;margin:18px auto 14px!important;border-radius:10px!important}.login{width:calc(100% - 24px)!important;margin:auto!important}.login .panel-body{padding:24px 20px!important}}
/* === BACKUPCLOUD GESTAO MOVEL - FIM === */
'''

path.write_text(text.rstrip() + "\n\n" + branding.strip() + "\n", encoding="utf-8")
saved = path.read_text(encoding="utf-8")
if saved.count("/* === BACKUPCLOUD GESTAO MOVEL - INICIO === */") != 1:
    raise SystemExit("bloco CSS BackupCloud não ficou único")
if "/images/backup-cloud/backupcloud-gestao-movel-login.jpg" not in saved:
    raise SystemExit("arte do login não foi referenciada no CSS")
print("   CSS BackupCloud: OK")
PY
then
  rollback
  fail "falha ao aplicar CSS; backup restaurado"
fi

echo "[5/6] Reiniciando aplicação"
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

echo "[6/6] Conferência final"
if ! python3 - "$CTX" "$CSS" "$LOGO" "$HERO" "$HERO_SHA256" <<'PY'
from pathlib import Path
import hashlib
import sys
import xml.etree.ElementTree as ET

ctx, css, logo, hero = map(Path, sys.argv[1:5])
expected_hero_sha = sys.argv[5].lower()
ET.parse(ctx)

if not logo.is_file() or logo.stat().st_size < 1000:
    raise SystemExit(f"logo ausente ou inválido: {logo}")
if not logo.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"):
    raise SystemExit("logo final não é PNG")

if not hero.is_file() or hero.stat().st_size < 50000:
    raise SystemExit(f"arte do login ausente ou inválida: {hero}")
h = hero.read_bytes()
if not h.startswith(b"\xff\xd8\xff") or not h.endswith(b"\xff\xd9"):
    raise SystemExit("arte final do login não é JPEG íntegro")
actual_hero_sha = hashlib.sha256(h).hexdigest()
if actual_hero_sha != expected_hero_sha:
    raise SystemExit(f"SHA-256 final da arte não confere: {actual_hero_sha}")

c = css.read_text(encoding="utf-8")
if c.count("/* === BACKUPCLOUD GESTAO MOVEL - INICIO === */") != 1:
    raise SystemExit("CSS final inválido")
if "/images/backup-cloud/backupcloud-gestao-movel-login.jpg" not in c:
    raise SystemExit("CSS final não referencia a arte aprovada")

x = ctx.read_text(encoding="utf-8")
required = [
    'name="rebranding.name" value="BackupCloud | Gestão Móvel"',
    'name="rebranding.vendor.name" value="BackupCloud"',
    'name="rebranding.logo" value="/images/backup-cloud/backup-cloud-logo.png"',
    'name="rebranding.mobile.name" value="Gestão Móvel"',
]
for item in required:
    if item not in x:
        raise SystemExit(f"parâmetro final ausente: {item}")

print("   Configuração, logo e arte do login: OK")
print(f"   Arte SHA-256: {actual_hero_sha}")
PY
then
  rollback
  fail "conferência final falhou; backup restaurado"
fi

echo "============================================================"
echo " SUCESSO - BACKUPCLOUD | GESTÃO MÓVEL"
echo " Backup: $BACKUP"
echo " Versão: $VERSION"
echo "============================================================"
