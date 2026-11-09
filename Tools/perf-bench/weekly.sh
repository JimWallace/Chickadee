#!/usr/bin/env bash
# The weekly performance check (docs/database-performance.md, "The weekly
# check"). Builds the release server and the load tool, builds the data set,
# measures every page and runs the claim scenarios, then prints one summary
# to compare with the baseline table. Takes about 25 minutes, most of it the
# release build.
set -euo pipefail
. "$(dirname "$0")/env.sh"
cd "$REPO"
swift build -c release --product chickadee-server
swift build -c release --product chickadee-loadtest
cd "$HERE"
./setup.sh
./start-server.sh > "$WORK/server.log" 2>&1 &
trap 'kill %1 2>/dev/null || true' EXIT
for _ in $(seq 1 180); do curl -s -o /dev/null "$BASE/login" && break; sleep 1; done
./measure-all.sh > /dev/null
./bench.sh weekly
$PSQL -A -t -f sql/fk-unindexed.sql > "$WORK/out/fk-unindexed.txt"

echo "== pages: stmts/req, db_ms/req, rows/req; then curl code, seconds, bytes"
for f in "$WORK"/out/pages/*.txt; do
  printf '%-26s %s | %s\n' "$(basename "$f" .txt)" "$(sed -n 's/^stmts/stmts/p' "$f" | head -1)" \
    "$(grep -m1 '^curl:' "$f")"
done
echo "== claims"
for f in "$WORK"/out/load/weekly-*.txt; do
  case "$f" in *.client.txt) continue ;; esac
  printf '%-22s %s | %s | %s\n' "$(basename "$f" .txt)" "$(grep -m1 'requests:' "$f" | xargs)" \
    "$(grep -m1 'latency:' "$f" | xargs)" "$(grep -m1 'server CPU' "$f")"
done
echo "== foreign keys with no leading index (should match ForeignKeyIndexCoverageTests)"
wc -l < "$WORK/out/fk-unindexed.txt"
