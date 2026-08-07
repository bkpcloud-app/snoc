#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

VERSION="2026.08.07.11"
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
HERO_SHA="e1d00fa50a8c1519631ed4d89bac5683c5e73db8c2b8e565dd4fab0ab5ee2659"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BASE/BACKUP-CLOUD-GESTAO-MOVEL-BRANDING-BACKUP-$STAMP"
TMP="$(mktemp -d /tmp/bc-mdm-branding.XXXXXX)"
CHANGED=0

cleanup(){ rm -rf "$TMP"; }
rollback(){
  [ "$CHANGED" = 1 ] || return 0
  echo "ROLLBACK: restaurando backup..."
  cp -a "$BACKUP/ROOT.xml" "$CTX" 2>/dev/null || true
  cp -a "$BACKUP/main.css" "$CSS" 2>/dev/null || true
  rm -rf "$ASSETS"
  [ -d "$BACKUP/backup-cloud-assets" ] && cp -a "$BACKUP/backup-cloud-assets" "$ASSETS"
  [ "$TEST_MODE" = 1 ] || systemctl restart tomcat9 >/dev/null 2>&1 || true
  echo "ROLLBACK concluído."
}
trap cleanup EXIT
trap 'r=$?; [ $r -eq 0 ] || rollback; exit $r' ERR
fail(){ echo "ERRO: $*" >&2; if [ "$CHANGED" = 1 ]; then rollback; CHANGED=0; fi; exit 1; }
fetch(){ curl -fLsS --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 90 "$1" -o "$2"; }

[ "$TEST_MODE" = 1 ] || [ "$(id -u)" = 0 ] || fail "execute como root"
for c in curl python3 cp rm mkdir install cat; do command -v "$c" >/dev/null || fail "comando ausente: $c"; done
[ -s "$CTX" ] || fail "arquivo não encontrado: $CTX"
[ -s "$CSS" ] || fail "arquivo não encontrado: $CSS"
if [ "$TEST_MODE" != 1 ]; then
  systemctl is-active --quiet tomcat9 || fail "tomcat9 não está ativo"
  systemctl is-active --quiet nginx || fail "nginx não está ativo"
fi

echo "============================================================"
echo " BACKUPCLOUD | GESTÃO MÓVEL"
echo " Instalador: $VERSION"
echo "============================================================"
echo "[1/6] Pré-validando ativos - nenhuma alteração no servidor"
fetch "$RAW/backup-cloud-logo-dark-transparent.png.b64" "$TMP/logo.b64" || fail "falha ao baixar logo"
: > "$TMP/hero.b64"
for n in 01 02 03 04; do
  fetch "$RAW/backupcloud-gestao-movel-login-560.jpg.b64.part$n" "$TMP/h$n" || fail "falha ao baixar arte parte $n"
  cat "$TMP/h$n" >> "$TMP/hero.b64"
done
python3 - "$TMP/logo.b64" "$TMP/logo.png" "$TMP/hero.b64" "$TMP/hero.jpg" "$HERO_SHA" <<'PY'
from pathlib import Path
import base64,hashlib,re,struct,sys
lb,lo,hb,ho,expected=map(str,sys.argv[1:])
def dec(path):
 s=Path(path).read_text(encoding='ascii'); p=re.sub(r'\s+','',s)
 if not re.fullmatch(r'[A-Za-z0-9+/]*={0,2}',p): raise SystemExit(f'Base64 inválido: {path}')
 p += '='*((-len(p))%4); return base64.b64decode(p,validate=True),len(re.sub(r'\s+','',s))
logo,_=dec(lb)
if not logo.startswith(b'\x89PNG\r\n\x1a\n') or logo[12:16]!=b'IHDR' or b'IEND' not in logo[-32:]: raise SystemExit('logo PNG inválido')
w,h=struct.unpack('>II',logo[16:24]); Path(lo).write_bytes(logo)
hero,b64len=dec(hb)
if b64len!=9016: raise SystemExit(f'tamanho Base64 da arte inesperado: {b64len}')
if not hero.startswith(b'\xff\xd8\xff') or not hero.endswith(b'\xff\xd9'): raise SystemExit('arte JPEG inválida')
sha=hashlib.sha256(hero).hexdigest()
if sha!=expected: raise SystemExit(f'SHA-256 da arte não confere: {sha}')
Path(ho).write_bytes(hero)
print(f'   Logo OK: {w}x{h} | {len(logo)} bytes')
print(f'   Arte login OK: {len(hero)} bytes | SHA-256 {sha}')
PY

echo "[2/6] Validando configuração atual"
python3 - "$CTX" <<'PY'
import sys,xml.etree.ElementTree as ET
ET.parse(sys.argv[1]); print('   ROOT.xml: XML válido')
PY

echo "[3/6] Criando backup"
mkdir -p "$BACKUP"
cp -a "$CTX" "$BACKUP/ROOT.xml"
cp -a "$CSS" "$BACKUP/main.css"
[ -d "$ASSETS" ] && cp -a "$ASSETS" "$BACKUP/backup-cloud-assets"
echo "   $BACKUP"
CHANGED=1

echo "[4/6] Aplicando identidade BackupCloud"
install -d -m 0755 "$ASSETS"
install -m 0644 "$TMP/logo.png" "$LOGO"
install -m 0644 "$TMP/hero.jpg" "$HERO"
python3 - "$CTX" <<'PY'
from pathlib import Path
import re,sys,xml.etree.ElementTree as ET
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')
vals={'rebranding.name':'BackupCloud | Gestão Móvel','rebranding.vendor.name':'BackupCloud','rebranding.logo':'/images/backup-cloud/backup-cloud-logo.png','rebranding.mobile.name':'Gestão Móvel'}
for name,val in vals.items():
 pat=re.compile(r'<Parameter\b(?=[^>]*\bname\s*=\s*["\']'+re.escape(name)+r'["\'])[^>]*?/?>',re.I)
 new=f'<Parameter name="{name}" value="{val}" override="false"/>'
 s=pat.sub(new,s,count=1) if pat.search(s) else s.replace('</Context>','    '+new+'\n</Context>',1)
p.write_text(s,encoding='utf-8'); ET.parse(p); print('   Rebranding nativo: OK')
PY
python3 - "$CSS" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8',errors='ignore')
for a,b in [('DDM GESTAO MOVEL - INICIO','DDM GESTAO MOVEL - FIM'),('DDM GESTAO MOVEL - PRODUCAO - INICIO','DDM GESTAO MOVEL - PRODUCAO - FIM'),('DDM POLIMENTO PRODUCAO - INICIO','DDM POLIMENTO PRODUCAO - FIM'),('BACKUP CLOUD GESTAO MOVEL - INICIO','BACKUP CLOUD GESTAO MOVEL - FIM'),('BACKUPCLOUD GESTAO MOVEL - INICIO','BACKUPCLOUD GESTAO MOVEL - FIM')]:
 s=re.sub(r'/\* === '+re.escape(a)+r' === \*/.*?/\* === '+re.escape(b)+r' === \*/','',s,flags=re.S)
block=r'''/* === BACKUPCLOUD GESTAO MOVEL - INICIO === */
:root{--bc-navy:#0B1323;--bc-dark:#111827;--bc-purple:#3E4095;--bc-purple2:#5659C7;--bc-blue:#2563EB;--bc-slate:#CBD5E1}
.header{background:linear-gradient(90deg,var(--bc-navy),var(--bc-dark) 58%,#171a35)!important;border-color:var(--bc-navy)!important;box-shadow:0 2px 12px rgba(4,9,20,.24)!important}.header a,.header .logo-text a{color:#fff!important}.btn-primary,.login .btn-default{background:linear-gradient(90deg,var(--bc-blue),var(--bc-purple2))!important;border-color:var(--bc-blue)!important;color:#fff!important;border-radius:7px!important;font-weight:600!important}
.login-logo{width:min(720px,calc(100% - 28px))!important;aspect-ratio:16/9!important;margin:24px auto 18px!important;display:block!important;position:relative!important;z-index:2!important;background:#0a0f18 url('/images/backup-cloud/backupcloud-gestao-movel-login.jpg') center/cover no-repeat!important;border:1px solid rgba(148,163,184,.16)!important;border-radius:14px!important;box-shadow:0 20px 56px rgba(0,0,0,.34)!important;overflow:hidden!important}.login-logo img,.login-logo .logo{position:absolute!important;width:1px!important;height:1px!important;opacity:0!important;overflow:hidden!important;pointer-events:none!important}.login-logo::before{content:"";position:fixed;inset:0;z-index:-2;background:radial-gradient(circle at 18% 25%,rgba(86,89,199,.28),transparent 27%),radial-gradient(circle at 76% 72%,rgba(37,99,235,.16),transparent 31%),linear-gradient(125deg,#070d19 0%,#0b1323 42%,#151735 70%,#090d18 100%)}.login-logo::after{content:""!important}
.login{width:480px!important;border:1px solid rgba(148,163,184,.18)!important;border-top:2px solid var(--bc-purple2)!important;border-radius:12px!important;overflow:hidden!important;position:relative!important;z-index:2!important;box-shadow:0 22px 58px rgba(0,0,0,.34)!important}.login .panel-body{background:rgba(17,24,39,.96)!important;padding:31px 36px!important}.login label{color:#e5e7eb!important;font-weight:500!important}.login .form-control{height:43px!important;color:#f8fafc!important;background:rgba(9,16,30,.88)!important;border-color:#334155!important;border-radius:7px!important;box-shadow:none!important}.login .form-control:focus{border-color:var(--bc-blue)!important;box-shadow:0 0 0 3px rgba(37,99,235,.17)!important}@media(max-width:760px){.login-logo{width:calc(100% - 24px)!important;margin:18px auto 14px!important;border-radius:10px!important}.login{width:calc(100% - 24px)!important;margin:auto!important}.login .panel-body{padding:24px 20px!important}}
/* === BACKUPCLOUD GESTAO MOVEL - FIM === */'''
p.write_text(s.rstrip()+'\n\n'+block+'\n',encoding='utf-8')
assert p.read_text(encoding='utf-8').count('BACKUPCLOUD GESTAO MOVEL - INICIO')==1
print('   CSS BackupCloud: OK')
PY

echo "[5/6] Reiniciando aplicação"
if [ "$TEST_MODE" != 1 ]; then
  systemctl restart tomcat9
  ok=0
  for _ in $(seq 1 90); do
    code="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/ 2>/dev/null || true)"
    case "$code" in 200|301|302|303|307|308|401|403) ok=1; break;; esac
    sleep 1
  done
  [ "$ok" = 1 ] || fail "aplicação não respondeu após o restart"
fi

echo "[6/6] Conferência final"
python3 - "$CTX" "$CSS" "$LOGO" "$HERO" "$HERO_SHA" <<'PY'
from pathlib import Path
import hashlib,sys,xml.etree.ElementTree as ET
ctx,css,logo,hero=map(Path,sys.argv[1:5]); expected=sys.argv[5]
ET.parse(ctx); x=ctx.read_text(encoding='utf-8')
for item in ['name="rebranding.name" value="BackupCloud | Gestão Móvel"','name="rebranding.vendor.name" value="BackupCloud"','name="rebranding.logo" value="/images/backup-cloud/backup-cloud-logo.png"','name="rebranding.mobile.name" value="Gestão Móvel"']: assert item in x,item
assert logo.read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
d=hero.read_bytes(); assert d.startswith(b'\xff\xd8\xff') and d.endswith(b'\xff\xd9')
assert hashlib.sha256(d).hexdigest()==expected
assert css.read_text(encoding='utf-8').count('BACKUPCLOUD GESTAO MOVEL - INICIO')==1
print('   Configuração e ativos: OK')
PY
CHANGED=0
echo "============================================================"
echo " SUCESSO - BACKUPCLOUD | GESTÃO MÓVEL"
echo " Backup: $BACKUP"
echo " Versão: $VERSION"
echo "============================================================"
