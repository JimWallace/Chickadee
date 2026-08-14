#!/usr/bin/env bash
#
# run-repaint-probe.sh — boot a chickadee-server, seed it, and check that a
# background table repaint keeps the shared widgets working.
#
# The visual-regression capture screenshots ~300ms after load, so it never
# sees a poll repaint. That leaves the interaction of four consolidations
# unverified: the poll swaps in server-rendered rows, which must still resolve
# sprite icons, still carry the sort the user chose, and still respect the
# filter box. Each of those fails silently.
#
# Server-boot logic mirrors run-visual.sh.

set -euo pipefail
cd "$(dirname "$0")"

REPO_ROOT="$(cd ../.. && pwd)"
PORT="${PORT:-8127}"
BIN="${CHICKADEE_SERVER_BIN:-$REPO_ROOT/.build/debug/chickadee-server}"
WORKDIR="$(mktemp -d)"
LOG="$WORKDIR/server.log"

if [ ! -x "$BIN" ]; then
  # SwiftPM puts the binary under an arch-triple directory on some hosts, CI
  # among them. run-visual.sh carries the same fallback; without it this probe
  # passes locally and cannot find the server in the job that runs it.
  alt="$(ls "$REPO_ROOT"/.build/*/debug/chickadee-server 2>/dev/null | head -1 || true)"
  if [ -n "$alt" ]; then BIN="$alt"; else
    echo "run-repaint-probe: server binary not found (set CHICKADEE_SERVER_BIN or run 'swift build')" >&2
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

(
  cd "$REPO_ROOT"
  ENABLE_NON_SSO_AUTH_MODES=true \
  AUTH_MODE=local \
  DATABASE_BACKEND=sqlite \
  SQLITE_PATH="$WORKDIR/probe.sqlite" \
  MCP_MODE=off \
  LOG_LEVEL=error \
    exec "$BIN" serve --hostname 127.0.0.1 --port "$PORT"
) >"$LOG" 2>&1 &
SRV_PID=$!

ready=0
for _ in $(seq 1 40); do
  if curl -fsS --max-time 2 -o /dev/null "http://127.0.0.1:$PORT/login" 2>/dev/null; then
    ready=1; break
  fi
  if ! kill -0 "$SRV_PID" 2>/dev/null; then
    echo "run-repaint-probe: server exited during boot — log follows:" >&2
    tail -20 "$LOG" >&2; exit 2
  fi
  sleep 1
done
[ "$ready" -eq 1 ] || { echo "run-repaint-probe: server never became ready" >&2; tail -20 "$LOG" >&2; exit 2; }

node -e '
  import("./seed.mjs").then(async ({ seed }) => {
    const s = await seed(process.argv[1]);
    require("fs").writeFileSync(process.argv[2], JSON.stringify(s.instructorState));
  }).catch((e) => { console.error(e); process.exit(1); });
' "http://127.0.0.1:$PORT" "$WORKDIR/instructor.json"

node repaint-probe.mjs "http://127.0.0.1:$PORT" "$WORKDIR/instructor.json"
