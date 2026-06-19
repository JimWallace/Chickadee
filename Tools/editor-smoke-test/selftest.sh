#!/usr/bin/env bash
#
# selftest.sh — prove the smoke test actually detects the regression it exists
# to catch. Runs the editor check twice against the same server build:
#
#   1. default config (service worker, NO cross-origin isolation) — must PASS;
#   2. NOTEBOOK_CROSS_ORIGIN_ISOLATION=true — must FAIL, because COEP
#      require-corp on the editor page blocks the fast-path-served Pyodide
#      kernel worker (the exact production breakage from the COEP attempt).
#
# If the "good" config fails or the "bad" config passes, the smoke test is not
# discriminating and this exits non-zero — i.e. it guards the guard.

set -uo pipefail
cd "$(dirname "$0")"

echo "=== selftest 1/2: default config — expect PASS ==="
if PORT="${PORT_GOOD:-8099}" NOTEBOOK_CROSS_ORIGIN_ISOLATION=false ./run-smoke.sh; then
  good_pass=1
else
  good_pass=0
fi

echo
echo "=== selftest 2/2: NOTEBOOK_CROSS_ORIGIN_ISOLATION=true — expect FAIL ==="
if PORT="${PORT_BAD:-8100}" NOTEBOOK_CROSS_ORIGIN_ISOLATION=true ./run-smoke.sh; then
  bad_pass=1
else
  bad_pass=0
fi

echo
if [ "$good_pass" -eq 1 ] && [ "$bad_pass" -eq 0 ]; then
  echo "SELFTEST PASS — smoke test passes on the good config and fails on the COEP regression."
  exit 0
fi
echo "SELFTEST FAIL — the smoke test is not discriminating:"
echo "  good-config passed? $good_pass (want 1)"
echo "  bad-config  passed? $bad_pass (want 0)"
exit 1
