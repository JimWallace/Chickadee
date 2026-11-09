# Tools/perf-bench/env.sh — sourced by every script here.
#
# The benchmark database, the release server and the work folder. Nothing here
# is read by the server's own configuration: start-server.sh passes the
# server's existing variables (docs/database-performance.md, "Re-run").
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
PERF_DB=${PERF_DB:-chickadee_perf}
PERF_PORT=${PERF_PORT:-8080}
BASE=${BASE:-http://127.0.0.1:$PERF_PORT}
# Cookie jars, the runner secret, ids and results. Outside the repository.
WORK=${PERF_WORK:-/tmp/chickadee-perf}
mkdir -p "$WORK/jars" "$WORK/out/pages" "$WORK/out/load"
PSQL_BASE="psql -h ${PGHOST:-localhost} -U ${PGUSER:-postgres} -X -q"
PSQL="$PSQL_BASE -d $PERF_DB"
