#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

VERSION="2026.08.07.4"
APP="${BC_NETBOX_APP:-/opt/netbox/netbox}"
VENV="${BC_NETBOX_VENV:-/opt/netbox/venv}"
PKG="${BC_NETBOX_PKG:-/opt/netbox/local/ddm-netbox-branding/ddm_netbox_branding}"
SRC="$PKG/static/ddm_netbox_branding/backupcloud-branding.css"
TC="$PKG/template_content.py"
PUBLISHED="$APP/static/ddm_netbox_branding/backupcloud-branding.css"
FQDN="${BC_FQDN:-inventory.bkpcloud.app.br}"
TEST_MODE="${BC_TEST_MODE:-0}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_BASE="${BC_BACKUP_BASE:-/opt/netbox/backups}"
BACKUP="$BACKUP_BASE/backupcloud-netbox-product-hierarchy-v4-${STAMP}"
CHANGED=0

rollback(){
  rc=$?
  trap - ERR
  set +e
  if [[ "$CHANGED" == "1" && -d "$BACKUP" ]]; then
    echo "ROLLBACK: restaurando estado anterior..."
    [[ -f "$BACKUP/backupcloud-branding.css" ]] && cp -a "$BACKUP/backupcloud-branding.css" "$SRC"
    [[ -f "$BACKUP/template_content.py" ]] && cp -a "$BACKUP/template_content.py" "$TC"
    if [[ "$TEST_MODE" != "1" ]]; then
      cd "$APP"
      "$VENV/bin/python" manage.py collectstatic --no-input >/dev/null 2>&1 || true
      systemctl restart netbox netbox-rq >/dev/null 2>&1 || true
    fi
    echo "ROLLBACK concluido: $BACKUP"
  fi
  exit "$rc"
}
trap rollback ERR
fail(){ echo "ERRO: $*" >&2; return 1; }

[[ "$TEST_MODE" == "1" || "$(id -u)" -eq 0 ]] || fail "execute como root"
for c in python3 grep cp mkdir; do command -v "$c" >/dev/null || fail "comando ausente: $c"; done
[[ -s "$SRC" ]] || fail "CSS BackupCloud nao encontrado: $SRC"
[[ -s "$TC" ]] || fail "template_content.py nao encontrado: $TC"

if [[ "$TEST_MODE" != "1" ]]; then
  [[ -x "$VENV/bin/python" ]] || fail "venv do NetBox nao encontrado"
  for svc in netbox netbox-rq nginx; do systemctl is-active --quiet "$svc" || fail "servico $svc nao esta ativo"; done
  cd "$APP"
  NETBOX_VERSION="$($VENV/bin/python manage.py shell -c 'from django.conf import settings; print(settings.VERSION)' 2>/dev/null | tail -n1)"
  [[ "$NETBOX_VERSION" == "4.6.5" ]] || fail "ajuste homologado para NetBox 4.6.5; detectado: $NETBOX_VERSION"
else
  NETBOX_VERSION="4.6.5-test"
fi

echo "============================================================"
echo " BACKUPCLOUD | INVENTARIO - HIERARQUIA FINAL"
echo " Instalador: $VERSION"
echo " NetBox: $NETBOX_VERSION"
echo "============================================================"

echo "[1/6] Validando estado atual - nenhuma alteracao"
grep -q "BACKUPCLOUD INVENTARIO FINAL - INICIO" "$SRC" || fail "tema base BackupCloud nao identificado"
grep -q "BACKUPCLOUD INVENTARIO POLISH V3 - INICIO" "$SRC" || fail "polimento V3 nao identificado; nao vou sobrepor estado desconhecido"
grep -q 'netbox-edition' "$SRC" || fail "seletor do nome do produto nao identificado"
grep -q 'backupcloud-branding.css' "$TC" || fail "template de publicacao nao reconhecido"
echo "   Estrutura: OK"

echo "[2/6] Criando backup"
mkdir -p "$BACKUP"
cp -a "$SRC" "$BACKUP/backupcloud-branding.css"
cp -a "$TC" "$BACKUP/template_content.py"
CHANGED=1
echo "   $BACKUP"

echo "[3/6] Aplicando hierarquia: produto maior que a marca"
python3 - "$SRC" "$TC" <<'PY'
from pathlib import Path
import re,sys
css,tc=map(Path,sys.argv[1:])

s=css.read_text(encoding='utf-8',errors='strict')
s=re.sub(r'/\* === BACKUPCLOUD INVENTARIO HIERARQUIA V4 - INICIO === \*/.*?/\* === BACKUPCLOUD INVENTARIO HIERARQUIA V4 - FIM === \*/\s*','',s,flags=re.S)
s += r'''

/* === BACKUPCLOUD INVENTARIO HIERARQUIA V4 - INICIO === */
/* Somente no login: marca como assinatura e produto como identificacao principal. */
.page-center img.logo.backupcloud-brand-image{
  width:min(285px,54vw)!important;
  max-width:285px!important;
  max-height:none!important;
  height:auto!important;
  margin:0 auto 12px!important;
  object-fit:contain!important;
}
.page-center .netbox-edition{
  display:block!important;
  width:min(900px,94vw)!important;
  max-width:900px!important;
  margin:18px auto 30px!important;
  color:#f7f9ff!important;
  font-size:clamp(46px,5.4vw,70px)!important;
  line-height:1.02!important;
  letter-spacing:.055em!important;
  text-transform:uppercase!important;
  font-weight:700!important;
  text-align:center!important;
  text-shadow:0 3px 18px rgba(0,0,0,.24)!important;
}
.page-center .card{margin-top:0!important}
@media(max-width:760px){
  .page-center img.logo.backupcloud-brand-image{width:min(245px,58vw)!important;max-width:245px!important}
  .page-center .netbox-edition{font-size:clamp(34px,10vw,48px)!important;letter-spacing:.035em!important;margin:14px auto 22px!important}
}
/* === BACKUPCLOUD INVENTARIO HIERARQUIA V4 - FIM === */
'''
css.write_text(s,encoding='utf-8')

s=tc.read_text(encoding='utf-8',errors='strict')
s=re.sub(r'\?v=3\.0\.\d+', '?v=3.0.4', s)
tc.write_text(s,encoding='utf-8')
PY

echo "[4/6] Validando arquivos alterados"
grep -q "BACKUPCLOUD INVENTARIO HIERARQUIA V4 - INICIO" "$SRC" || fail "bloco visual V4 nao foi gravado"
grep -q "font-size:clamp(46px,5.4vw,70px)" "$SRC" || fail "tamanho do produto nao foi aplicado"
grep -q '?v=3.0.4' "$TC" || fail "cache-buster V4 nao foi aplicado"

echo "[5/6] Publicando"
if [[ "$TEST_MODE" != "1" ]]; then
  cd "$APP"
  "$VENV/bin/python" manage.py check
  "$VENV/bin/python" manage.py collectstatic --no-input >/dev/null
  [[ -s "$PUBLISHED" ]] || fail "CSS publicado nao encontrado"
  grep -q "BACKUPCLOUD INVENTARIO HIERARQUIA V4 - INICIO" "$PUBLISHED" || fail "V4 nao chegou ao static publicado"
  systemctl restart netbox netbox-rq
  for svc in netbox netbox-rq nginx; do systemctl is-active --quiet "$svc" || fail "servico $svc nao voltou"; done
fi

echo "[6/6] Validando entrega"
if [[ "$TEST_MODE" != "1" ]]; then
  for _ in $(seq 1 20); do
    if curl -fsS --connect-timeout 5 --max-time 10 "https://${FQDN}/static/ddm_netbox_branding/backupcloud-branding.css?v=3.0.4" 2>/dev/null | grep -q "BACKUPCLOUD INVENTARIO HIERARQUIA V4 - INICIO"; then
      break
    fi
    sleep 2
  done
  curl -fsS --connect-timeout 5 --max-time 10 "https://${FQDN}/static/ddm_netbox_branding/backupcloud-branding.css?v=3.0.4" 2>/dev/null | grep -q "BACKUPCLOUD INVENTARIO HIERARQUIA V4 - INICIO" || fail "CSS V4 nao apareceu via HTTPS"
  curl -fsS --connect-timeout 5 --max-time 10 "https://${FQDN}/login/" 2>/dev/null | grep -q 'backupcloud-branding.css?v=3.0.4' || fail "pagina de login nao referencia o cache V4"
fi

CHANGED=0
trap - ERR

echo
echo "SUCESSO - BACKUPCLOUD | INVENTARIO"
echo "Produto: INVENTARIO em destaque maior que a marca"
echo "Backup: $BACKUP"
