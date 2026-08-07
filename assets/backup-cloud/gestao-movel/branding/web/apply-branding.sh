#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

BASE="/home/suporte"
FQDN="mobgw.bkpcloud.app.br"
TOMCAT="/var/lib/tomcat9"
CTX="$TOMCAT/conf/Catalina/localhost/ROOT.xml"
WEB="$TOMCAT/webapps/ROOT"
CSS="$WEB/css/main.css"
ASSETS="$WEB/images/backup-cloud"
LOGO="$ASSETS/backup-cloud-logo.png"
HERO="$ASSETS/gestao-movel-login-hero.jpg"
ICON="$ASSETS/backup-cloud-icon.png"
FAVICON="$WEB/images/favicon.ico"
RAW="https://raw.githubusercontent.com/bkpcloud-app/snoc/main/assets/backup-cloud/gestao-movel/branding/web"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BASE/BACKUP-CLOUD-GESTAO-MOVEL-BRANDING-BACKUP-$STAMP"
TMP="$(mktemp -d /tmp/bc-mdm-branding.XXXXXX)"
CHANGED=0

cleanup(){ rm -rf "$TMP"; }
trap cleanup EXIT

wait8080(){
  for _ in $(seq 1 90); do
    ss -H -lnt 'sport = :8080' 2>/dev/null | grep -q . && return 0
    sleep 1
  done
  return 1
}

rollback(){
  CHANGED=0
  echo "ROLLBACK: restaurando $BACKUP"
  cp -a "$BACKUP/ROOT.xml" "$CTX"
  cp -a "$BACKUP/main.css" "$CSS"
  [[ -f "$BACKUP/favicon.ico" ]] && cp -a "$BACKUP/favicon.ico" "$FAVICON"
  rm -rf "$ASSETS"
  [[ -d "$BACKUP/backup-cloud-assets" ]] && cp -a "$BACKUP/backup-cloud-assets" "$ASSETS"
  systemctl restart tomcat9 || true
  wait8080 || true
}

die(){
  echo "ERRO: $*" >&2
  [[ "$CHANGED" -eq 1 && -d "$BACKUP" ]] && rollback
  exit 1
}

trap 'rc=$?; [[ "$CHANGED" -eq 1 && -d "$BACKUP" ]] && rollback; exit $rc' ERR

[[ "$(id -u)" -eq 0 ]] || die "execute como root"
for c in curl python3 ss; do command -v "$c" >/dev/null || die "$c ausente"; done
[[ -s "$CTX" ]] || die "ROOT.xml ausente"
[[ -s "$CSS" ]] || die "main.css ausente"
systemctl is-active --quiet tomcat9 || die "tomcat9 inativo"
systemctl is-active --quiet nginx || die "nginx inativo"

echo "============================================================"
echo " BACKUP CLOUD | GESTÃO MÓVEL"
echo "============================================================"
echo "[1/6] Pré-validando ativos (nenhuma alteração ainda)"

decode(){
  local url="$1" out="$2" kind="$3" txt="$TMP/$(basename "$out").txt"
  echo " - $(basename "$out")"
  curl -fL --retry 3 --retry-delay 1 --connect-timeout 10 --max-time 60 -sS "$url" -o "$txt" || die "falha ao baixar $url"
  python3 - "$txt" "$out" "$kind" <<'PY'
from pathlib import Path
import base64,re,sys
src,out,kind=Path(sys.argv[1]),Path(sys.argv[2]),sys.argv[3]
text=src.read_bytes().decode("ascii","ignore").lstrip("\ufeff")
prefix={"png":"iVBORw0KGgo","jpg":"/9j/"}[kind]
i=text.find(prefix)
if i<0: raise SystemExit(f"assinatura {kind} não encontrada")
m=re.match(r"[A-Za-z0-9+/=\r\n\t ]+",text[i:])
if not m: raise SystemExit("base64 ausente")
s=re.sub(r"\s+","",m.group(0))
eq=s.find("=")
if eq>=0:
    j=eq
    while j<len(s) and s[j]=="=": j+=1
    s=s[:j]
else:
    s+="="*((-len(s))%4)
try: data=base64.b64decode(s,validate=False)
except Exception as e: raise SystemExit(f"decode falhou: {e}")
if kind=="png":
    sig=b"\x89PNG\r\n\x1a\n"; end=b"\x00\x00\x00\x00IEND\xaeB`\x82"
    if not data.startswith(sig): raise SystemExit("PNG inválido")
    p=data.find(end)
    if p<0: raise SystemExit("IEND não encontrado")
    data=data[:p+len(end)]
else:
    if not data.startswith(b"\xff\xd8\xff"): raise SystemExit("JPEG inválido")
    p=data.find(b"\xff\xd9",3)
    if p<0: raise SystemExit("EOI JPEG não encontrado")
    data=data[:p+2]
if len(data)<1500: raise SystemExit(f"asset pequeno: {len(data)} bytes")
out.write_bytes(data)
print(f"   OK {len(data)} bytes")
PY
}

decode "$RAW/backup-cloud-logo-dark-transparent.png.b64" "$TMP/logo.png" png
decode "$RAW/gestao-movel-login-hero.jpg.b64" "$TMP/hero.jpg" jpg
decode "$RAW/backup-cloud-icon.png.b64" "$TMP/icon.png" png

python3 - "$TMP/icon.png" "$TMP/favicon.ico" <<'PY'
from pathlib import Path
import struct,sys
p,o=map(Path,sys.argv[1:])
d=p.read_bytes()
if not d.startswith(b"\x89PNG\r\n\x1a\n") or len(d)<24: raise SystemExit("PNG de favicon inválido")
w,h=struct.unpack(">II",d[16:24])
entry=struct.pack("<BBBBHHII",0 if w>=256 else w,0 if h>=256 else h,0,0,1,32,len(d),22)
o.write_bytes(struct.pack("<HHH",0,1,1)+entry+d)
print(f" - favicon.ico OK ({o.stat().st_size} bytes)")
PY

echo "[2/6] Criando backup"
mkdir -p "$BACKUP"
cp -a "$CTX" "$BACKUP/ROOT.xml"
cp -a "$CSS" "$BACKUP/main.css"
[[ -f "$FAVICON" ]] && cp -a "$FAVICON" "$BACKUP/favicon.ico"
[[ -d "$ASSETS" ]] && cp -a "$ASSETS" "$BACKUP/backup-cloud-assets"
echo " Backup: $BACKUP"

echo "[3/6] Instalando ativos"
install -d -o tomcat -g tomcat -m 0755 "$ASSETS"
install -o root -g tomcat -m 0644 "$TMP/logo.png" "$LOGO"
install -o root -g tomcat -m 0644 "$TMP/hero.jpg" "$HERO"
install -o root -g tomcat -m 0644 "$TMP/icon.png" "$ICON"
install -o root -g tomcat -m 0644 "$TMP/favicon.ico" "$FAVICON"
CHANGED=1

echo "[4/6] Aplicando marca e visual"
python3 - "$CTX" "$LOGO" <<'PY'
import sys,xml.etree.ElementTree as ET
path,logo=sys.argv[1:]
tree=ET.parse(path); root=tree.getroot()
vals={
 "base.url":"https://mobgw.bkpcloud.app.br",
 "swagger.host":"mobgw.bkpcloud.app.br",
 "mqtt.server.uri":"mobgw.bkpcloud.app.br:31000",
 "rebranding.name":"Gestão Móvel",
 "rebranding.vendor.name":"Backup Cloud",
 "rebranding.vendor.link":"#",
 "rebranding.logo":logo,
 "rebranding.mobile.name":"Gestão Móvel"
}
params={p.get("name"):p for p in root.findall("Parameter") if p.get("name")}
for k,v in vals.items():
    n=params.get(k)
    if n is None:
        n=ET.SubElement(root,"Parameter"); n.set("name",k); params[k]=n
    n.set("value",v)
if hasattr(ET,"indent"): ET.indent(tree,space="    ")
tree.write(path,encoding="UTF-8",xml_declaration=True)
ET.parse(path)
for k,v in vals.items():
    if params[k].get("value")!=v: raise SystemExit(f"falha em {k}")
    print(f" - {k}={v}")
PY

python3 - "$CSS" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text(encoding="utf-8")
pairs=[
("/* === DDM GESTAO MOVEL - INICIO === */","/* === DDM GESTAO MOVEL - FIM === */"),
("/* === DDM GESTAO MOVEL - PRODUCAO - INICIO === */","/* === DDM GESTAO MOVEL - PRODUCAO - FIM === */"),
("/* === DDM POLIMENTO PRODUCAO - INICIO === */","/* === DDM POLIMENTO PRODUCAO - FIM === */"),
("/* === BACKUP CLOUD GESTAO MOVEL - INICIO === */","/* === BACKUP CLOUD GESTAO MOVEL - FIM === */")]
for a,b in pairs: s=re.sub(re.escape(a)+r".*?"+re.escape(b),"",s,flags=re.S)
css=r'''
/* === BACKUP CLOUD GESTAO MOVEL - INICIO === */
:root{--bc-navy:#0B1323;--bc-dark:#111827;--bc-purple:#3E4095;--bc-purple2:#5659C7;--bc-blue:#2563EB;--bc-white:#fff}
body{background:#f3f4f6!important;color:#1f2937}
.header{background:linear-gradient(90deg,var(--bc-navy),var(--bc-dark) 58%,#171a35)!important;border-color:var(--bc-navy)!important;box-shadow:0 2px 12px rgba(4,9,20,.24)!important}
.header a,.header .logo-text a{color:#fff!important}.header .logo-text a{font-weight:600!important}
.btn-primary,.login .btn-default{background:linear-gradient(90deg,var(--bc-blue),var(--bc-purple2))!important;border-color:var(--bc-blue)!important;color:#fff!important;border-radius:7px!important;font-weight:600!important}
a,.action-link,.login .action-link{color:var(--bc-blue)!important}
.login-logo{max-width:660px!important;margin:44px auto 17px!important;display:flex!important;flex-direction:column!important;align-items:center!important;gap:8px!important;position:relative!important;z-index:2!important}
.login-logo img{width:330px!important;height:auto!important;max-height:150px!important;object-fit:contain!important;margin:0!important;filter:drop-shadow(0 7px 22px rgba(0,0,0,.25))}
.login-logo .logo{color:#f8fafc!important;font-size:26px!important;font-weight:500!important;text-shadow:0 2px 10px rgba(0,0,0,.4)}
.login-logo::before{content:"";position:fixed;inset:0;z-index:-2;background:linear-gradient(90deg,rgba(6,13,27,.18),rgba(6,13,27,.50) 48%,rgba(6,13,27,.94) 76%),url('../images/backup-cloud/gestao-movel-login-hero.jpg') center/cover no-repeat,var(--bc-navy)}
.login-logo::after{content:"Backup Cloud  •  Gestão Móvel";color:#cbd5e1;font-size:13px;letter-spacing:.35px}
.login{width:480px!important;border:1px solid rgba(148,163,184,.18)!important;border-top:2px solid var(--bc-purple2)!important;border-radius:12px!important;overflow:hidden!important;position:relative!important;z-index:2!important;box-shadow:0 22px 58px rgba(0,0,0,.34)!important}
.login .panel-body{background:rgba(17,24,39,.94)!important;padding:31px 36px!important}
.login label{color:#e5e7eb!important;font-weight:500!important}
.login .form-control{height:43px!important;color:#f8fafc!important;background:rgba(9,16,30,.86)!important;border-color:#334155!important;border-radius:7px!important;box-shadow:none!important}
.login .form-control:focus{border-color:var(--bc-blue)!important;box-shadow:0 0 0 3px rgba(37,99,235,.17)!important}
.login-footer{position:relative!important;z-index:2!important;border-top:0!important;background:transparent!important;color:#9ca3af!important;font-size:12px!important}
.login-footer>*{display:none!important}.login-footer::after{content:"Backup Cloud  •  Gestão Móvel"!important;color:#9ca3af!important}
@media(max-width:760px){.login-logo{width:calc(100% - 28px)!important;margin-top:28px!important}.login-logo img{width:min(310px,82vw)!important}.login{width:calc(100% - 28px)!important;margin:auto!important}.login .panel-body{padding:25px 22px!important}}
/* === BACKUP CLOUD GESTAO MOVEL - FIM === */
'''
p.write_text(s.rstrip()+"\n"+css+"\n",encoding="utf-8")
print(" - CSS Backup Cloud aplicado")
PY

echo "[5/6] Reiniciando e validando"
systemctl restart tomcat9
wait8080 || die "Tomcat não abriu 8080 em 90s"
CODE="$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/ || true)"
case "$CODE" in 200|301|302|303|307|308|401|403) ;; *) die "HTTP local inválido: ${CODE:-sem resposta}";; esac
systemctl is-active --quiet tomcat9 || die "tomcat9 inativo"
systemctl is-active --quiet nginx || die "nginx inativo"

echo "[6/6] Conferência final"
grep -q 'rebranding.name.*Gestão Móvel' "$CTX" || die "nome não gravado"
grep -q 'rebranding.vendor.name.*Backup Cloud' "$CTX" || die "vendor não gravado"
grep -q 'BACKUP CLOUD GESTAO MOVEL - INICIO' "$CSS" || die "CSS não gravado"
[[ -s "$LOGO" && -s "$HERO" && -s "$ICON" && -s "$FAVICON" ]] || die "asset final ausente"
CHANGED=0

echo "============================================================"
echo " SUCESSO"
echo " Produto : Gestão Móvel"
echo " Marca   : Backup Cloud"
echo " URL     : https://$FQDN"
echo " HTTP    : $CODE"
echo " Backup  : $BACKUP"
echo "============================================================"
