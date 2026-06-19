#!/usr/bin/env bash
#
# selftest.sh — prove the smoke test actually detects the regressions it exists
# to catch. Runs the editor check three ways against the same server build:
#
#   1. default config (service worker, NO cross-origin isolation) — must PASS;
#   2. NOTEBOOK_CROSS_ORIGIN_ISOLATION=true — must FAIL, because COEP
#      require-corp on the editor page blocks the fast-path-served Pyodide
#      kernel worker (the COEP attempt's kernel-worker block);
#   3. SMOKE_SIMULATE_FROZEN=1 — must FAIL, because disabling the service worker
#      (and with COEP off, no SAB) leaves input()/stdin no synchronous path and
#      the editor goes "Page Unresponsive" (the #959 freeze).
#
# If the good config fails or either bad config passes, the smoke test is not
# discriminating and this exits non-zero — i.e. it guards the guard.

set -uo pipefail
cd "$(dirname "$0")"

echo "=== selftest 1/3: default config — expect PASS ==="
PORT="${PORT_GOOD:-8099}" NOTEBOOK_CROSS_ORIGIN_ISOLATION=false ./run-smoke.sh
good_ok=$([ $? -eq 0 ] && echo 1 || echo 0)

echo
echo "=== selftest 2/3: NOTEBOOK_CROSS_ORIGIN_ISOLATION=true — expect FAIL (COEP worker-block) ==="
PORT="${PORT_COEP:-8100}" NOTEBOOK_CROSS_ORIGIN_ISOLATION=true ./run-smoke.sh
coep_failed=$([ $? -ne 0 ] && echo 1 || echo 0)

echo
echo "=== selftest 3/3: SMOKE_SIMULATE_FROZEN=1 (no service worker) — expect FAIL (input freeze) ==="
PORT="${PORT_FROZEN:-8101}" NOTEBOOK_CROSS_ORIGIN_ISOLATION=false SMOKE_SIMULATE_FROZEN=1 ./run-smoke.sh
frozen_failed=$([ $? -ne 0 ] && echo 1 || echo 0)

echo
if [ "$good_ok" -eq 1 ] && [ "$coep_failed" -eq 1 ] && [ "$frozen_failed" -eq 1 ]; then
  echo "SELFTEST PASS — passes on the good config and fails on both the COEP block and the freeze."
  exit 0
fi
echo "SELFTEST FAIL — the smoke test is not discriminating:"
echo "  good config passed?      $good_ok       (want 1)"
echo "  COEP config failed?      $coep_failed   (want 1)"
echo "  freeze config failed?    $frozen_failed (want 1)"
exit 1
