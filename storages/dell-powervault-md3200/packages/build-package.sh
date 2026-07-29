#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
OUT="md3200-monitoring-v1.1.1.zip"
cat "$OUT".b64.part-* | base64 -d > "$OUT"
sha256sum -c SHA256SUMS
ls -lh "$OUT"
