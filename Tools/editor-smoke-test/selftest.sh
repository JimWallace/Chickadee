#!/usr/bin/env bash
#
# selftest.sh — prove the editor is healthy AND that the smoke test detects the
# regressions it exists to catch. The editor is now cross-origin isolated
# unconditionally (SharedArrayBuffer path), so this runs four ways against one
# server build:
#
#   1. default boot — must PASS, and must report crossOriginIsolated=true
#      (SMOKE_EXPECT_ISOLATED=1): the editor boots isolated and input() round-
#      trips over SharedArrayBuffer. This is also the live worker-block guard —
#      if the asset middlewares stop stamping COEP on the kernel worker chunk,
#      Chrome blocks the worker and this flips to FAIL.
#   2. SMOKE_SIMULATE_FROZEN=1 (service worker disabled) — must STILL PASS, and
#      still crossOriginIsolated=true: with SAB carrying synchronous stdin the
#      kernel no longer needs the service worker, so killing it must not break
#      the editor. This is the proof that the SW-control "Kernel Unknown" race
#      is gone.
#   3. SMOKE_SIMULATE_NO_SYNC=1 (service worker disabled AND isolation headers
#      stripped off the editor document) — must FAIL: with neither the SW nor
#      SAB, input()/stdin has no synchronous path and the editor goes "Page
#      Unresponsive" (#959). Proves the input() freeze probe is discriminating.
#   4. SMOKE_SIMULATE_NO_WAITASYNC=1 (native Atomics.waitAsync deleted) — must
#      STILL PASS, crossOriginIsolated=true: the kernel's waitAsync polyfill
#      worker is vended as a blob: URL (not data:), which CSP worker-src and COEP
#      both allow, so engines without native waitAsync (older Safari / iPadOS)
#      boot the kernel isolated. Guards scripts/patch-pyodide-waitasync-worker.py.
#
# If a must-pass config fails or the must-fail config passes, the editor / smoke
# test is not behaving and this exits non-zero — i.e. it guards the guard.

set -uo pipefail
cd "$(dirname "$0")"

echo "=== selftest 1/4: default boot — expect PASS (isolated, SharedArrayBuffer path) ==="
PORT="${PORT_GOOD:-8099}" SMOKE_EXPECT_ISOLATED=1 ./run-smoke.sh
good_ok=$([ $? -eq 0 ] && echo 1 || echo 0)

echo
echo "=== selftest 2/4: service worker disabled — expect PASS (SAB independent of the SW) ==="
PORT="${PORT_NOSW:-8100}" SMOKE_SIMULATE_FROZEN=1 SMOKE_EXPECT_ISOLATED=1 ./run-smoke.sh
no_sw_ok=$([ $? -eq 0 ] && echo 1 || echo 0)

echo
echo "=== selftest 3/4: no SW and no SAB — expect FAIL (input freeze) ==="
PORT="${PORT_FROZEN:-8101}" SMOKE_SIMULATE_NO_SYNC=1 ./run-smoke.sh
frozen_failed=$([ $? -ne 0 ] && echo 1 || echo 0)

echo
echo "=== selftest 4/5: no native Atomics.waitAsync — expect PASS (blob: polyfill worker) ==="
PORT="${PORT_NOWAITASYNC:-8102}" SMOKE_SIMULATE_NO_WAITASYNC=1 SMOKE_EXPECT_ISOLATED=1 ./run-smoke.sh
no_waitasync_ok=$([ $? -eq 0 ] && echo 1 || echo 0)

echo
echo "=== selftest 5/5: post-idle execute — expect PASS (cell still runs after idling) ==="
# Closes the lifecycle gap that hid the post-idle exec_hang: every other probe
# runs at t≈0; this idles, then executes again. Can't reproduce the prod hang
# (a headless tab is never throttled) but guards that post-idle execution works.
PORT="${PORT_POSTIDLE:-8103}" SMOKE_POST_IDLE_MS=8000 SMOKE_EXPECT_ISOLATED=1 ./run-smoke.sh
post_idle_ok=$([ $? -eq 0 ] && echo 1 || echo 0)

echo
if [ "$good_ok" -eq 1 ] && [ "$no_sw_ok" -eq 1 ] && [ "$frozen_failed" -eq 1 ] \
   && [ "$no_waitasync_ok" -eq 1 ] && [ "$post_idle_ok" -eq 1 ]; then
  echo "SELFTEST PASS — editor boots isolated, survives losing the service worker"
  echo "(SharedArrayBuffer), boots on engines without native Atomics.waitAsync"
  echo "(blob: polyfill worker), executes a cell after idling (post-idle guard),"
  echo "and the freeze probe still catches a no-sync editor."
  exit 0
fi
echo "SELFTEST FAIL — the editor / smoke test is not behaving:"
echo "  default isolated boot passed?     $good_ok       (want 1)"
echo "  survives SW removal (SAB)?        $no_sw_ok      (want 1)"
echo "  no-sync freeze detected?          $frozen_failed (want 1)"
echo "  boots with no native waitAsync?   $no_waitasync_ok (want 1)"
echo "  post-idle execute passed?         $post_idle_ok  (want 1)"
exit 1
