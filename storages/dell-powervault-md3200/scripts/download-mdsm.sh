#!/usr/bin/env bash
set -euo pipefail

DEST_DIR="${1:-/root}"
RATE="${MDSM_DOWNLOAD_RATE:-1M}"
FILE="DELL_MDSS_Consolidated_RDVD_6_5_0_1.iso"
URL="https://downloads.dell.com/FOLDER04066625M/1/${FILE}"
SHA256="4b1309a9c59c264bca360cb45560ef45dfbbb9532fed078ce3875184bc7299ec"
OUT="${DEST_DIR}/${FILE}"
LOG="${DEST_DIR}/download-mdsm.log"

mkdir -p "$DEST_DIR"
command -v curl >/dev/null || { echo "ERRO: curl não encontrado" >&2; exit 1; }
command -v sha256sum >/dev/null || { echo "ERRO: sha256sum não encontrado" >&2; exit 1; }

if [[ -f "$OUT" ]]; then
  echo "Arquivo existente encontrado: $OUT"
fi

echo "Baixando em segundo plano com limite ${RATE}:"
echo "$OUT"

nohup nice -n 19 ionice -c 3 \
  curl -4 --http1.1 -fL \
    --continue-at - \
    --limit-rate "$RATE" \
    --retry 10 \
    --retry-delay 15 \
    --connect-timeout 30 \
    -o "$OUT" \
    "$URL" \
  >"$LOG" 2>&1 &

PID=$!
echo "PID=$PID"
echo "Log=$LOG"
echo
echo "Acompanhe com:"
echo "  tail -f '$LOG'"
echo
echo "Após terminar, valide com:"
echo "  echo '$SHA256  $OUT' | sha256sum -c -"
