#!/usr/bin/env bash
#
# selftest.sh — prove the smoke test actually detects the regressions it exists
# to catch AND that both editor sync paths (service worker / SharedArrayBuffer)
# are healthy. Runs the editor check three ways against the same server build:
#
#   1. default config (service worker, NO cross-origin isolation) — must PASS,
#      and must report crossOriginIsolated=false (SMOKE_EXPECT_ISOLATED=0): the
#      kernel syncs stdin/Drive through the service worker;
#   2. NOTEBOOK_CROSS_ORIGIN_ISOLATION=true — must PASS, and must report
#      crossOriginIsolated=true (SMOKE_EXPECT_ISOLATED=1): the editor boots
#      cross-origin isolated and input() round-trips over SharedArrayBuffer,
#      with no dependence on the service worker.  Before the fast-path-isolation
#      fix this config FAILED, because COEP on the editor page blocked the
#      fast-path-served Pyodide kernel worker (its script was missing COEP).
#      This config is therefore ALSO the live worker-block guard: if the fix
#      regresses the worker block returns and this flips to FAIL (and the
#      SMOKE_EXPECT_ISOLATED=1 assertion catches a silent isolation regression
#      that would otherwise pass via the service-worker fallback);
#   3. SMOKE_SIMULATE_FROZEN=1 — must FAIL, because disabling the service worker
#      (and with COEP off, no SAB) leaves input()/stdin no synchronous path and
#      the editor goes "Page Unresponsive" (the #959 freeze).  Proves the
#      input() probe is discriminating.
#
# If a must-pass config fails or the must-fail config passes, the smoke test /
# fix is not behaving and this exits non-zero — i.e. it guards the guard.

set -uo pipefail
cd "$(dirname "$0")"

echo "=== selftest 1/3: default config — expect PASS (service-worker path) ==="
PORT="${PORT_GOOD:-8099}" NOTEBOOK_CROSS_ORIGIN_ISOLATION=false SMOKE_EXPECT_ISOLATED=0 ./run-smoke.sh
good_ok=$([ $? -eq 0 ] && echo 1 || echo 0)

echo
echo "=== selftest 2/3: NOTEBOOK_CROSS_ORIGIN_ISOLATION=true — expect PASS (SharedArrayBuffer path) ==="
PORT="${PORT_COEP:-8100}" NOTEBOOK_CROSS_ORIGIN_ISOLATION=true SMOKE_EXPECT_ISOLATED=1 ./run-smoke.sh
coep_ok=$([ $? -eq 0 ] && echo 1 || echo 0)

echo
echo "=== selftest 3/3: SMOKE_SIMULATE_FROZEN=1 (no service worker) — expect FAIL (input freeze) ==="
PORT="${PORT_FROZEN:-8101}" NOTEBOOK_CROSS_ORIGIN_ISOLATION=false SMOKE_SIMULATE_FROZEN=1 ./run-smoke.sh
frozen_failed=$([ $? -ne 0 ] && echo 1 || echo 0)

echo
if [ "$good_ok" -eq 1 ] && [ "$coep_ok" -eq 1 ] && [ "$frozen_failed" -eq 1 ]; then
  echo "SELFTEST PASS — passes on the service-worker config, passes on the isolated"
  echo "SharedArrayBuffer config, and fails on the input freeze."
  exit 0
fi
echo "SELFTEST FAIL — the smoke test is not discriminating:"
echo "  default (SW) config passed?       $good_ok       (want 1)"
echo "  isolated (SAB) config passed?     $coep_ok       (want 1)"
echo "  freeze config failed?             $frozen_failed (want 1)"
exit 1
