#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

BASE="/home/suporte"
TOMCAT_BASE="/var/lib/tomcat9"
MAINCSS="${TOMCAT_BASE}/webapps/ROOT/css/main.css"
LOGO="${TOMCAT_BASE}/work/ddm-branding/ddm-login-icon.png"
ASSET_B64="https://raw.githubusercontent.com/bkpcloud-app/snoc/main/assets/ddm-gestao-movel/branding/web/ddm-icon-clean-64.png.b64"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${BASE}/DDM-MDM-POLISH-BACKUP-${STAMP}"
TMP_B64="/tmp/ddm-icon-clean-${STAMP}.b64"
TMP_PNG="/tmp/ddm-icon-clean-${STAMP}.png"

fail(){ echo "ERRO: $*" >&2; exit 1; }
cleanup(){ rm -f "$TMP_B64" "$TMP_PNG"; }
trap cleanup EXIT

[[ "$(id -u)" -eq 0 ]] || fail "execute como root"
[[ -s "$MAINCSS" ]] || fail "main.css ausente: $MAINCSS"
command -v curl >/dev/null || fail "curl ausente"
command -v base64 >/dev/null || fail "base64 ausente"
command -v python3 >/dev/null || fail "python3 ausente"

mkdir -p "$BACKUP"
cp -a "$MAINCSS" "$BACKUP/main.css"
[[ -f "$LOGO" ]] && cp -a "$LOGO" "$BACKUP/ddm-login-icon.png" || true

echo "Backup: $BACKUP"

curl -fsSL "$ASSET_B64" -o "$TMP_B64"
base64 -d "$TMP_B64" > "$TMP_PNG"
python3 - "$TMP_PNG" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
d=p.read_bytes()
if len(d) < 1000 or not d.startswith(b'\x89PNG\r\n\x1a\n'):
    raise SystemExit('PNG inválido')
print(f'Ícone limpo: OK ({len(d)} bytes)')
PY

install -d -o tomcat -g tomcat -m 0755 "$(dirname "$LOGO")"
install -o tomcat -g tomcat -m 0644 "$TMP_PNG" "$LOGO"

python3 - "$MAINCSS" <<'PY'
from pathlib import Path
import re, sys
p=Path(sys.argv[1])
s=p.read_text(encoding='utf-8')
start='/* === DDM POLIMENTO PRODUCAO - INICIO === */'
end='/* === DDM POLIMENTO PRODUCAO - FIM === */'
s=re.sub(re.escape(start)+r'.*?'+re.escape(end),'',s,flags=re.S)
css=r'''

/* === DDM POLIMENTO PRODUCAO - INICIO === */

.login-logo {
    max-width: 500px !important;
    margin: 44px auto 18px auto !important;
    gap: 14px !important;
}

.login-logo img {
    width: 58px !important;
    height: 58px !important;
    min-width: 58px !important;
    object-fit: contain !important;
    border-radius: 12px !important;
}

.login-logo .logo {
    color: #3f4a52 !important;
    font-size: 28px !important;
    font-weight: 600 !important;
    letter-spacing: -0.25px !important;
}

.login {
    width: 470px !important;
    border: 1px solid #e1e4e8 !important;
    border-top: 2px solid #e8842b !important;
    border-radius: 8px !important;
    box-shadow: 0 8px 24px rgba(25,31,36,.08) !important;
}

.login .panel-body {
    background: #ffffff !important;
    padding: 30px 34px !important;
}

.login .form-control {
    height: 42px !important;
    border-radius: 6px !important;
}

.login .btn-default,
.login .btn-default[disabled],
.login .btn-default.disabled,
.login .btn-default[disabled]:hover,
.login .btn-default[disabled]:focus,
.login .btn-default.disabled:hover,
.login .btn-default.disabled:focus {
    background-color: #e8842b !important;
    border-color: #e8842b !important;
    color: #ffffff !important;
    opacity: .78 !important;
    font-weight: 600 !important;
    border-radius: 6px !important;
    padding: 8px 22px !important;
}

.login .btn-default:not([disabled]):hover,
.login .btn-default:not([disabled]):focus,
.login .btn-default:not([disabled]):active {
    background-color: #cf721f !important;
    border-color: #cf721f !important;
    opacity: 1 !important;
}

.login-footer {
    color: #737980 !important;
    font-size: 13px !important;
}

.login-footer > * {
    display: none !important;
}

.login-footer::after {
    content: "DDM Gestão Móvel  •  DDMTI Soluções" !important;
    color: #737980 !important;
}

/* === DDM POLIMENTO PRODUCAO - FIM === */
'''
p.write_text(s.rstrip()+css+'\n',encoding='utf-8')
PY

chown root:tomcat "$MAINCSS"
chmod 0644 "$MAINCSS"

curl -fsS http://127.0.0.1:8080/rest/public/logo -o /tmp/ddm-logo-check.png
python3 - <<'PY'
from pathlib import Path
p=Path('/tmp/ddm-logo-check.png')
d=p.read_bytes()
assert d.startswith(b'\x89PNG\r\n\x1a\n') and len(d) > 1000
print(f'rest/public/logo: OK ({len(d)} bytes)')
PY
rm -f /tmp/ddm-logo-check.png

echo
echo "============================================================"
echo " DDM GESTAO MOVEL - POLIMENTO FINAL APLICADO"
echo "============================================================"
echo "Ícone      : limpo, sem texto cortado"
echo "Título     : grafite #3F4A52"
echo "Acento     : laranja #E8842B"
echo "Painel     : 470px / branco"
echo "Botão      : laranja inclusive desabilitado"
echo "index.html : NÃO ALTERADO"
echo "JavaScript : NÃO ALTERADO"
echo "Backup     : $BACKUP"
echo "============================================================"
