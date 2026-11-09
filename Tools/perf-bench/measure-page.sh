#!/usr/bin/env bash
# Usage: measure-page.sh LABEL JAR URL [N]
# Warms the page once, resets pg_stat_statements, requests it N times
# (default 5), then prints statements per request, database ms per request,
# the curl wall times and the top statements. Writes $WORK/out/pages/LABEL.txt.
set -euo pipefail
. "$(dirname "$0")/env.sh"
LABEL=$1; JAR=$2; URL=$3; N=${4:-5}
Q="$PSQL -A -t"
FILTER="d.datname='$PERF_DB' and query not ilike '%pg_stat_statements%'"

curl -s -b "$JAR" -c "$JAR" -o /dev/null "$BASE$URL"
$Q -c "select pg_stat_statements_reset()" >/dev/null
TIMES=()
for _ in $(seq 1 "$N"); do
  TIMES+=("$(curl -s -b "$JAR" -c "$JAR" -o "$WORK/page.body" \
    -w '%{http_code} %{time_total} %{size_download}' "$BASE$URL")")
done
{
  echo "== $LABEL  $URL  (N=$N)"
  printf 'curl: %s\n' "${TIMES[@]}"
  $Q -F ' | ' -c "
    select 'stmts/req=' || round(sum(calls)::numeric/$N,1),
           'db_ms/req=' || round((sum(total_exec_time)/$N)::numeric,2),
           'rows/req=' || round(sum(rows)::numeric/$N,0)
    from pg_stat_statements s join pg_database d on d.oid=s.dbid where $FILTER"
  echo "-- top statements (calls/req, ms/req, rows/req, query)"
  $Q -F ' | ' -c "
    select round(calls::numeric/$N,1), round((total_exec_time/$N)::numeric,2),
           round(rows::numeric/$N,0), left(regexp_replace(query,'\s+',' ','g'),260)
    from pg_stat_statements s join pg_database d on d.oid=s.dbid where $FILTER
    order by total_exec_time desc limit 10"
  echo
} | tee "$WORK/out/pages/$LABEL.txt"
