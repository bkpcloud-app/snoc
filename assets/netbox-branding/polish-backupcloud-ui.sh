#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

VERSION="2026.08.07.2"
APP="/opt/netbox/netbox"
VENV="/opt/netbox/venv"
SRC="/opt/netbox/local/ddm-netbox-branding/ddm_netbox_branding/static/ddm_netbox_branding/backupcloud-branding.css"
PUBLISHED="$APP/static/ddm_netbox_branding/backupcloud-branding.css"
FQDN="inventory.bkpcloud.app.br"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/opt/netbox/backups/backupcloud-netbox-polish-${STAMP}"
TMP="$(mktemp -d /tmp/backupcloud-netbox-polish.XXXXXX)"
CHANGED=0

fail(){ echo "ERRO: $*" >&2; exit 1; }
cleanup(){ rm -rf "$TMP"; }
rollback(){
  rc=$?
  trap - ERR
  set +e
  if [[ "$CHANGED" == "1" && -f "$BACKUP/backupcloud-branding.css" ]]; then
    echo "ROLLBACK: restaurando CSS anterior..."
    cp -a "$BACKUP/backupcloud-branding.css" "$SRC"
    cd "$APP"
    "$VENV/bin/python" manage.py collectstatic --no-input >/dev/null 2>&1 || true
    systemctl restart netbox netbox-rq >/dev/null 2>&1 || true
    echo "ROLLBACK concluido: $BACKUP"
  fi
  exit "$rc"
}
trap cleanup EXIT
trap rollback ERR

[[ "$(id -u)" -eq 0 ]] || fail "execute como root"
[[ -x "$VENV/bin/python" ]] || fail "venv do NetBox nao encontrado"
[[ -f "$SRC" ]] || fail "CSS BackupCloud nao encontrado: $SRC"
for svc in netbox netbox-rq nginx; do systemctl is-active --quiet "$svc" || fail "servico $svc nao esta ativo"; done

cd "$APP"
NETBOX_VERSION="$($VENV/bin/python manage.py shell -c 'from django.conf import settings; print(settings.VERSION)' 2>/dev/null | tail -n1)"
[[ "$NETBOX_VERSION" == "4.6.5" ]] || fail "polimento homologado para NetBox 4.6.5; detectado: $NETBOX_VERSION"

echo "============================================================"
echo " BACKUPCLOUD | INVENTARIO - POLIMENTO FINAL"
echo " Versao: $VERSION"
echo "============================================================"

echo "[1/5] Criando backup"
mkdir -p "$BACKUP"
cp -a "$SRC" "$BACKUP/backupcloud-branding.css"
CHANGED=1

echo "[2/5] Aplicando acabamento visual"
python3 - "$SRC" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1])
s=p.read_text(encoding='utf-8')
s=re.sub(r'/\* === BACKUPCLOUD INVENTARIO POLISH - INICIO === \*/.*?/\* === BACKUPCLOUD INVENTARIO POLISH - FIM === \*/\s*','',s,flags=re.S)
block=r'''
/* === BACKUPCLOUD INVENTARIO POLISH - INICIO === */

/* Login: mesmo acabamento da Gestão Móvel */
.page-center .card{
  background:rgba(43,66,104,.96)!important;
  border:1px solid rgba(165,181,215,.48)!important;
  border-top:2px solid #7377e6!important;
  box-shadow:0 22px 58px rgba(0,0,0,.25)!important;
}
.page-center .card .card-body{background:transparent!important}
.page-center .btn-primary,
.page-center button[type="submit"],
.page-center input[type="submit"]{
  color:#fff!important;
  font-weight:600!important;
  text-shadow:none!important;
}
.page-center .form-control,
.page-center .form-select{
  background:#f8fafc!important;
  color:#26364e!important;
  border-color:#aebed2!important;
}

/* Cabeçalho interno */
header.navbar{
  background:linear-gradient(90deg,#17243d 0%,#203354 62%,#30366e 100%)!important;
}
.navbar-brand-image.backupcloud-brand-image{
  width:225px!important;
  max-height:62px!important;
}

/* Área de trabalho: menos preta, mais próxima da Gestão Móvel */
.page-wrapper,
.page-body{
  background:linear-gradient(135deg,rgba(20,33,56,.96) 0%,rgba(29,46,75,.96) 58%,rgba(41,45,94,.94) 100%)!important;
}
.page-body .card,
.page-body .table-responsive,
.page-body .tab-content,
.page-body .card-body{
  background:rgba(30,47,76,.72)!important;
}
.page-body .table{
  background:rgba(17,31,53,.42)!important;
}
.page-body .table>:not(caption)>*>*{
  border-color:rgba(148,163,184,.22)!important;
}
.page-body .table-hover>tbody>tr:hover>*{
  background:rgba(86,89,199,.11)!important;
}

/* Abas, filtros e controles */
.nav-tabs .nav-link.active{
  background:rgba(43,66,104,.96)!important;
  color:#fff!important;
  border-color:rgba(148,163,184,.28)!important;
}
.nav-tabs .nav-link:not(.active){color:#aebbd0!important}
.input-group-text,
.ts-control{
  border-color:#aebed2!important;
}

/* Botões neutros menos pesados no tema escuro */
.btn-secondary,
.btn-outline-secondary{
  background:rgba(51,68,96,.88)!important;
  border-color:rgba(148,163,184,.34)!important;
  color:#eef4ff!important;
}

@media(max-width:991.98px){
  .navbar-brand-image.backupcloud-brand-image{width:190px!important;max-height:54px!important}
}

/* === BACKUPCLOUD INVENTARIO POLISH - FIM === */
'''
p.write_text(s.rstrip()+"\n\n"+block+"\n",encoding='utf-8')
if p.read_text(encoding='utf-8').count('BACKUPCLOUD INVENTARIO POLISH - INICIO') != 1:
    raise SystemExit('bloco de polimento duplicado')
print('   CSS: OK')
PY

echo "[3/5] Publicando estaticos"
"$VENV/bin/python" manage.py collectstatic --no-input >/dev/null
[[ -s "$PUBLISHED" ]] || fail "CSS publicado nao encontrado"
grep -q 'BACKUPCLOUD INVENTARIO POLISH - INICIO' "$PUBLISHED" || fail "polimento nao chegou ao collectstatic"

echo "[4/5] Reiniciando e validando"
systemctl restart netbox netbox-rq
sleep 4
systemctl is-active --quiet netbox || fail "netbox nao voltou"
systemctl is-active --quiet netbox-rq || fail "netbox-rq nao voltou"

HTTP="$(curl -ksS --resolve "$FQDN:443:127.0.0.1" -o "$TMP/css" -w '%{http_code}' "https://$FQDN/static/ddm_netbox_branding/backupcloud-branding.css?v=$VERSION")"
[[ "$HTTP" == "200" ]] || fail "CSS HTTPS respondeu $HTTP"
grep -q 'BACKUPCLOUD INVENTARIO POLISH - INICIO' "$TMP/css" || fail "HTTPS ainda entrega CSS antigo"

echo "[5/5] Concluido"
trap - ERR

echo
echo "============================================================"
echo " SUCESSO - BACKUPCLOUD | INVENTARIO"
echo " Login       : polido"
echo " Area interna: clareada"
echo " Botao login : texto branco"
echo " Logo header : ampliada"
echo " Backup      : $BACKUP"
echo "============================================================"
