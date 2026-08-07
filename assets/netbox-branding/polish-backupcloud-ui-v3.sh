#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

VERSION="2026.08.07.3"
APP="/opt/netbox/netbox"
VENV="/opt/netbox/venv"
PKG="/opt/netbox/local/ddm-netbox-branding/ddm_netbox_branding"
SRC="$PKG/static/ddm_netbox_branding/backupcloud-branding.css"
TC="$PKG/template_content.py"
PUBLISHED="$APP/static/ddm_netbox_branding/backupcloud-branding.css"
FQDN="inventory.bkpcloud.app.br"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/opt/netbox/backups/backupcloud-netbox-polish-v3-${STAMP}"
CHANGED=0

fail(){ echo "ERRO: $*" >&2; exit 1; }
rollback(){
  rc=$?
  trap - ERR
  set +e
  if [[ "$CHANGED" == "1" ]]; then
    echo "ROLLBACK: restaurando arquivos anteriores..."
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

[[ "$(id -u)" -eq 0 ]] || fail "execute como root"
[[ -x "$VENV/bin/python" ]] || fail "venv do NetBox nao encontrado"
[[ -f "$SRC" ]] || fail "CSS BackupCloud nao encontrado: $SRC"
[[ -f "$TC" ]] || fail "template_content.py nao encontrado: $TC"
for svc in netbox netbox-rq nginx; do systemctl is-active --quiet "$svc" || fail "servico $svc nao esta ativo"; done

cd "$APP"
NETBOX_VERSION="$($VENV/bin/python manage.py shell -c 'from django.conf import settings; print(settings.VERSION)' 2>/dev/null | tail -n1)"
[[ "$NETBOX_VERSION" == "4.6.5" ]] || fail "ajuste homologado para NetBox 4.6.5; detectado: $NETBOX_VERSION"

echo "============================================================"
echo " BACKUPCLOUD | INVENTARIO - POLIMENTO V3"
echo " Instalador: $VERSION"
echo " NetBox: $NETBOX_VERSION"
echo "============================================================"

echo "[1/6] Criando backup"
mkdir -p "$BACKUP"
cp -a "$SRC" "$BACKUP/backupcloud-branding.css"
cp -a "$TC" "$BACKUP/template_content.py"
CHANGED=1
echo "   $BACKUP"

echo "[2/6] Aplicando correcoes de contraste"
python3 - "$SRC" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1])
s=p.read_text(encoding='utf-8')
s=re.sub(r'/\* === BACKUPCLOUD INVENTARIO POLISH V3 - INICIO === \*/.*?/\* === BACKUPCLOUD INVENTARIO POLISH V3 - FIM === \*/\s*','',s,flags=re.S)
s += r'''

/* === BACKUPCLOUD INVENTARIO POLISH V3 - INICIO === */

/* Cabeçalho de conteúdo: remove o bloco branco e mantém a linguagem BackupCloud */
.page-header,
.page-header .container-xl,
.page-header .container-fluid,
.page-header .container {
  background:linear-gradient(90deg,rgba(24,38,64,.98),rgba(34,50,82,.98))!important;
  color:#edf4ff!important;
  border-color:rgba(148,163,184,.18)!important;
}
.page-header h1,
.page-header h2,
.page-header h3,
.page-header .page-title,
.page-header .text-secondary,
.page-header .text-muted {
  color:#edf4ff!important;
}
.page-header .nav-tabs {
  border-bottom:1px solid rgba(148,163,184,.22)!important;
}
.page-header .nav-tabs .nav-link {
  color:#b9c8dc!important;
  background:transparent!important;
  border-color:transparent!important;
}
.page-header .nav-tabs .nav-link:hover {
  color:#fff!important;
  background:rgba(86,89,199,.12)!important;
}
.page-header .nav-tabs .nav-link.active {
  color:#fff!important;
  background:rgba(86,89,199,.22)!important;
  border-color:rgba(121,140,255,.35)!important;
}

/* Algumas páginas do NetBox usam o wrapper de título fora de .page-header */
.page-wrapper > .container-xl:first-child,
.page-wrapper > .container-fluid:first-child {
  background:transparent!important;
  color:#edf4ff!important;
}

/* Menu lateral/offcanvas: corrige texto preto sobre azul escuro */
.offcanvas,
.offcanvas-header,
.offcanvas-body,
#sidebar-menu,
#sidebar-menu .accordion,
#sidebar-menu .accordion-item,
#sidebar-menu .accordion-body {
  background:linear-gradient(180deg,#15223a 0%,#233856 100%)!important;
  color:#e7eef9!important;
  border-color:rgba(148,163,184,.18)!important;
}
#sidebar-menu a,
#sidebar-menu button:not(.btn-primary),
#sidebar-menu .nav-link,
#sidebar-menu .dropdown-item,
#sidebar-menu .accordion-button,
#sidebar-menu .list-group-item,
#sidebar-menu .text-secondary,
#sidebar-menu .text-muted,
.offcanvas-body a,
.offcanvas-body .nav-link,
.offcanvas-body .dropdown-item {
  color:#dbe7f6!important;
}
#sidebar-menu a:hover,
#sidebar-menu .nav-link:hover,
#sidebar-menu .dropdown-item:hover,
#sidebar-menu .accordion-button:hover {
  color:#fff!important;
  background:rgba(86,89,199,.16)!important;
}
#sidebar-menu .active,
#sidebar-menu .nav-link.active,
#sidebar-menu .dropdown-item.active {
  color:#fff!important;
  background:rgba(86,89,199,.22)!important;
}
#sidebar-menu .text-uppercase,
#sidebar-menu .menu-section-title,
#sidebar-menu .section-title,
.offcanvas-body .text-uppercase {
  color:#40c7bd!important;
  font-weight:700!important;
}

/* Campo de busca do menu continua claro e legível */
.offcanvas .form-control,
.offcanvas .form-select,
#sidebar-menu .form-control,
#sidebar-menu .form-select {
  background:#f8fafc!important;
  color:#26364e!important;
  border-color:#bac8da!important;
}
.offcanvas .form-control::placeholder,
#sidebar-menu .form-control::placeholder {
  color:#6b7b91!important;
}

/* Preserva o miolo da página no azul/grafite, sem voltar ao preto absoluto */
.page-body {
  background:rgba(24,38,64,.82)!important;
  color:#e8eef9!important;
}
.page-body .card,
.page-body .table-responsive {
  background:rgba(34,52,82,.78)!important;
}

/* === BACKUPCLOUD INVENTARIO POLISH V3 - FIM === */
'''
p.write_text(s,encoding='utf-8')
PY

echo "[3/6] Atualizando cache-buster"
python3 - "$TC" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1])
s=p.read_text(encoding='utf-8')
s=re.sub(r'\?v=3\.0\.\d+', '?v=3.0.3', s)
p.write_text(s,encoding='utf-8')
PY

echo "[4/6] Validando e publicando"
"$VENV/bin/python" manage.py check
"$VENV/bin/python" manage.py collectstatic --no-input >/dev/null
[[ -f "$PUBLISHED" ]] || fail "CSS publicado nao encontrado"
grep -q "BACKUPCLOUD INVENTARIO POLISH V3 - INICIO" "$PUBLISHED" || fail "marcador V3 nao chegou ao static publicado"

echo "[5/6] Reiniciando NetBox"
systemctl restart netbox netbox-rq
for svc in netbox netbox-rq nginx; do systemctl is-active --quiet "$svc" || fail "servico $svc nao voltou"; done

echo "[6/6] Validando publicacao HTTP"
for _ in $(seq 1 20); do
  if curl -fsS --connect-timeout 5 --max-time 10 "https://${FQDN}/static/ddm_netbox_branding/backupcloud-branding.css?v=3.0.3" 2>/dev/null | grep -q "BACKUPCLOUD INVENTARIO POLISH V3 - INICIO"; then
    break
  fi
  sleep 2
done
curl -fsS --connect-timeout 5 --max-time 10 "https://${FQDN}/static/ddm_netbox_branding/backupcloud-branding.css?v=3.0.3" 2>/dev/null | grep -q "BACKUPCLOUD INVENTARIO POLISH V3 - INICIO" || fail "CSS V3 nao apareceu via HTTPS"

echo
echo "SUCESSO - BACKUPCLOUD | INVENTARIO - POLIMENTO V3"
echo "Corrigido: cabecalho branco + contraste do menu lateral"
echo "Backup: $BACKUP"
