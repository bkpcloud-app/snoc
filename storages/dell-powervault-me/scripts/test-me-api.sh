#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "Uso: $0 <IP_A> <IP_B> <USUARIO>" >&2
  exit 1
fi

IP_A="$1"
IP_B="$2"
USER_NAME="$3"
PORT="${POWERVAULT_PORT:-443}"
SCHEME="${POWERVAULT_SCHEME:-https}"

command -v curl >/dev/null || { echo "ERRO: curl não encontrado" >&2; exit 1; }
command -v sha256sum >/dev/null || { echo "ERRO: sha256sum não encontrado" >&2; exit 1; }

read -r -s -p "Senha do usuário ${USER_NAME}: " PASSWORD
echo

AUTH_HASH="$(printf '%s' "${USER_NAME}_${PASSWORD}" | sha256sum | awk '{print $1}')"
unset PASSWORD

try_controller() {
  local ip="$1" base response key status
  base="${SCHEME}://${ip}:${PORT}"
  echo "Tentando ${base} ..."

  response="$(curl -k -sS --connect-timeout 10 --max-time 30 \
    -H 'datatype: json' \
    "${base}/api/login/${AUTH_HASH}")" || return 1

  key="$(python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("status") or [{}])[0].get("response", ""))' <<<"$response" 2>/dev/null || true)"
  [[ ${#key} -ge 16 ]] || { echo "Falha de autenticação em ${ip}"; return 1; }

  echo "Autenticação OK em ${ip}"
  for endpoint in system controllers disks pools volumes versions; do
    status="$(curl -k -sS -o /tmp/me-api-${endpoint}.$$ -w '%{http_code}' \
      --connect-timeout 10 --max-time 45 \
      -H 'datatype: json' -H "sessionKey: ${key}" \
      "${base}/api/show/${endpoint}" || true)"
    printf '%-24s HTTP=%s bytes=%s\n' "$endpoint" "$status" "$(wc -c </tmp/me-api-${endpoint}.$$ 2>/dev/null || echo 0)"
    rm -f /tmp/me-api-${endpoint}.$$
  done
  return 0
}

try_controller "$IP_A" || try_controller "$IP_B" || {
  echo "ERRO: nenhuma controladora respondeu corretamente." >&2
  exit 1
}
