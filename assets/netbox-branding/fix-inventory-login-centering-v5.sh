#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

VERSION="2026.08.07.5"
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
BACKUP="$BACKUP_BASE/backupcloud-netbox-centering-v5-${STAMP}"
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
echo " BACKUPCLOUD | INVENTARIO - CENTRALIZACAO DO LOGIN"
echo " Instalador: $VERSION"
echo " NetBox: $NETBOX_VERSION"
echo "============================================================"

echo "[1/6] Validando estado atual - nenhuma alteracao"
grep -q "BACKUPCLOUD INVENTARIO HIERARQUIA V4 - INICIO" "$SRC" || fail "hierarquia V4 nao identificada; nao vou alterar estado desconhecido"
grep -Eq '\?v=3\.0\.(4|5)' "$TC" || fail "cache V4/V5 nao identificado; nao vou alterar estado desconhecido"
echo "   Estado esperado: OK"

echo "[2/6] Criando backup"
mkdir -p "$BACKUP"
cp -a "$SRC" "$BACKUP/backupcloud-branding.css"
cp -a "$TC" "$BACKUP/template_content.py"
CHANGED=1
echo "   $BACKUP"

echo "[3/6] Corrigindo somente alinhamento/largura do login"
python3 - "$SRC" "$TC" <<'PY'
from pathlib import Path
import re,sys
css,tc=map(Path,sys.argv[1:])

s=css.read_text(encoding='utf-8',errors='strict')
s=re.sub(r'/\* === BACKUPCLOUD INVENTARIO CENTER V5 - INICIO === \*/.*?/\* === BACKUPCLOUD INVENTARIO CENTER V5 - FIM === \*/\s*','',s,flags=re.S)
s += r'''

/* === BACKUPCLOUD INVENTARIO CENTER V5 - INICIO === */
/* Correção cirúrgica somente no login: ocupa todo o viewport e centraliza o conjunto. */
.page.page-center,
.page-center{
  width:100vw!important;
  min-width:100vw!important;
  max-width:none!important;
  min-height:100vh!important;
  margin-left:0!important;
  margin-right:0!important;
  padding-left:0!important;
  padding-right:0!important;
  box-sizing:border-box!important;
  overflow-x:hidden!important;
}
.page-center > .container,
.page-center > .container-fluid,
.page-center > .container-xl,
.page-center > .container-tight{
  margin-left:auto!important;
  margin-right:auto!important;
}
/* === BACKUPCLOUD INVENTARIO CENTER V5 - FIM === */
'''
css.write_text(s,encoding='utf-8')

s=tc.read_text(encoding='utf-8',errors='strict')
s=re.sub(r'\?v=3\.0\.(?:4|5)', '?v=3.0.5', s)
tc.write_text(s,encoding='utf-8')
PY

echo "[4/6] Validando arquivos alterados"
grep -q "BACKUPCLOUD INVENTARIO CENTER V5 - INICIO" "$SRC" || fail "bloco V5 nao foi gravado"
grep -q 'width:100vw!important' "$SRC" || fail "largura integral nao foi aplicada"
grep -q '?v=3.0.5' "$TC" || fail "cache-buster V5 nao foi aplicado"
[[ "$(grep -c 'BACKUPCLOUD INVENTARIO CENTER V5 - INICIO' "$SRC")" -eq 1 ]] || fail "bloco V5 duplicado"

echo "[5/6] Publicando"
if [[ "$TEST_MODE" != "1" ]]; then
  cd "$APP"
  "$VENV/bin/python" manage.py check
  "$VENV/bin/python" manage.py collectstatic --no-input >/dev/null
  [[ -s "$PUBLISHED" ]] || fail "CSS publicado nao encontrado"
  grep -q "BACKUPCLOUD INVENTARIO CENTER V5 - INICIO" "$PUBLISHED" || fail "V5 nao chegou ao static publicado"
  systemctl restart netbox netbox-rq
  for svc in netbox netbox-rq nginx; do systemctl is-active --quiet "$svc" || fail "servico $svc nao voltou"; done
fi

echo "[6/6] Validando entrega"
if [[ "$TEST_MODE" != "1" ]]; then
  for _ in $(seq 1 20); do
    if curl -fsS --connect-timeout 5 --max-time 10 "https://${FQDN}/static/ddm_netbox_branding/backupcloud-branding.css?v=3.0.5" 2>/dev/null | grep -q "BACKUPCLOUD INVENTARIO CENTER V5 - INICIO"; then
      break
    fi
    sleep 2
  done
  curl -fsS --connect-timeout 5 --max-time 10 "https://${FQDN}/static/ddm_netbox_branding/backupcloud-branding.css?v=3.0.5" 2>/dev/null | grep -q "BACKUPCLOUD INVENTARIO CENTER V5 - INICIO" || fail "CSS V5 nao apareceu via HTTPS"
  curl -fsS --connect-timeout 5 --max-time 10 "https://${FQDN}/login/" 2>/dev/null | grep -q 'backupcloud-branding.css?v=3.0.5' || fail "pagina de login nao referencia o cache V5"
fi

CHANGED=0
trap - ERR

echo
echo "SUCESSO - BACKUPCLOUD | INVENTARIO"
echo "Ajuste: login centralizado no viewport inteiro"
echo "Demais elementos: preservados"
echo "Backup: $BACKUP"
