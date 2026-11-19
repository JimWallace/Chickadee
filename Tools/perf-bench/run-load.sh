#!/usr/bin/env bash
# Usage: run-load.sh LABEL DURATION [chickadee-loadtest args...]
# Resets pg_stat_statements, runs chickadee-loadtest (docs/load-testing.md),
# and writes the client report, the server's CPU over the run and the
# statement profile to $WORK/out/load/LABEL.txt.
set -euo pipefail
. "$(dirname "$0")/env.sh"
LABEL=$1; DUR=$2; shift 2
OUT=$WORK/out/load
Q="$PSQL -A -t"
FILTER="d.datname='$PERF_DB' and query not ilike '%pg_stat_statements%'"
PID=$(pgrep -f 'chickadee-server serve' | head -1 || true)
[ -n "$PID" ] || { echo "run-load.sh: no running chickadee-server (start-server.sh)" >&2; exit 1; }
# CPU seconds (user + system) the server has used. Linux has /proc; macOS
# does not, so there the cumulative time comes from ps ([[HH:]MM:]SS.ss).
cpu_seconds() {
  if [ -r "/proc/$1/stat" ]; then
    awk -v t="$(getconf CLK_TCK)" '{printf "%.2f", ($14 + $15) / t}' "/proc/$1/stat"
  else
    ps -o time= -p "$1" | awk -F: '{s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; printf "%.2f", s}'
  fi
}
$Q -c "select pg_stat_statements_reset()" >/dev/null
T0=$(cpu_seconds "$PID")
"$REPO/.build/release/chickadee-loadtest" --base-url "$BASE" --duration "$DUR" \
  --runner-secret-file "$WORK/runner-secret" "$@" > "$OUT/$LABEL.client.txt" 2>&1
T1=$(cpu_seconds "$PID")
{
  echo "== $LABEL ($*) duration=${DUR}s"
  cat "$OUT/$LABEL.client.txt"
  awk -v a="$T0" -v b="$T1" -v d="$DUR" \
    'BEGIN {printf "server CPU: %.0fs over %ss (%.0f%% of one core)\n", b - a, d, (b - a) * 100 / d}'
  $Q -F ' | ' -c "
    select 'total stmts=' || sum(calls), 'db_ms=' || round(sum(total_exec_time)::numeric,0)
    from pg_stat_statements s join pg_database d on d.oid=s.dbid where $FILTER"
  echo '-- top statements by total time (calls, total_ms, mean_ms, rows, query)'
  $Q -F ' | ' -c "
    select calls, round(total_exec_time::numeric,0), round(mean_exec_time::numeric,3), rows,
           left(regexp_replace(query,'\s+',' ','g'),200)
    from pg_stat_statements s join pg_database d on d.oid=s.dbid where $FILTER
    order by total_exec_time desc limit 10"
} > "$OUT/$LABEL.txt"
