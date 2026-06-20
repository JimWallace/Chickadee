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

node editor-check.mjs "http://127.0.0.1:$PORT"
