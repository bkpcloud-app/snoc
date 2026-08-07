#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

VERSION="2026.08.07.12"
BASE="${BC_BASE:-/home/suporte}"
TOMCAT="${BC_TOMCAT:-/var/lib/tomcat9}"
CTX="$TOMCAT/conf/Catalina/localhost/ROOT.xml"
WEB="$TOMCAT/webapps/ROOT"
CSS="$WEB/css/main.css"
LOGIN="$WEB/app/components/main/view/login.html"
ASSETS="$WEB/images/backup-cloud"
LOGO="$ASSETS/backup-cloud-logo.png"
HERO="$ASSETS/backupcloud-gestao-movel-login.jpg"
RAW="${BC_RAW_BASE:-https://raw.githubusercontent.com/bkpcloud-app/snoc/main/assets/backup-cloud/gestao-movel/branding/web}"
TEST_MODE="${BC_TEST_MODE:-0}"
HERO_SHA="5dcf016dcd91781457494cba552676c10ddaa682d01cc64e5480ce476737a07a"
HERO_B64_LEN="29488"
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
  cp -a "$BACKUP/login.html" "$LOGIN" 2>/dev/null || true
  rm -rf "$ASSETS"
  [ -d "$BACKUP/backup-cloud-assets" ] && cp -a "$BACKUP/backup-cloud-assets" "$ASSETS"
  [ "$TEST_MODE" = 1 ] || systemctl restart tomcat9 >/dev/null 2>&1 || true
  CHANGED=0
  echo "ROLLBACK concluído."
}
trap cleanup EXIT
trap 'r=$?; [ $r -eq 0 ] || rollback; exit $r' ERR
fail(){ echo "ERRO: $*" >&2; rollback; exit 1; }
fetch(){ curl -fLsS --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 90 "$1" -o "$2"; }

[ "$TEST_MODE" = 1 ] || [ "$(id -u)" = 0 ] || fail "execute como root"
for c in curl python3 cp rm mkdir install cat grep; do command -v "$c" >/dev/null || fail "comando ausente: $c"; done
for f in "$CTX" "$CSS" "$LOGIN"; do [ -s "$f" ] || fail "arquivo não encontrado: $f"; done
if [ "$TEST_MODE" != 1 ]; then
  systemctl is-active --quiet tomcat9 || fail "tomcat9 não está ativo"
  systemctl is-active --quiet nginx || fail "nginx não está ativo"
fi

echo "============================================================"
echo " BackupCloud | GESTÃO MÓVEL"
echo " Instalador: $VERSION"
echo "============================================================"
echo "[1/7] Pré-validando ativos - nenhuma alteração no servidor"
fetch "$RAW/backup-cloud-logo-dark-transparent.png.b64" "$TMP/logo.b64" || fail "falha ao baixar logo"
: > "$TMP/hero.b64"
for n in 01 02 03 04 05; do
  fetch "$RAW/backupcloud-gestao-movel-login-v12.b64.part$n" "$TMP/h$n" || fail "falha ao baixar arte parte $n"
  cat "$TMP/h$n" >> "$TMP/hero.b64"
done
python3 - "$TMP/logo.b64" "$TMP/logo.png" "$TMP/hero.b64" "$TMP/hero.jpg" "$HERO_SHA" "$HERO_B64_LEN" <<'PY'
from pathlib import Path
import base64, hashlib, re, struct, sys
lb,lo,hb,ho,expected,expected_len=sys.argv[1:]
def dec(path):
    s=Path(path).read_text(encoding='ascii')
    p=re.sub(r'\s+','',s)
    if not re.fullmatch(r'[A-Za-z0-9+/]*={0,2}',p):
        raise SystemExit(f'Base64 inválido: {path}')
    if len(p) % 4:
        raise SystemExit(f'Base64 com tamanho inválido: {path} ({len(p)})')
    return base64.b64decode(p,validate=True),len(p)
logo,_=dec(lb)
if not logo.startswith(b'\x89PNG\r\n\x1a\n') or logo[12:16] != b'IHDR' or b'IEND' not in logo[-32:]:
    raise SystemExit('logo PNG inválido')
w,h=struct.unpack('>II',logo[16:24])
Path(lo).write_bytes(logo)
hero,b64len=dec(hb)
if b64len != int(expected_len):
    raise SystemExit(f'tamanho Base64 da arte inesperado: {b64len} (esperado {expected_len})')
if not hero.startswith(b'\xff\xd8\xff') or not hero.endswith(b'\xff\xd9'):
    raise SystemExit('arte JPEG inválida')
sha=hashlib.sha256(hero).hexdigest()
if sha != expected:
    raise SystemExit(f'SHA-256 da arte não confere: {sha}')
Path(ho).write_bytes(hero)
print(f'   Logo OK: {w}x{h} | {len(logo)} bytes')
print(f'   Arte login OK: {len(hero)} bytes | SHA-256 {sha}')
PY

echo "[2/7] Validando aplicação atual"
python3 - "$CTX" "$LOGIN" <<'PY'
import sys,xml.etree.ElementTree as ET
from pathlib import Path
ET.parse(sys.argv[1])
s=Path(sys.argv[2]).read_text(encoding='utf-8',errors='strict')
if 'class="login' not in s and "class='login" not in s:
    raise SystemExit('estrutura de login não reconhecida')
print('   ROOT.xml e login.html: OK')
PY

echo "[3/7] Criando backup"
mkdir -p "$BACKUP"
cp -a "$CTX" "$BACKUP/ROOT.xml"
cp -a "$CSS" "$BACKUP/main.css"
cp -a "$LOGIN" "$BACKUP/login.html"
[ -d "$ASSETS" ] && cp -a "$ASSETS" "$BACKUP/backup-cloud-assets"
echo "   $BACKUP"
CHANGED=1

echo "[4/7] Instalando ativos e identidade nativa"
install -d -m 0755 "$ASSETS"
install -m 0644 "$TMP/logo.png" "$LOGO"
install -m 0644 "$TMP/hero.jpg" "$HERO"
python3 - "$CTX" "$LOGO" <<'PY'
from pathlib import Path
import re,sys,xml.etree.ElementTree as ET
p=Path(sys.argv[1]); logo=sys.argv[2]
s=p.read_text(encoding='utf-8')
vals={
  'rebranding.name':'BackupCloud | Gestão Móvel',
  'rebranding.vendor.name':'BackupCloud',
  'rebranding.vendor.link':'https://bkpcloud.app.br',
  'rebranding.logo':logo,
  'rebranding.mobile.name':'Gestão Móvel'
}
for name,val in vals.items():
    pat=re.compile(r'<Parameter\b(?=[^>]*\bname\s*=\s*["\']'+re.escape(name)+r'["\'])[^>]*?/?>',re.I)
    new=f'<Parameter name="{name}" value="{val}" override="false"/>'
    s=pat.sub(new,s,count=1) if pat.search(s) else s.replace('</Context>','    '+new+'\n</Context>',1)
p.write_text(s,encoding='utf-8')
ET.parse(p)
print('   Rebranding nativo: OK')
PY

echo "[5/7] Fixando a arte aprovada diretamente no login"
python3 - "$LOGIN" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')
start='<!-- BACKUPCLOUD GESTAO MOVEL HERO - INICIO -->'
end='<!-- BACKUPCLOUD GESTAO MOVEL HERO - FIM -->'
s=re.sub(re.escape(start)+r'.*?'+re.escape(end)+r'\s*','',s,flags=re.S)
hero='''<!-- BACKUPCLOUD GESTAO MOVEL HERO - INICIO -->
<div class="bc-login-hero" aria-label="BackupCloud | Gestão Móvel">
  <img src="/images/backup-cloud/backupcloud-gestao-movel-login.jpg?v=2026080712" alt="BackupCloud | Gestão Móvel">
</div>
<!-- BACKUPCLOUD GESTAO MOVEL HERO - FIM -->
'''
needles=['<div class="login-logo"',"<div class='login-logo'",'<div ng-if="!isIE">',"<div ng-if='!isIE'>"]
for needle in needles:
    pos=s.find(needle)
    if pos >= 0:
        s=s[:pos]+hero+s[pos:]
        break
else:
    raise SystemExit('ponto de inserção do login não encontrado')
if s.count(start)!=1 or '/images/backup-cloud/backupcloud-gestao-movel-login.jpg?v=2026080712' not in s:
    raise SystemExit('falha ao inserir arte no login')
p.write_text(s,encoding='utf-8')
print('   login.html: arte fixada')
PY
python3 - "$CSS" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8',errors='ignore')
for a,b in [
 ('DDM GESTAO MOVEL - INICIO','DDM GESTAO MOVEL - FIM'),
 ('DDM GESTAO MOVEL - PRODUCAO - INICIO','DDM GESTAO MOVEL - PRODUCAO - FIM'),
 ('DDM POLIMENTO PRODUCAO - INICIO','DDM POLIMENTO PRODUCAO - FIM'),
 ('BACKUP CLOUD GESTAO MOVEL - INICIO','BACKUP CLOUD GESTAO MOVEL - FIM'),
 ('BACKUPCLOUD GESTAO MOVEL - INICIO','BACKUPCLOUD GESTAO MOVEL - FIM')]:
    s=re.sub(r'/\* === '+re.escape(a)+r' === \*/.*?/\* === '+re.escape(b)+r' === \*/','',s,flags=re.S)
block=r'''/* === BACKUPCLOUD GESTAO MOVEL - INICIO === */
:root{--bc-navy:#0B1323;--bc-dark:#111827;--bc-purple:#3E4095;--bc-purple2:#5659C7;--bc-blue:#2563EB;--bc-slate:#CBD5E1}
html,body{min-height:100%!important;background:radial-gradient(circle at 18% 25%,rgba(86,89,199,.28),transparent 27%),radial-gradient(circle at 76% 72%,rgba(37,99,235,.16),transparent 31%),linear-gradient(125deg,#070d19 0%,#0b1323 42%,#151735 70%,#090d18 100%) fixed!important}
.header{background:linear-gradient(90deg,var(--bc-navy),var(--bc-dark) 58%,#171a35)!important;border-color:var(--bc-navy)!important;box-shadow:0 2px 12px rgba(4,9,20,.24)!important}.header a,.header .logo-text a{color:#fff!important}
.btn-primary,.login .btn-default{background:linear-gradient(90deg,var(--bc-blue),var(--bc-purple2))!important;border-color:var(--bc-blue)!important;color:#fff!important;border-radius:7px!important;font-weight:600!important}
.login-logo{display:none!important}
.bc-login-hero{width:min(620px,calc(100% - 28px))!important;margin:22px auto 18px!important;display:block!important;position:relative!important;z-index:2!important}
.bc-login-hero img{display:block!important;width:100%!important;height:auto!important;opacity:1!important;visibility:visible!important;border:1px solid rgba(148,163,184,.16)!important;border-radius:14px!important;box-shadow:0 20px 56px rgba(0,0,0,.34)!important;background:#0a0f18!important}
.login{width:480px!important;border:1px solid rgba(148,163,184,.18)!important;border-top:2px solid var(--bc-purple2)!important;border-radius:12px!important;overflow:hidden!important;position:relative!important;z-index:2!important;box-shadow:0 22px 58px rgba(0,0,0,.34)!important}.login .panel-body{background:rgba(17,24,39,.96)!important;padding:31px 36px!important}.login label{color:#e5e7eb!important;font-weight:500!important}.login .form-control{height:43px!important;color:#f8fafc!important;background:rgba(9,16,30,.88)!important;border-color:#334155!important;border-radius:7px!important;box-shadow:none!important}.login .form-control:focus{border-color:var(--bc-blue)!important;box-shadow:0 0 0 3px rgba(37,99,235,.17)!important}
@media(max-width:760px){.bc-login-hero{width:calc(100% - 24px)!important;margin:16px auto 12px!important;border-radius:10px!important}.login{width:calc(100% - 24px)!important;margin:auto!important}.login .panel-body{padding:24px 20px!important}}
/* === BACKUPCLOUD GESTAO MOVEL - FIM === */'''
p.write_text(s.rstrip()+'\n\n'+block+'\n',encoding='utf-8')
if p.read_text(encoding='utf-8').count('BACKUPCLOUD GESTAO MOVEL - INICIO')!=1:
    raise SystemExit('bloco CSS duplicado')
print('   CSS BackupCloud: OK')
PY

echo "[6/7] Reiniciando aplicação"
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

echo "[7/7] Conferência final"
python3 - "$CTX" "$CSS" "$LOGIN" "$LOGO" "$HERO" "$HERO_SHA" <<'PY'
from pathlib import Path
import hashlib,sys,xml.etree.ElementTree as ET
ctx,css,login,logo,hero=map(Path,sys.argv[1:6]); expected=sys.argv[6]
ET.parse(ctx); x=ctx.read_text(encoding='utf-8')
required=[
 'name="rebranding.name" value="BackupCloud | Gestão Móvel"',
 'name="rebranding.vendor.name" value="BackupCloud"',
 'name="rebranding.logo" value="'+str(logo)+'"',
 'name="rebranding.mobile.name" value="Gestão Móvel"'
]
for item in required:
    if item not in x: raise SystemExit('configuração ausente: '+item)
if not logo.read_bytes().startswith(b'\x89PNG\r\n\x1a\n'): raise SystemExit('logo instalado inválido')
d=hero.read_bytes()
if not (d.startswith(b'\xff\xd8\xff') and d.endswith(b'\xff\xd9')): raise SystemExit('arte instalada inválida')
if hashlib.sha256(d).hexdigest()!=expected: raise SystemExit('SHA da arte instalada não confere')
l=login.read_text(encoding='utf-8')
if l.count('BACKUPCLOUD GESTAO MOVEL HERO - INICIO')!=1: raise SystemExit('hero não está fixado no login')
if '/images/backup-cloud/backupcloud-gestao-movel-login.jpg?v=2026080712' not in l: raise SystemExit('URL da arte ausente no login')
if css.read_text(encoding='utf-8').count('BACKUPCLOUD GESTAO MOVEL - INICIO')!=1: raise SystemExit('CSS inválido')
print('   Arquivos locais: OK')
PY
if [ "$TEST_MODE" != 1 ]; then
  fetch "http://127.0.0.1:8080/images/backup-cloud/backupcloud-gestao-movel-login.jpg?v=2026080712" "$TMP/live-hero.jpg" || fail "arte não é servida pelo Tomcat"
  fetch "http://127.0.0.1:8080/app/components/main/view/login.html?v=2026080712" "$TMP/live-login.html" || fail "login.html não é servido pelo Tomcat"
  fetch "http://127.0.0.1:8080/rest/public/logo?v=2026080712" "$TMP/live-logo.png" || fail "logo nativa não é servida pela aplicação"
  python3 - "$TMP/live-hero.jpg" "$TMP/live-login.html" "$TMP/live-logo.png" "$HERO_SHA" <<'PY'
from pathlib import Path
import hashlib,sys
hero,login,logo=map(Path,sys.argv[1:4]); expected=sys.argv[4]
if hashlib.sha256(hero.read_bytes()).hexdigest()!=expected: raise SystemExit('arte HTTP não confere com a aprovada')
l=login.read_text(encoding='utf-8',errors='strict')
if 'BACKUPCLOUD GESTAO MOVEL HERO - INICIO' not in l or 'backupcloud-gestao-movel-login.jpg?v=2026080712' not in l: raise SystemExit('login HTTP não contém a arte')
if not logo.read_bytes().startswith(b'\x89PNG\r\n\x1a\n'): raise SystemExit('logo nativa HTTP inválida')
print('   HTTP: arte + login + logo nativa OK')
PY
fi
CHANGED=0
echo "============================================================"
echo " SUCESSO - BackupCloud | GESTÃO MÓVEL"
echo " Backup: $BACKUP"
echo " Versão: $VERSION"
echo "============================================================"
