#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$SCRIPT_DIR/.."
EXAMPLE="$REPO/example"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

echo "Building pb-runner..."
cabal build pb-runner --project-dir "$REPO" -v0

echo "Processing Appeon example corpus..."
cabal run pb-runner --project-dir "$REPO" -v0 -- \
  -i "$EXAMPLE/PowerBuilder-Example/export" \
  -o "$OUT/appeon"

echo "Processing OpenPay corpus..."
cabal run pb-runner --project-dir "$REPO" -v0 -- \
  -i "$EXAMPLE/openpay" \
  -o "$OUT/openpay"

ERRORS=$(grep -rl '"error":' "$OUT" 2>/dev/null | wc -l | tr -d ' ') || ERRORS=0
TOTAL=$(find "$OUT" -name "*.json" | wc -l | tr -d ' ')

echo ""
echo "Files processed: $TOTAL  |  Errors: $ERRORS"

if [ "$ERRORS" -gt 0 ]; then
  echo ""
  echo "--- failing files ---"
  grep -rl '"error":' "$OUT"
  exit 1
fi
