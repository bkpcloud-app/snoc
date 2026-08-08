#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

VERSION="2026.08.07.6"
APP="${BC_NETBOX_APP:-/opt/netbox/netbox}"
VENV="${BC_NETBOX_VENV:-/opt/netbox/venv}"
PKG="${BC_NETBOX_PKG:-/opt/netbox/local/ddm-netbox-branding/ddm_netbox_branding}"
SRC="$PKG/static/ddm_netbox_branding/backupcloud-branding.css"
TC="$PKG/template_content.py"
PUBLISHED="$APP/static/ddm_netbox_branding/backupcloud-branding.css"
FQDN="${BC_FQDN:-inventory.bkpcloud.app.br}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_BASE="${BC_BACKUP_BASE:-/opt/netbox/backups}"
BACKUP="$BACKUP_BASE/backupcloud-netbox-centering-v6-${STAMP}"
CHANGED=0

rollback(){
  rc=$?
  trap - ERR
  set +e
  if [[ "$CHANGED" == "1" && -d "$BACKUP" ]]; then
    echo "ROLLBACK: restaurando estado anterior..."
    [[ -f "$BACKUP/backupcloud-branding.css" ]] && cp -a "$BACKUP/backupcloud-branding.css" "$SRC"
    [[ -f "$BACKUP/template_content.py" ]] && cp -a "$BACKUP/template_content.py" "$TC"
    cd "$APP"
    "$VENV/bin/python" manage.py collectstatic --no-input >/dev/null 2>&1 || true
    systemctl restart netbox netbox-rq >/dev/null 2>&1 || true
    echo "ROLLBACK concluido: $BACKUP"
  fi
  exit "$rc"
}
trap rollback ERR
fail(){ echo "ERRO: $*" >&2; return 1; }

[[ "$(id -u)" -eq 0 ]] || fail "execute como root"
for c in python3 grep cp mkdir curl; do command -v "$c" >/dev/null || fail "comando ausente: $c"; done
[[ -x "$VENV/bin/python" ]] || fail "venv do NetBox nao encontrado"
[[ -s "$SRC" ]] || fail "CSS BackupCloud nao encontrado: $SRC"
[[ -s "$TC" ]] || fail "template_content.py nao encontrado: $TC"
for svc in netbox netbox-rq nginx; do systemctl is-active --quiet "$svc" || fail "servico $svc nao esta ativo"; done

cd "$APP"
NETBOX_VERSION="$($VENV/bin/python manage.py shell -c 'from django.conf import settings; print(settings.VERSION)' 2>/dev/null | tail -n1)"
[[ "$NETBOX_VERSION" == "4.6.5" ]] || fail "ajuste homologado para NetBox 4.6.5; detectado: $NETBOX_VERSION"

echo "============================================================"
echo " BACKUPCLOUD | INVENTARIO - CENTRALIZACAO CIRURGICA"
echo " Instalador: $VERSION"
echo " NetBox: $NETBOX_VERSION"
echo "============================================================"

echo "[1/6] Validando base atual - nenhuma alteracao"
grep -q "BACKUPCLOUD INVENTARIO FINAL - INICIO" "$SRC" || fail "tema base BackupCloud nao identificado"
grep -q "BACKUPCLOUD INVENTARIO POLISH V3 - INICIO" "$SRC" || fail "polimento V3 nao identificado"
grep -q 'netbox-edition' "$SRC" || fail "seletor do produto nao identificado"
grep -q 'backupcloud-branding.css' "$TC" || fail "template de publicacao nao reconhecido"
echo "   Base atual: OK"

echo "[2/6] Criando backup"
mkdir -p "$BACKUP"
cp -a "$SRC" "$BACKUP/backupcloud-branding.css"
cp -a "$TC" "$BACKUP/template_content.py"
CHANGED=1
echo "   $BACKUP"

echo "[3/6] Corrigindo somente a centralizacao horizontal do login"
python3 - "$SRC" "$TC" <<'PY'
from pathlib import Path
import re,sys
css,tc=map(Path,sys.argv[1:])

s=css.read_text(encoding='utf-8',errors='strict')
s=re.sub(r'/\* === BACKUPCLOUD INVENTARIO CENTER V[56] - INICIO === \*/.*?/\* === BACKUPCLOUD INVENTARIO CENTER V[56] - FIM === \*/\s*','',s,flags=re.S)
s += r'''

/* === BACKUPCLOUD INVENTARIO CENTER V6 - INICIO === */
/* Somente login: neutraliza a largura deslocada e centraliza o conjunto no viewport. */
body > .page.page-center,
body > .page-center,
.page.page-center{
  width:100%!important;
  max-width:none!important;
  min-height:100vh!important;
  margin-left:0!important;
  margin-right:0!important;
  padding-left:0!important;
  padding-right:0!important;
  position:relative!important;
  left:auto!important;
  right:auto!important;
  transform:none!important;
  box-sizing:border-box!important;
}
.page-center > .container,
.page-center > .container-fluid,
.page-center > .container-xl,
.page-center > .container-tight{
  width:100%!important;
  max-width:100%!important;
  margin-left:auto!important;
  margin-right:auto!important;
  padding-left:16px!important;
  padding-right:16px!important;
  box-sizing:border-box!important;
}
.page-center img.logo.backupcloud-brand-image,
.page-center .netbox-edition,
.page-center .card{
  margin-left:auto!important;
  margin-right:auto!important;
}
html,body{
  width:100%!important;
  max-width:100%!important;
  margin-left:0!important;
  margin-right:0!important;
  overflow-x:hidden!important;
}
/* === BACKUPCLOUD INVENTARIO CENTER V6 - FIM === */
'''
css.write_text(s,encoding='utf-8')

s=tc.read_text(encoding='utf-8',errors='strict')
s=re.sub(r'\?v=3\.0\.\d+', '?v=3.0.6', s)
tc.write_text(s,encoding='utf-8')
PY

echo "[4/6] Validando arquivos alterados"
grep -q "BACKUPCLOUD INVENTARIO CENTER V6 - INICIO" "$SRC" || fail "bloco V6 nao foi gravado"
grep -q 'body > .page.page-center' "$SRC" || fail "regra de centralizacao nao foi aplicada"
grep -q '?v=3.0.6' "$TC" || fail "cache-buster V6 nao foi aplicado"

echo "[5/6] Publicando"
"$VENV/bin/python" manage.py check
"$VENV/bin/python" manage.py collectstatic --no-input >/dev/null
[[ -s "$PUBLISHED" ]] || fail "CSS publicado nao encontrado"
grep -q "BACKUPCLOUD INVENTARIO CENTER V6 - INICIO" "$PUBLISHED" || fail "V6 nao chegou ao static publicado"
systemctl restart netbox netbox-rq
for svc in netbox netbox-rq nginx; do systemctl is-active --quiet "$svc" || fail "servico $svc nao voltou"; done

echo "[6/6] Validando entrega HTTPS"
for _ in $(seq 1 20); do
  if curl -fsS --connect-timeout 5 --max-time 10 "https://${FQDN}/static/ddm_netbox_branding/backupcloud-branding.css?v=3.0.6" 2>/dev/null | grep -q "BACKUPCLOUD INVENTARIO CENTER V6 - INICIO"; then
    break
  fi
  sleep 2
done
curl -fsS --connect-timeout 5 --max-time 10 "https://${FQDN}/static/ddm_netbox_branding/backupcloud-branding.css?v=3.0.6" 2>/dev/null | grep -q "BACKUPCLOUD INVENTARIO CENTER V6 - INICIO" || fail "CSS V6 nao apareceu via HTTPS"
curl -fsS --connect-timeout 5 --max-time 10 "https://${FQDN}/login/" 2>/dev/null | grep -q 'backupcloud-branding.css?v=3.0.6' || fail "pagina de login nao referencia o cache V6"

CHANGED=0
trap - ERR

echo
echo "SUCESSO - BACKUPCLOUD | INVENTARIO"
echo "Ajuste: somente centralizacao horizontal do login"
echo "Demais elementos: preservados"
echo "Backup: $BACKUP"
