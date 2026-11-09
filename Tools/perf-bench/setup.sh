#!/usr/bin/env bash
# Builds the benchmark data set from nothing: a fresh database that the server
# migrates, an admin and an instructor made through /register, course STAT231
# made through the admin route, then sql/seed.sql (300 students, 12
# assignments, about 18,000 submissions and 400,000 request metrics), the ids
# the page measurements use, and a signed-in cookie jar per role.
#
# Drops and recreates the benchmark database. Needs a release build
# (swift build -c release --product chickadee-server) and a Postgres with
# pg_stat_statements in shared_preload_libraries.
set -euo pipefail
. "$(dirname "$0")/env.sh"
cd "$HERE"

$PSQL_BASE -d postgres -c "DROP DATABASE IF EXISTS $PERF_DB" -c "CREATE DATABASE $PERF_DB"
$PSQL -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements"
mkdir -p "$WORK/setups" "$WORK/subs"

./start-server.sh > "$WORK/setup-server.log" 2>&1 &
trap 'kill %1 2>/dev/null || true' EXIT
for _ in $(seq 1 180); do curl -s -o /dev/null "$BASE/login" && break; sleep 1; done

# The first account to register becomes the deployment admin.
./login.sh register perfadmin perf-password-1 "$WORK/jars/admin.txt"
./login.sh register template perf-password-1 "$WORK/jars/inst.txt"
./post.sh "$WORK/jars/admin.txt" /admin/courses \
  --data-urlencode code=STAT231 --data-urlencode "name=Statistics" \
  --data-urlencode termYear=2026 --data-urlencode termSeason=fall --data-urlencode instructor=template

$PSQL -f sql/seed.sql > "$WORK/seed.log"
$PSQL -A -t -f sql/ids.sql > "$WORK/ids.env"
./login.sh login stu001 perf-password-1 "$WORK/jars/stu.txt"
./login.sh login template perf-password-1 "$WORK/jars/inst.txt"
./login.sh login perfadmin perf-password-1 "$WORK/jars/admin.txt"
$PSQL -f sql/rowcounts.sql | head -15
echo "setup done: ids in $WORK/ids.env"
