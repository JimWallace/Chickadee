#!/usr/bin/env bash
#
# run-visual.sh — boot a chickadee-server on an ephemeral SQLite DB, capture
# screenshots of the key pages in light + dark, and compare them against the
# committed baselines (#1136).  Server-boot logic mirrors
# Tools/editor-smoke-test/run-smoke.sh.
#
#   run-visual.sh            capture + compare (exit 1 on visual diff)
#   run-visual.sh --update   capture + overwrite baselines/ (commit the result)
#
# Env knobs:
#   CHICKADEE_SERVER_BIN   path to the built server (default: debug build)
#   PORT                   port to bind (default: 8123)
#   VISUAL_OUT             where captures/diffs go (default: mktemp -d)

set -euo pipefail
cd "$(dirname "$0")"

REPO_ROOT="$(cd ../.. && pwd)"
PORT="${PORT:-8123}"
BIN="${CHICKADEE_SERVER_BIN:-$REPO_ROOT/.build/debug/chickadee-server}"
WORKDIR="$(mktemp -d)"
OUT="${VISUAL_OUT:-$WORKDIR/out}"
LOG="$WORKDIR/server.log"
MODE="${1:-compare}"

if [ ! -x "$BIN" ]; then
  alt="$(ls "$REPO_ROOT"/.build/*/debug/chickadee-server 2>/dev/null | head -1 || true)"
  if [ -n "$alt" ]; then BIN="$alt"; else
    echo "run-visual: server binary not found (set CHICKADEE_SERVER_BIN or run 'swift build')" >&2
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

echo "run-visual: booting $BIN on 127.0.0.1:$PORT"
(
  cd "$REPO_ROOT"
  ENABLE_NON_SSO_AUTH_MODES=true \
  AUTH_MODE=local \
  DATABASE_BACKEND=sqlite \
  SQLITE_PATH="$WORKDIR/visual.sqlite" \
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
    echo "run-visual: server exited during boot — log follows:" >&2
    tail -20 "$LOG" >&2
    exit 2
  fi
  sleep 1
done
if [ "$ready" -ne 1 ]; then
  echo "run-visual: server did not become ready — log follows:" >&2
  tail -20 "$LOG" >&2
  exit 2
fi

mkdir -p "$OUT/capture"
set +e
node capture.mjs "http://127.0.0.1:$PORT" "$OUT/capture"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  echo "run-visual: capture failed (rc=$rc) — server log tail:" >&2
  tail -40 "$LOG" >&2 || true
  exit "$rc"
fi

if [ "$MODE" = "--update" ]; then
  mkdir -p baselines
  rm -f baselines/*.png
  cp "$OUT/capture/"*.png baselines/
  echo "run-visual: baselines updated ($(ls baselines/*.png | wc -l | tr -d ' ') pages) — review and commit."
  exit 0
fi

if ! ls baselines/*.png >/dev/null 2>&1; then
  # Bootstrap mode: no baselines committed yet.  Leave the captures where CI
  # can pick them up as an artifact and succeed — committing them flips the
  # harness to enforcing.
  mkdir -p "$REPO_ROOT/visual-bootstrap"
  cp "$OUT/capture/"*.png "$REPO_ROOT/visual-bootstrap/"
  echo "run-visual: NO BASELINES COMMITTED — captures saved to visual-bootstrap/."
  echo "            Commit them to Tools/visual-regression/baselines/ to enable enforcement."
  exit 0
fi

mkdir -p "$OUT/diff"
set +e
node compare.mjs baselines "$OUT/capture" "$OUT/diff"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  # Preserve evidence for the CI artifact step.
  mkdir -p "$REPO_ROOT/visual-diffs"
  cp "$OUT/diff/"* "$REPO_ROOT/visual-diffs/" 2>/dev/null || true
  cp "$OUT/capture/"*.png "$REPO_ROOT/visual-diffs/" 2>/dev/null || true
fi
exit "$rc"
