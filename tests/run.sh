#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export ROOT
TOTAL_FAILS=0
for t in "$ROOT"/tests/*_test.sh; do
  [ -e "$t" ] || continue
  echo "== $(basename "$t") =="
  STUB_BIN="$(mktemp -d)"; export STUB_BIN
  PATH="$STUB_BIN:$PATH" bash "$t"; rc=$?
  TOTAL_FAILS=$((TOTAL_FAILS+rc))
  rm -rf "$STUB_BIN"
done
if [ "$TOTAL_FAILS" -ne 0 ]; then echo "SUITE FAILED ($TOTAL_FAILS)"; exit 1; fi
echo "ALL TESTS PASSED"
