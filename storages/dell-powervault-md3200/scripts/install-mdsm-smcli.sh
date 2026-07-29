#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "ERRO: execute como root." >&2
  exit 1
fi

ISO="${1:-}"
EXPECTED_SHA="4b1309a9c59c264bca360cb45560ef45dfbbb9532fed078ce3875184bc7299ec"
MOUNT_POINT="/mnt/dell-mdsm"
PROPERTIES="/root/mdsm-smclient-only.properties"

if [[ -z "$ISO" || ! -f "$ISO" ]]; then
  echo "Uso: $0 /caminho/DELL_MDSS_Consolidated_RDVD_6_5_0_1.iso" >&2
  exit 1
fi

command -v dnf >/dev/null && dnf install -y acl >/dev/null 2>&1 || true

for cmd in sha256sum mount umount find setfacl; do
  command -v "$cmd" >/dev/null || {
    echo "ERRO: comando obrigatório ausente: $cmd" >&2
    exit 1
  }
done

ACTUAL_SHA="$(sha256sum "$ISO" | awk '{print $1}')"
if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
  echo "ERRO: SHA-256 inválido para $ISO" >&2
  echo "Esperado: $EXPECTED_SHA" >&2
  echo "Obtido:   $ACTUAL_SHA" >&2
  exit 1
fi

echo "SHA-256: OK"

mkdir -p "$MOUNT_POINT"
if mountpoint -q "$MOUNT_POINT"; then
  umount "$MOUNT_POINT"
fi
mount -o loop,ro,exec "$ISO" "$MOUNT_POINT"

INSTALLER="$MOUNT_POINT/linux/mdsm/SMIA-LINUXX64.bin"
[[ -x "$INSTALLER" ]] || { echo "ERRO: instalador não encontrado: $INSTALLER" >&2; exit 1; }

cat > "$PROPERTIES" <<'PROP'
INSTALLER_UI=SILENT
CHOSEN_INSTALL_SET=Custom
CHOSEN_INSTALL_FEATURE_LIST=SMclient
USER_REQUESTED_RESTART=NO
PROP

rpm -qa | sort > /root/rpm-before-mdsm.txt
LOG="/root/mdsm-smclient-install-$(date +%Y%m%d-%H%M%S).log"

echo "Instalando somente SMclient/SMcli..."
"$INSTALLER" -i silent -f "$PROPERTIES" 2>&1 | tee "$LOG"
RC=${PIPESTATUS[0]}
if [[ $RC -ne 0 ]]; then
  echo "ERRO: instalador retornou $RC. Log: $LOG" >&2
  exit "$RC"
fi

rpm -qa | sort > /root/rpm-after-mdsm.txt
comm -13 /root/rpm-before-mdsm.txt /root/rpm-after-mdsm.txt > /root/rpm-new-mdsm.txt || true

SMCLI_REAL="$(find /opt/dell /opt -type f -name SMcli 2>/dev/null | head -1)"
[[ -n "$SMCLI_REAL" ]] || { echo "ERRO: instalação terminou, mas SMcli não foi localizado." >&2; exit 1; }

ln -sfn "$SMCLI_REAL" /usr/bin/SMcli

command -v dnf >/dev/null && dnf install -y acl >/dev/null 2>&1 || true
install -d -o zabbix -g zabbix -m 0750 /var/lib/zabbix

MDSM_BASE="$(dirname "$(dirname "$SMCLI_REAL")")"
setfacl -R -m u:zabbix:rX "$MDSM_BASE"

if [[ -d /var/opt/SM ]]; then
  setfacl -m u:zabbix:--x /var /var/opt
  find /var/opt/SM -type d -exec setfacl -m u:zabbix:rwx,m::rwx,d:u:zabbix:rwx,d:m::rwx {} +
  find /var/opt/SM -type f ! -name LAUNCHER_ENV -exec setfacl -m u:zabbix:rw- {} +
  [[ ! -f /var/opt/SM/LAUNCHER_ENV ]] || setfacl -m u:zabbix:r-- /var/opt/SM/LAUNCHER_ENV
fi

echo "SMcli instalado: $SMCLI_REAL"
echo "Link: /usr/bin/SMcli"
runuser -u zabbix -- env HOME=/var/lib/zabbix /usr/bin/SMcli -? 2>&1 | tail -20

echo "Instalação concluída. Nenhum reboot foi solicitado."
