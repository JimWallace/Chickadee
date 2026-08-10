#!/usr/bin/env bash
#
# run-smoke.sh — boot a chickadee-server, run the headless-browser editor smoke
# test against it, tear it down, and exit with the test's result.
#
# This is the single-config runner (used by CI and by selftest.sh). It boots
# the server with local auth on an ephemeral SQLite DB so no external services
# are needed, then drives the real JupyterLite editor through the real
# middleware chain — which is where the COEP/header regressions actually bit us.
#
# Env knobs:
#   CHICKADEE_SERVER_BIN   path to the built server (default: debug build)
#   PORT                   port to bind (default: 8099)
#   SMOKE_* knobs (SMOKE_SIMULATE_FROZEN / SMOKE_SIMULATE_NO_SYNC /
#                  SMOKE_EXPECT_ISOLATED)  read by editor-check.mjs, inherited
#                  from the environment (the selftest sets them per config).
#
# The editor is cross-origin isolated unconditionally now, so there is no
# server-side isolation flag to forward.
#
# Exit 0 = editor healthy; non-zero = broken (or boot/setup failure).

set -euo pipefail
cd "$(dirname "$0")"

REPO_ROOT="$(cd ../.. && pwd)"
PORT="${PORT:-8099}"
BIN="${CHICKADEE_SERVER_BIN:-$REPO_ROOT/.build/debug/chickadee-server}"
WORKDIR="$(mktemp -d)"
LOG="$WORKDIR/server.log"

if [ ! -x "$BIN" ]; then
  # Fall back to the platform-triple debug path (Linux CI layout).
  alt="$(ls "$REPO_ROOT"/.build/*/debug/chickadee-server 2>/dev/null | head -1 || true)"
  if [ -n "$alt" ]; then BIN="$alt"; else
    echo "run-smoke: server binary not found (set CHICKADEE_SERVER_BIN or run 'swift build')" >&2
    exit 2
  fi
fi

cleanup() {
  if [ -n "${SRV_PID:-}" ] && kill -0 "$SRV_PID" 2>/dev/null; then
    kill "$SRV_PID" 2>/dev/null || true
    wait "$SRV_PID" 2>/dev/null || true
  fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo "run-smoke: booting $BIN on 127.0.0.1:$PORT"
# Launch from the repo root: Vapor's DirectoryConfiguration.detect() resolves
# Public/ (the vended JupyterLite + Pyodide the editor loads) from the working
# directory, so the server must run with the repo root as its CWD — not this
# script's directory.
(
  cd "$REPO_ROOT"
  ENABLE_NON_SSO_AUTH_MODES=true \
  AUTH_MODE=local \
  DATABASE_BACKEND=sqlite \
  SQLITE_PATH="$WORKDIR/smoke.sqlite" \
  MCP_MODE=off \
  LOG_LEVEL=info \
    exec "$BIN" serve --hostname 127.0.0.1 --port "$PORT"
) >"$LOG" 2>&1 &
SRV_PID=$!

# Wait for readiness (up to ~40s).
ready=0
for _ in $(seq 1 40); do
  if curl -fsS --max-time 2 -o /dev/null "http://127.0.0.1:$PORT/login" 2>/dev/null; then
    ready=1
    break
  fi
  if ! kill -0 "$SRV_PID" 2>/dev/null; then
    echo "run-smoke: server exited during boot — log follows:" >&2
    tail -20 "$LOG" >&2
    exit 2
  fi
  sleep 1
done
if [ "$ready" -ne 1 ]; then
  echo "run-smoke: server did not become ready — log follows:" >&2
  tail -20 "$LOG" >&2
  exit 2
fi

# Run the check; on failure dump the server log tail BEFORE the EXIT trap wipes
# the work dir, so a server-side 500 (e.g. a SQLite "database is locked") is
# visible in CI instead of hiding behind the browser's generic "500" message.
set +e
node "${SMOKE_CHECK:-editor-check.mjs}" "http://127.0.0.1:$PORT"
check_rc=$?
set -e
if [ "$check_rc" -ne 0 ]; then
  # The error lines FIRST, from the whole log, because the tail below often
  # cannot show them. When a submit 500s the page keeps polling the submission
  # for the probe's full 300 s budget, so by the time the check gives up the
  # last 40 lines are several hundred INFO polls and the 500 that caused the
  # failure has scrolled away — which is exactly what happened on the third
  # sighting of the result-POST intermittent (docs/ci-flakiness.md, Family 2's
  # "not the exec-hang" note). The tail is kept: it is the right view when the
  # server died or never got that far.
  echo "run-smoke: check failed (rc=$check_rc) — server errors:" >&2
  grep -aE '\[ (ERROR|CRITICAL|WARNING) \]|status_code: 5[0-9][0-9]' "$LOG" \
    | tail -40 >&2 || true
  echo "run-smoke: server log tail:" >&2
  tail -40 "$LOG" >&2 || true
fi
exit "$check_rc"
