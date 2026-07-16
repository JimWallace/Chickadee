#!/usr/bin/env bash
#
# selftest.sh — prove the editor is healthy AND that the smoke test detects the
# regressions it exists to catch.
#
# The editor's kernel transport now depends on the browser ENGINE (SMOKE_BROWSER):
#
#   * Chromium / Blink / Gecko — cross-origin ISOLATED; the kernel syncs over
#     SharedArrayBuffer (`coincident`) and the service worker is redundant.
#   * WebKit (Safari / iOS) — NON-isolated; the kernel uses async `comlink` and
#     the JupyterLite service worker carries synchronous stdin/Drive. WebKit is
#     served this way because the SharedArrayBuffer/`coincident` handshake
#     deadlocks the kernel there — see
#     Sources/APIServer/Middleware/EditorEngineDetection.swift.
#
# So the isolation expectation inverts by engine, and the SharedArrayBuffer-only
# guards (survives-SW-removal; blob: waitAsync polyfill) are Chromium-only — on
# WebKit the SW is REQUIRED and `comlink` never touches Atomics.waitAsync. The
# shared guards (a healthy boot; the no-sync freeze detector; post-idle execute)
# run on both. Drive with SMOKE_BROWSER=chromium (default) or =webkit.

set -uo pipefail
cd "$(dirname "$0")"

ENGINE="${SMOKE_BROWSER:-chromium}"
if [ "$ENGINE" = "webkit" ]; then
  EXPECT_ISOLATED=0   # WebKit → non-isolated comlink + service-worker transport
else
  EXPECT_ISOLATED=1   # everyone else → isolated SharedArrayBuffer transport
fi
echo "### editor-smoke selftest — engine=$ENGINE; expect crossOriginIsolated=$EXPECT_ISOLATED ###"

echo
echo "=== selftest 1/5: default boot — expect PASS (isolated=$EXPECT_ISOLATED) ==="
PORT="${PORT_GOOD:-8099}" SMOKE_EXPECT_ISOLATED=$EXPECT_ISOLATED ./run-smoke.sh
good_ok=$([ $? -eq 0 ] && echo 1 || echo 0)

echo
if [ "$ENGINE" = "webkit" ]; then
  echo "=== selftest 2/5: survives-SW-removal — SKIPPED on WebKit (the SW is its sync path, not redundant) ==="
  no_sw_ok=1
else
  echo "=== selftest 2/5: service worker disabled — expect PASS (SAB independent of the SW) ==="
  PORT="${PORT_NOSW:-8100}" SMOKE_SIMULATE_FROZEN=1 SMOKE_EXPECT_ISOLATED=1 ./run-smoke.sh
  no_sw_ok=$([ $? -eq 0 ] && echo 1 || echo 0)
fi

echo
echo "=== selftest 3/5: no SW and no SAB — expect FAIL (input freeze; both engines) ==="
PORT="${PORT_FROZEN:-8101}" SMOKE_SIMULATE_NO_SYNC=1 ./run-smoke.sh
frozen_failed=$([ $? -ne 0 ] && echo 1 || echo 0)

echo
if [ "$ENGINE" = "webkit" ]; then
  echo "=== selftest 4/5: blob: waitAsync polyfill — SKIPPED on WebKit (comlink never uses Atomics.waitAsync) ==="
  no_waitasync_ok=1
else
  echo "=== selftest 4/5: no native Atomics.waitAsync — expect PASS (blob: polyfill worker) ==="
  PORT="${PORT_NOWAITASYNC:-8102}" SMOKE_SIMULATE_NO_WAITASYNC=1 SMOKE_EXPECT_ISOLATED=1 ./run-smoke.sh
  no_waitasync_ok=$([ $? -eq 0 ] && echo 1 || echo 0)
fi

echo
echo "=== selftest 5/5: post-idle execute — expect PASS (cell still runs after idling; both engines) ==="
# Closes the lifecycle gap that hid the post-idle exec_hang: every other probe
# runs at t≈0; this idles, then executes again. Can't reproduce the prod hang
# (a headless tab is never throttled) but guards that post-idle execution works.
PORT="${PORT_POSTIDLE:-8103}" SMOKE_POST_IDLE_MS=8000 SMOKE_EXPECT_ISOLATED=$EXPECT_ISOLATED ./run-smoke.sh
post_idle_ok=$([ $? -eq 0 ] && echo 1 || echo 0)

echo
if [ "$good_ok" -eq 1 ] && [ "$no_sw_ok" -eq 1 ] && [ "$frozen_failed" -eq 1 ] \
   && [ "$no_waitasync_ok" -eq 1 ] && [ "$post_idle_ok" -eq 1 ]; then
  echo "SELFTEST PASS ($ENGINE) — editor boots on its engine's transport"
  echo "(isolated=$EXPECT_ISOLATED), executes a cell after idling, and the freeze"
  echo "probe still catches a no-sync editor."
  exit 0
fi
echo "SELFTEST FAIL ($ENGINE) — the editor / smoke test is not behaving:"
echo "  default boot passed (isolated=$EXPECT_ISOLATED)?  $good_ok       (want 1)"
echo "  SW-removal guard behaved (chromium only)?         $no_sw_ok      (want 1)"
echo "  no-sync freeze detected?                          $frozen_failed (want 1)"
echo "  waitAsync guard behaved (chromium only)?          $no_waitasync_ok (want 1)"
echo "  post-idle execute passed?                         $post_idle_ok  (want 1)"
exit 1
