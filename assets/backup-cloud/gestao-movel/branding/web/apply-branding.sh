#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

VERSION="2026.08.07.14"
BASE="${BC_BASE:-/home/suporte}"
TOMCAT="${BC_TOMCAT:-/var/lib/tomcat9}"
CTX="$TOMCAT/conf/Catalina/localhost/ROOT.xml"
WEB="$TOMCAT/webapps/ROOT"
CSS="$WEB/css/main.css"
LOGIN="$WEB/app/components/main/view/login.html"
INDEX="$WEB/index.html"
APPJS="$WEB/app/app.js"
REBRANDING_JS="$WEB/app/shared/service/rebranding.service.js"
PT="$WEB/localization/pt_PT.js"
ASSETS="$WEB/images/backup-cloud"
LOGO="$ASSETS/backup-cloud-logo.png"
RAW="${BC_RAW_BASE:-https://raw.githubusercontent.com/bkpcloud-app/snoc/main/assets/backup-cloud/gestao-movel/branding/web}"
TEST_MODE="${BC_TEST_MODE:-0}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BASE/BACKUP-CLOUD-GESTAO-MOVEL-BRANDING-BACKUP-$STAMP"
TMP="$(mktemp -d /tmp/bc-mdm-branding.XXXXXX)"
CHANGED=0

FILES=("$CTX" "$CSS" "$LOGIN" "$INDEX" "$APPJS" "$REBRANDING_JS" "$PT")

cleanup(){ rm -rf "$TMP"; }
rollback(){
  [ "$CHANGED" = 1 ] || return 0
  echo "ROLLBACK: restaurando backup..."
  for f in "${FILES[@]}"; do
    rel="${f#$TOMCAT/}"
    src="$BACKUP/$rel"
    [ -f "$src" ] && { mkdir -p "$(dirname "$f")"; cp -a "$src" "$f"; }
  done
  rm -rf "$ASSETS"
  [ -d "$BACKUP/webapps/ROOT/images/backup-cloud" ] && cp -a "$BACKUP/webapps/ROOT/images/backup-cloud" "$ASSETS"
  [ "$TEST_MODE" = 1 ] || systemctl restart tomcat9 >/dev/null 2>&1 || true
  CHANGED=0
  echo "ROLLBACK concluído."
}
trap cleanup EXIT
trap 'r=$?; [ $r -eq 0 ] || rollback; exit $r' ERR
fail(){ echo "ERRO: $*" >&2; rollback; exit 1; }
fetch(){ curl -fLsS --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 90 "$1" -o "$2"; }

[ "$TEST_MODE" = 1 ] || [ "$(id -u)" = 0 ] || fail "execute como root"
for c in curl python3 cp rm mkdir install sha256sum; do command -v "$c" >/dev/null || fail "comando ausente: $c"; done
for f in "${FILES[@]}"; do [ -s "$f" ] || fail "arquivo não encontrado: $f"; done
if [ "$TEST_MODE" != 1 ]; then
  systemctl is-active --quiet tomcat9 || fail "tomcat9 não está ativo"
  systemctl is-active --quiet nginx || fail "nginx não está ativo"
fi

echo "============================================================"
echo " BackupCloud | GESTÃO MÓVEL"
echo " Instalador: $VERSION"
echo "============================================================"

echo "[1/7] Pré-validando logo - nenhuma alteração no servidor"
fetch "$RAW/backup-cloud-logo-dark-transparent.png.b64" "$TMP/logo.b64" || fail "falha ao baixar logo"
python3 - "$TMP/logo.b64" "$TMP/logo.png" <<'PY'
from pathlib import Path
import base64,re,struct,sys,hashlib
src,dst=sys.argv[1:]
s=re.sub(r'\s+','',Path(src).read_text(encoding='ascii'))
if not re.fullmatch(r'[A-Za-z0-9+/]*={0,2}',s) or len(s)%4:
    raise SystemExit('Base64 da logo inválido')
b=base64.b64decode(s,validate=True)
if not b.startswith(b'\x89PNG\r\n\x1a\n') or b[12:16] != b'IHDR' or b'IEND' not in b[-64:]:
    raise SystemExit('logo PNG inválido')
w,h=struct.unpack('>II',b[16:24])
Path(dst).write_bytes(b)
print(f'   Logo OK: {w}x{h} | {len(b)} bytes | SHA-256 {hashlib.sha256(b).hexdigest()}')
PY

echo "[2/7] Validando estrutura atual"
python3 - "${FILES[@]}" <<'PY'
from pathlib import Path
import sys,xml.etree.ElementTree as ET
ctx,css,login,index,appjs,rebrand,pt=map(Path,sys.argv[1:])
ET.parse(ctx)
for p in (css,login,index,appjs,rebrand,pt):
    p.read_text(encoding='utf-8',errors='strict')
if 'class="login-logo"' not in login.read_text(encoding='utf-8') and "class='login-logo'" not in login.read_text(encoding='utf-8'):
    raise SystemExit('estrutura login-logo não reconhecida')
print('   Estrutura: OK')
PY

echo "[3/7] Criando backup"
mkdir -p "$BACKUP"
for f in "${FILES[@]}"; do
  rel="${f#$TOMCAT/}"
  mkdir -p "$BACKUP/$(dirname "$rel")"
  cp -a "$f" "$BACKUP/$rel"
done
[ -d "$ASSETS" ] && { mkdir -p "$BACKUP/webapps/ROOT/images"; cp -a "$ASSETS" "$BACKUP/webapps/ROOT/images/backup-cloud"; }
echo "   $BACKUP"
CHANGED=1

echo "[4/7] Aplicando identidade nativa e logo transparente"
install -d -m 0755 "$ASSETS"
install -m 0644 "$TMP/logo.png" "$LOGO"
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

echo "[5/7] Corrigindo login, nomes antigos, tradução e cache de branding"
python3 - "$WEB" "$LOGIN" "$INDEX" "$APPJS" "$REBRANDING_JS" "$PT" <<'PY'
from pathlib import Path
import re,sys
web,login,index,appjs,rebrand,pt=map(Path,sys.argv[1:])
ver='2026080714'

s=login.read_text(encoding='utf-8')
s=re.sub(r'<!-- BACKUPCLOUD GESTAO MOVEL HERO - INICIO -->.*?<!-- BACKUPCLOUD GESTAO MOVEL HERO - FIM -->\s*','',s,flags=re.S)
s=re.sub(r'<!-- BACKUPCLOUD GESTAO MOVEL LOGO - INICIO -->.*?<!-- BACKUPCLOUD GESTAO MOVEL LOGO - FIM -->\s*','',s,flags=re.S)
pat=re.compile(r'<div\s+class=["\']login-logo["\'][^>]*>.*?</div>',re.S|re.I)
replacement=f'''<!-- BACKUPCLOUD GESTAO MOVEL LOGO - INICIO -->\n<div class="login-logo bc-login-logo" ng-if="rebranding">\n  <img src="/images/backup-cloud/backup-cloud-logo.png?bc={ver}" alt="BackupCloud">\n  <span class="bc-product-name">Gestão Móvel</span>\n</div>\n<!-- BACKUPCLOUD GESTAO MOVEL LOGO - FIM -->'''
if not pat.search(s):
    raise SystemExit('bloco login-logo não encontrado')
s=pat.sub(replacement,s,count=1)
s=re.sub(r'<div\s+class=["\']login-footer["\'][^>]*>.*?</div>',
         '<div class="login-footer bc-login-footer"><span>BackupCloud | Gestão Móvel</span> · © {{rebranding.year}} <a href="https://bkpcloud.app.br">BackupCloud</a></div>',
         s,count=1,flags=re.S|re.I)
login.write_text(s,encoding='utf-8')

s=pt.read_text(encoding='utf-8')
if "'button.group.action'" not in s:
    marker=re.search(r"^(\s*)'button\.set\.group'\s*:\s*[^\n]+$",s,re.M)
    if marker:
        pos=marker.end()
        s=s[:pos]+"\n"+marker.group(1)+"'button.group.action': 'Ações em grupo',"+s[pos:]
    else:
        raise SystemExit('ponto para button.group.action não encontrado em pt_PT.js')
s=re.sub(r"('app\.name'\s*:\s*)'[^']*'",r"\1'BackupCloud | Gestão Móvel'",s)
s=re.sub(r"('app\.vendor\.name'\s*:\s*)'[^']*'",r"\1'BackupCloud'",s)
s=re.sub(r"('app\.vendor\.link'\s*:\s*)'[^']*'",r"\1'https://bkpcloud.app.br'",s)
pt.write_text(s,encoding='utf-8')

s=rebrand.read_text(encoding='utf-8')
s=s.replace("$cookies.get('rebranding')", "$cookies.get('rebranding_backupcloud_v2')")
s=s.replace("$cookies.put('rebranding',", "$cookies.put('rebranding_backupcloud_v2',")
rebrand.write_text(s,encoding='utf-8')

s=index.read_text(encoding='utf-8')
s=re.sub(r"localization/pt_PT\.js(?:\?[^'\"]*)?",f"localization/pt_PT.js?bc={ver}",s)
s=re.sub(r"app/shared/service/rebranding\.service\.js(?:\?[^'\"]*)?",f"app/shared/service/rebranding.service.js?bc={ver}",s)
s=re.sub(r"css/main\.css(?:\?[^'\"]*)?",f"css/main.css?bc={ver}",s)
s=re.sub(r'<title>.*?</title>', '<title>BackupCloud | Gestão Móvel</title>', s, count=1, flags=re.S|re.I)
clear="<script>document.cookie='rebranding=; Max-Age=0; path=/';</script>"
if clear not in s:
    s=s.replace("<meta charset='UTF-8'>", "<meta charset='UTF-8'>\n    "+clear,1)
index.write_text(s,encoding='utf-8')

s=appjs.read_text(encoding='utf-8')
s=re.sub(r"app/components/main/view/login\.html(?:\?[^'\"]*)?",f"app/components/main/view/login.html?bc={ver}",s)
appjs.write_text(s,encoding='utf-8')

replacements={
    'DDM Gestão Móvel':'BackupCloud | Gestão Móvel',
    'DDM Gestao Movel':'BackupCloud | Gestão Móvel',
    'DDMTI Soluções':'BackupCloud',
    'DDMTI Solucoes':'BackupCloud'
}
allowed={'.html','.js','.css','.xml','.txt'}
changed=0
for p in web.rglob('*'):
    if not p.is_file() or p.suffix.lower() not in allowed:
        continue
    try: data=p.read_text(encoding='utf-8')
    except Exception: continue
    new=data
    for a,b in replacements.items(): new=new.replace(a,b)
    if new!=data:
        p.write_text(new,encoding='utf-8'); changed+=1
print(f'   Login/tradução/cache/textos: OK | arquivos antigos corrigidos: {changed}')
PY

echo "[6/7] Aplicando tema final mais claro"
python3 - "$CSS" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8',errors='strict')
patterns=[
 ('DDM GESTAO MOVEL - INICIO','DDM GESTAO MOVEL - FIM'),
 ('DDM GESTAO MOVEL - PRODUCAO - INICIO','DDM GESTAO MOVEL - PRODUCAO - FIM'),
 ('DDM POLIMENTO PRODUCAO - INICIO','DDM POLIMENTO PRODUCAO - FIM'),
 ('BACKUP CLOUD GESTAO MOVEL - INICIO','BACKUP CLOUD GESTAO MOVEL - FIM'),
 ('BACKUPCLOUD GESTAO MOVEL - INICIO','BACKUPCLOUD GESTAO MOVEL - FIM'),
 ('BACKUPCLOUD GESTAO MOVEL FINAL - INICIO','BACKUPCLOUD GESTAO MOVEL FINAL - FIM')
]
for a,b in patterns:
    s=re.sub(r'/\* === '+re.escape(a)+r' === \*/.*?/\* === '+re.escape(b)+r' === \*/','',s,flags=re.S)
s=re.sub(r'/\* ================================\s*HOTFIX BackupCloud \| Gestão Móvel\s*=============================== \*/.*\Z','',s,flags=re.S)
block=r'''/* === BACKUPCLOUD GESTAO MOVEL FINAL - INICIO === */
:root{
  --bc-bg:#111a2c;--bc-bg2:#182640;--bc-panel:#243552;--bc-panel2:#1d2c47;
  --bc-purple:#5659c7;--bc-blue:#3578f6;--bc-text:#e8eef9;--bc-muted:#aebbd0;
  --bc-border:rgba(148,163,184,.28)
}
html,body{min-height:100%!important;color:var(--bc-text)!important;background:radial-gradient(circle at 16% 22%,rgba(86,89,199,.34),transparent 31%),radial-gradient(circle at 82% 70%,rgba(53,120,246,.22),transparent 34%),linear-gradient(135deg,var(--bc-bg) 0%,var(--bc-bg2) 52%,#25295c 100%) fixed!important}
.header{background:linear-gradient(90deg,#111a2c,#182640 60%,#25295c)!important;border-color:rgba(148,163,184,.15)!important;box-shadow:0 2px 12px rgba(4,9,20,.22)!important}.header a,.header .logo-text a{color:#f8fbff!important}.header .logo-text a{font-weight:500!important}
.content-wrapper,.fullscreen,.administration,.container,.container-fluid,.tab-content{color:var(--bc-text)!important;background:transparent!important}
.nav-tabs{border-color:rgba(148,163,184,.28)!important}.nav-tabs>li>a{color:#8fc4f6!important;border-color:transparent!important}.nav-tabs>li>a:hover{background:rgba(255,255,255,.08)!important}.nav-tabs>li.active>a,.nav-tabs>li.active>a:hover,.nav-tabs>li.active>a:focus{background:#f8fafc!important;color:#1e293b!important;border-color:#dbe4f0!important}
.table{color:var(--bc-text)!important;background:transparent!important}.table>thead>tr>th{color:#d8e3f3!important;border-bottom:1px solid rgba(203,213,225,.42)!important}.table>tbody>tr>td{color:#dfe8f5!important;border-top:1px solid rgba(148,163,184,.18)!important}.table>tbody>tr:hover{background:rgba(255,255,255,.045)!important}.table a{color:#64b5f6!important}
label,.control-label{color:#e0e8f4!important}.list-desc,.field-hint,.configuration-hint{color:var(--bc-muted)!important}
.form-control,input.form-control,select.form-control,textarea.form-control{background:rgba(248,250,252,.96)!important;color:#24324a!important;border:1px solid #bac8da!important;border-radius:6px!important;box-shadow:none!important}.form-control::placeholder{color:#6b7b91!important}.form-control:focus{border-color:#6e8cff!important;box-shadow:0 0 0 3px rgba(86,89,199,.15)!important}
.btn-primary,.login .btn-default{background:linear-gradient(90deg,var(--bc-blue),var(--bc-purple))!important;border-color:transparent!important;color:#fff!important;border-radius:7px!important;font-weight:600!important}.btn-default{border-radius:6px!important}
.panel,.panel-default,.well,.modal-content{border-color:var(--bc-border)!important}.panel:not(.login)>.panel-body,.well{background:rgba(36,53,82,.82)!important;color:var(--bc-text)!important}
.bc-login-logo{display:flex!important;flex-direction:column!important;align-items:center!important;justify-content:center!important;width:min(430px,78vw)!important;max-width:430px!important;margin:42px auto 18px!important;white-space:normal!important;background:transparent!important;border:0!important;box-shadow:none!important}
.bc-login-logo img{display:block!important;width:min(360px,68vw)!important;max-width:360px!important;height:auto!important;margin:0 auto!important;background:transparent!important;border:0!important;box-shadow:none!important;object-fit:contain!important}.bc-product-name{margin-top:5px!important;color:#cfd7e6!important;font-size:14px!important;letter-spacing:.28em!important;text-transform:uppercase!important;font-weight:500!important}
.login{width:500px!important;margin:18px auto 0!important;border:1px solid rgba(153,170,205,.46)!important;border-top:2px solid #7377e6!important;border-radius:12px!important;overflow:hidden!important;box-shadow:0 20px 52px rgba(0,0,0,.24)!important}.login .panel-body{background:rgba(36,53,82,.94)!important;padding:30px 36px!important}.login label{color:#eef4ff!important}.login .form-control{height:44px!important;background:#f8fafc!important;color:#26364e!important;border-color:#aebed2!important}
.login-footer{color:#aebbd0!important;border-top-color:rgba(203,213,225,.28)!important}.login-footer a{color:#91c9ff!important}
@media(max-width:760px){.bc-login-logo{width:calc(100% - 28px)!important;margin:28px auto 12px!important}.bc-login-logo img{width:min(320px,72vw)!important}.login{width:calc(100% - 24px)!important;margin:12px auto!important}.login .panel-body{padding:24px 20px!important}.bc-product-name{font-size:12px!important;letter-spacing:.2em!important}}
/* === BACKUPCLOUD GESTAO MOVEL FINAL - FIM === */'''
p.write_text(s.rstrip()+'\n\n'+block+'\n',encoding='utf-8')
if p.read_text(encoding='utf-8').count('BACKUPCLOUD GESTAO MOVEL FINAL - INICIO')!=1:
    raise SystemExit('bloco CSS final duplicado')
print('   CSS final: OK')
PY

if [ "$TEST_MODE" != 1 ]; then
  echo "[7/7] Reiniciando e validando aplicação"
  systemctl restart tomcat9
  ok=0
  for _ in $(seq 1 90); do
    code="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/ 2>/dev/null || true)"
    case "$code" in 200|301|302|303|307|308|401|403) ok=1; break;; esac
    sleep 1
  done
  [ "$ok" = 1 ] || fail "aplicação não respondeu após o restart"
else
  echo "[7/7] Validação em modo de teste"
fi

python3 - "$CTX" "$CSS" "$LOGIN" "$INDEX" "$APPJS" "$REBRANDING_JS" "$PT" "$LOGO" <<'PY'
from pathlib import Path
import sys,xml.etree.ElementTree as ET
ctx,css,login,index,appjs,rebrand,pt,logo=map(Path,sys.argv[1:])
ET.parse(ctx)
x=ctx.read_text(encoding='utf-8')
for item in [
 'name="rebranding.name" value="BackupCloud | Gestão Móvel"',
 'name="rebranding.vendor.name" value="BackupCloud"',
 'name="rebranding.logo" value="'+str(logo)+'"',
 'name="rebranding.mobile.name" value="Gestão Móvel"']:
    if item not in x: raise SystemExit('configuração ausente: '+item)
if not logo.read_bytes().startswith(b'\x89PNG\r\n\x1a\n'): raise SystemExit('logo instalada inválida')
l=login.read_text(encoding='utf-8')
if l.count('BACKUPCLOUD GESTAO MOVEL LOGO - INICIO')!=1: raise SystemExit('logo do login não foi fixada')
if 'backupcloud-gestao-movel-login' in l: raise SystemExit('arte grande ainda referenciada no login')
if 'BackupCloud | Gestão Móvel' not in l: raise SystemExit('rodapé BackupCloud ausente')
if "'button.group.action': 'Ações em grupo'" not in pt.read_text(encoding='utf-8'): raise SystemExit('tradução button.group.action ausente')
if 'rebranding_backupcloud_v2' not in rebrand.read_text(encoding='utf-8'): raise SystemExit('cache de rebranding não foi versionado')
if 'BACKUPCLOUD GESTAO MOVEL FINAL - INICIO' not in css.read_text(encoding='utf-8'): raise SystemExit('CSS final ausente')
for p in (login,index,appjs,rebrand,pt):
    data=p.read_text(encoding='utf-8',errors='ignore')
    if 'DDM Gestão Móvel' in data or 'DDMTI Soluções' in data:
        raise SystemExit('branding antigo ainda presente em '+str(p))
print('   Arquivos finais: OK')
PY

if [ "$TEST_MODE" != 1 ]; then
  fetch "http://127.0.0.1:8080/rest/public/name?bc=2026080714" "$TMP/live-name.json" || fail "API de branding não respondeu"
  fetch "http://127.0.0.1:8080/rest/public/logo?bc=2026080714" "$TMP/live-logo.png" || fail "logo nativa não é servida"
  fetch "http://127.0.0.1:8080/app/components/main/view/login.html?bc=2026080714" "$TMP/live-login.html" || fail "login.html não é servido"
  python3 - "$TMP/live-name.json" "$TMP/live-logo.png" "$TMP/live-login.html" <<'PY'
from pathlib import Path
import json,sys
name,logo,login=map(Path,sys.argv[1:])
j=json.loads(name.read_text(encoding='utf-8'))
raw=json.dumps(j,ensure_ascii=False)
if 'BackupCloud | Gestão Móvel' not in raw or 'BackupCloud' not in raw:
    raise SystemExit('API ainda não devolve a marca BackupCloud')
if not logo.read_bytes().startswith(b'\x89PNG\r\n\x1a\n'):
    raise SystemExit('logo HTTP inválida')
l=login.read_text(encoding='utf-8')
if 'BACKUPCLOUD GESTAO MOVEL LOGO - INICIO' not in l or 'backupcloud-gestao-movel-login' in l:
    raise SystemExit('login HTTP não contém a versão final')
print('   HTTP: nome + logo transparente + login final OK')
PY
fi

CHANGED=0
echo "============================================================"
echo " SUCESSO - BackupCloud | GESTÃO MÓVEL"
echo " Backup: $BACKUP"
echo " Versão: $VERSION"
echo "============================================================"
