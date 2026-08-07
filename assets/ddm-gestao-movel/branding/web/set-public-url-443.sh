#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

BASE="/home/suporte"
FQDN="mobgw.bkpcloud.app.br"
PUBLIC_URL="https://${FQDN}"
MQTT_URI="${FQDN}:31000"
TOMCAT_BASE="/var/lib/tomcat9"
CTX="${TOMCAT_BASE}/conf/Catalina/localhost/ROOT.xml"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${BASE}/DDM-MDM-URL-BACKUP-${STAMP}"

fail() {
    echo "ERRO: $*" >&2
    exit 1
}

wait_port() {
    local port="$1"
    local timeout="$2"
    local i
    for ((i=0; i<timeout; i++)); do
        if ss -H -lnt "sport = :${port}" | grep -q .; then
            return 0
        fi
        sleep 1
    done
    return 1
}

[[ "$(id -u)" -eq 0 ]] || fail "execute como root"
[[ -s "$CTX" ]] || fail "ROOT.xml ausente: $CTX"
systemctl is-active --quiet tomcat9 || fail "tomcat9 inativo"
systemctl is-active --quiet nginx || fail "nginx inativo"

mkdir -p "$BACKUP"
cp -a "$CTX" "$BACKUP/ROOT.xml"
[[ -f /etc/nginx/sites-available/ddm-mdm ]] && cp -a /etc/nginx/sites-available/ddm-mdm "$BACKUP/ddm-mdm.nginx" || true
cp -a /etc/hosts "$BACKUP/hosts"

echo "Backup: $BACKUP"

python3 - "$CTX" <<'PY'
import sys
import xml.etree.ElementTree as ET

path = sys.argv[1]
tree = ET.parse(path)
root = tree.getroot()

values = {
    "base.url": "https://mobgw.bkpcloud.app.br",
    "swagger.host": "mobgw.bkpcloud.app.br",
    "mqtt.server.uri": "mobgw.bkpcloud.app.br:31000",
}

params = {
    p.get("name"): p
    for p in root.findall("Parameter")
    if p.get("name")
}

for name, value in values.items():
    node = params.get(name)
    if node is None:
        node = ET.SubElement(root, "Parameter")
        node.set("name", name)
        params[name] = node
    node.set("value", value)

ET.indent(tree, space="    ")
tree.write(path, encoding="UTF-8", xml_declaration=True)
ET.parse(path)

for name, expected in values.items():
    actual = params[name].get("value")
    if actual != expected:
        raise SystemExit(f"Falha ao aplicar {name}: {actual!r}")
    print(f"{name}={actual}")
PY

systemctl restart tomcat9
wait_port 8080 180 || {
    journalctl -u tomcat9 -n 120 --no-pager
    fail "Tomcat não voltou na porta 8080"
}

wait_port 31000 180 || {
    journalctl -u tomcat9 -n 120 --no-pager
    fail "MQTT não voltou na porta 31000"
}

nginx -t

HTTP="$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/)"
HTTPS="$(curl -sS --resolve "${FQDN}:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://${FQDN}/")"

[[ "$HTTP" =~ ^(200|301|302)$ ]] || fail "HTTP local inesperado: $HTTP"
[[ "$HTTPS" =~ ^(200|301|302)$ ]] || fail "HTTPS local inesperado: $HTTPS"

echo
echo "============================================================"
echo " DDM GESTÃO MÓVEL - URL PÚBLICA ATUALIZADA"
echo "============================================================"
echo "HTTPS público : ${PUBLIC_URL}"
echo "MQTT público  : ${MQTT_URI}"
echo "Tomcat        : 127.0.0.1:8080"
echo "HTTP local    : ${HTTP}"
echo "HTTPS local   : ${HTTPS}"
echo "Backup        : ${BACKUP}"
echo "============================================================"
