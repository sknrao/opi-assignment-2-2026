#!/usr/bin/env bash
# lab-console/sync.sh — regenerate docs/data.js from repo evidence
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 "${ROOT}/lab-console/gen_data.py" \
  "${ROOT}/verification_flows.json" \
  "${ROOT}/ping_results.txt" \
  "${ROOT}/evidence/flows_before.txt" \
  "${ROOT}/evidence/flows_after.txt" \
  "${ROOT}/evidence/execution_mode.txt" \
  > "${ROOT}/docs/data.js"
echo "docs/data.js updated"
