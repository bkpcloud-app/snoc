#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

VERSION="2026.08.07.15"
TOMCAT="${BC_TOMCAT:-/var/lib/tomcat9}"
WEB="$TOMCAT/webapps/ROOT"
CSS="$WEB/css/main.css"
LOGIN="$WEB/app/components/main/view/login.html"
INDEX="$WEB/index.html"
APPJS="$WEB/app/app.js"
FQDN="${BC_FQDN:-mobgw.bkpcloud.app.br}"
TEST_MODE="${BC_TEST_MODE:-0}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_BASE="${BC_BACKUP_BASE:-/home/suporte}"
BACKUP="$BACKUP_BASE/BACKUP-CLOUD-GESTAO-MOVEL-HIERARCHY-$STAMP"
EXPECTED_CSS_SHA="${BC_EXPECTED_CSS_SHA:-3f37c65a3fe1c29edfa275441ad6d3d2778ae26b97c2c9491204b9834e7d7582}"
CHANGED=0

files=("$CSS" "$LOGIN" "$INDEX" "$APPJS")

rollback(){
  rc=$?
  trap - ERR
  set +e
  if [[ "$CHANGED" == "1" && -d "$BACKUP" ]]; then
    echo "ROLLBACK: restaurando estado anterior..."
    for f in "${files[@]}"; do
      rel="${f#$TOMCAT/}"
      [[ -f "$BACKUP/$rel" ]] && cp -a "$BACKUP/$rel" "$f"
    done
    [[ "$TEST_MODE" == "1" ]] || systemctl restart tomcat9 >/dev/null 2>&1 || true
    echo "ROLLBACK concluido: $BACKUP"
  fi
  exit "$rc"
}
trap rollback ERR

fail(){ echo "ERRO: $*" >&2; return 1; }

[[ "$TEST_MODE" == "1" || "$(id -u)" -eq 0 ]] || fail "execute como root"
for c in python3 sha256sum grep cp mkdir; do command -v "$c" >/dev/null || fail "comando ausente: $c"; done
for f in "${files[@]}"; do [[ -s "$f" ]] || fail "arquivo ausente: $f"; done

if [[ "$TEST_MODE" != "1" ]]; then
  systemctl is-active --quiet tomcat9 || fail "tomcat9 nao esta ativo"
  systemctl is-active --quiet nginx || fail "nginx nao esta ativo"
fi

echo "============================================================"
echo " BACKUPCLOUD | GESTAO MOVEL - HIERARQUIA FINAL"
echo " Instalador: $VERSION"
echo "============================================================"

echo "[1/6] Validando estado atual - nenhuma alteracao"
grep -q "BACKUPCLOUD GESTAO MOVEL FINAL - INICIO" "$CSS" || fail "tema BackupCloud v14 nao identificado"
grep -q '<span class="bc-product-name">Gestão Móvel</span>' "$LOGIN" || fail "titulo Gestão Móvel nao identificado no login"
CURRENT_SHA="$(sha256sum "$CSS" | awk '{print $1}')"
if ! grep -q "BACKUPCLOUD PRODUTO HIERARQUIA V15 - INICIO" "$CSS" && [[ "$CURRENT_SHA" != "$EXPECTED_CSS_SHA" ]]; then
  fail "main.css divergiu da coleta aprovada (atual: $CURRENT_SHA)"
fi
echo "   Estrutura OK | CSS SHA-256: $CURRENT_SHA"

echo "[2/6] Criando backup"
mkdir -p "$BACKUP"
for f in "${files[@]}"; do
  rel="${f#$TOMCAT/}"
  mkdir -p "$BACKUP/$(dirname "$rel")"
  cp -a "$f" "$BACKUP/$rel"
done
CHANGED=1
echo "   $BACKUP"

echo "[3/6] Aplicando hierarquia: produto maior que a marca"
python3 - "$CSS" "$LOGIN" "$INDEX" "$APPJS" <<'PY'
from pathlib import Path
import re,sys
css,login,index,appjs=map(Path,sys.argv[1:])
ver='2026080715'

s=css.read_text(encoding='utf-8',errors='strict')
s=re.sub(r'/\* === BACKUPCLOUD PRODUTO HIERARQUIA V15 - INICIO === \*/.*?/\* === BACKUPCLOUD PRODUTO HIERARQUIA V15 - FIM === \*/\s*','',s,flags=re.S)
s += r'''

/* === BACKUPCLOUD PRODUTO HIERARQUIA V15 - INICIO === */
/* A marca assina; o produto identifica a aplicacao. */
.bc-login-logo{
  width:min(760px,94vw)!important;
  max-width:760px!important;
  margin:28px auto 12px!important;
}
.bc-login-logo img{
  width:min(285px,54vw)!important;
  max-width:285px!important;
  height:auto!important;
  margin:0 auto!important;
}
.bc-product-name{
  display:block!important;
  margin:18px auto 0!important;
  color:#f7f9ff!important;
  font-size:clamp(42px,5.2vw,66px)!important;
  line-height:1.03!important;
  letter-spacing:.055em!important;
  text-transform:uppercase!important;
  font-weight:700!important;
  text-align:center!important;
  text-shadow:0 3px 18px rgba(0,0,0,.24)!important;
}
.login{margin-top:18px!important}
@media(max-width:760px){
  .bc-login-logo{width:calc(100% - 24px)!important;margin:22px auto 10px!important}
  .bc-login-logo img{width:min(245px,58vw)!important;max-width:245px!important}
  .bc-product-name{font-size:clamp(32px,9vw,46px)!important;letter-spacing:.035em!important;margin-top:14px!important}
  .login{margin-top:14px!important}
}
/* === BACKUPCLOUD PRODUTO HIERARQUIA V15 - FIM === */
'''
css.write_text(s,encoding='utf-8')

s=login.read_text(encoding='utf-8',errors='strict')
s=re.sub(r'backup-cloud-logo\.png\?bc=\d+',f'backup-cloud-logo.png?bc={ver}',s)
login.write_text(s,encoding='utf-8')

s=index.read_text(encoding='utf-8',errors='strict')
s=re.sub(r'css/main\.css(?:\?[^\'\"]*)?',f'css/main.css?bc={ver}',s)
index.write_text(s,encoding='utf-8')

s=appjs.read_text(encoding='utf-8',errors='strict')
s=re.sub(r'app/components/main/view/login\.html(?:\?[^\'\"]*)?',f'app/components/main/view/login.html?bc={ver}',s)
appjs.write_text(s,encoding='utf-8')
PY

echo "[4/6] Validando arquivos alterados"
grep -q "BACKUPCLOUD PRODUTO HIERARQUIA V15 - INICIO" "$CSS" || fail "bloco visual final nao foi gravado"
grep -q "font-size:clamp(42px,5.2vw,66px)" "$CSS" || fail "tamanho do produto nao foi aplicado"
grep -q "backup-cloud-logo.png?bc=2026080715" "$LOGIN" || fail "cache da logo nao foi atualizado"
grep -q "css/main.css?bc=2026080715" "$INDEX" || fail "cache do CSS nao foi atualizado"
grep -q "login.html?bc=2026080715" "$APPJS" || fail "cache do login nao foi atualizado"
NEW_SHA="$(sha256sum "$CSS" | awk '{print $1}')"
echo "   CSS final SHA-256: $NEW_SHA"

echo "[5/6] Publicando"
if [[ "$TEST_MODE" != "1" ]]; then
  systemctl restart tomcat9
  systemctl is-active --quiet tomcat9 || fail "tomcat9 nao voltou"
fi

echo "[6/6] Validando entrega"
if [[ "$TEST_MODE" != "1" ]]; then
  for _ in $(seq 1 20); do
    if curl -fsS --connect-timeout 5 --max-time 10 "https://${FQDN}/css/main.css?bc=2026080715" 2>/dev/null | grep -q "BACKUPCLOUD PRODUTO HIERARQUIA V15 - INICIO"; then
      break
    fi
    sleep 2
  done
  curl -fsS --connect-timeout 5 --max-time 10 "https://${FQDN}/css/main.css?bc=2026080715" 2>/dev/null | grep -q "BACKUPCLOUD PRODUTO HIERARQUIA V15 - INICIO" || fail "CSS final nao apareceu via HTTPS"
  curl -fsS --connect-timeout 5 --max-time 10 "https://${FQDN}/app/components/main/view/login.html?bc=2026080715" 2>/dev/null | grep -q "bc-product-name" || fail "login final nao apareceu via HTTPS"
fi

CHANGED=0
trap - ERR

echo
echo "SUCESSO - BACKUPCLOUD | GESTAO MOVEL"
echo "Produto: GESTAO MOVEL em destaque maior que a marca"
echo "Backup: $BACKUP"
