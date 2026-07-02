#!/usr/bin/env bash
#
# run-a11y.sh — boot a chickadee-server and run the axe-core accessibility
# scan (a11y.mjs, #1137) against it.  Server-boot logic mirrors run-visual.sh.
#
#   run-a11y.sh          scan (exit 1 on critical/serious or ratchet growth)
#
# Env knobs:
#   CHICKADEE_SERVER_BIN   path to the built server (default: debug build)
#   PORT                   port to bind (default: 8124)

set -euo pipefail
cd "$(dirname "$0")"

REPO_ROOT="$(cd ../.. && pwd)"
PORT="${PORT:-8124}"
BIN="${CHICKADEE_SERVER_BIN:-$REPO_ROOT/.build/debug/chickadee-server}"
WORKDIR="$(mktemp -d)"
LOG="$WORKDIR/server.log"

if [ ! -x "$BIN" ]; then
  alt="$(ls "$REPO_ROOT"/.build/*/debug/chickadee-server 2>/dev/null | head -1 || true)"
  if [ -n "$alt" ]; then BIN="$alt"; else
    echo "run-a11y: server binary not found (set CHICKADEE_SERVER_BIN or run 'swift build')" >&2
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

echo "run-a11y: booting $BIN on 127.0.0.1:$PORT"
(
  cd "$REPO_ROOT"
  ENABLE_NON_SSO_AUTH_MODES=true \
  AUTH_MODE=local \
  DATABASE_BACKEND=sqlite \
  SQLITE_PATH="$WORKDIR/a11y.sqlite" \
  MCP_MODE=off \
  LOG_LEVEL=info \
    exec "$BIN" serve --hostname 127.0.0.1 --port "$PORT"
) >"$LOG" 2>&1 &
SRV_PID=$!

ready=0
for _ in $(seq 1 40); do
  if curl -fsS --max-time 2 -o /dev/null "http://127.0.0.1:$PORT/login" 2>/dev/null; then
    ready=1
    break
  fi
  if ! kill -0 "$SRV_PID" 2>/dev/null; then
    echo "run-a11y: server exited during boot — log follows:" >&2
    tail -20 "$LOG" >&2
    exit 2
  fi
  sleep 1
done
if [ "$ready" -ne 1 ]; then
  echo "run-a11y: server did not become ready — log follows:" >&2
  tail -20 "$LOG" >&2
  exit 2
fi

set +e
node a11y.mjs "http://127.0.0.1:$PORT"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  echo "run-a11y: scan failed (rc=$rc) — server log tail:" >&2
  tail -40 "$LOG" >&2 || true
fi
exit "$rc"
