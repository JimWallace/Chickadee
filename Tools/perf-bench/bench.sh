#!/usr/bin/env bash
# Usage: bench.sh PREFIX
# The runner-claim scenarios: a 20,000-job backlog over twelve assignments
# with 100 runners, then all on one assignment with 50, 100 and 200 runners.
# The server must be running (start-server.sh). Each run is 30 s; results
# land in $WORK/out/load/PREFIX-*.txt. Leaves the backlog cleared.
set -euo pipefail
. "$(dirname "$0")/env.sh"
cd "$HERE"
P=$1
# The twelve-assignment spread first: backlog.sql resets the rows but does
# not move them back off the one assignment.
$PSQL -f sql/backlog-clear.sql >/dev/null 2>&1
$PSQL -v n=20000 -f sql/backlog.sql >/dev/null
./run-load.sh "$P-twelve-100" 30 --runners 100 --runner-poll-interval 1
for n in 50 100 200; do
  $PSQL -v n=20000 -f sql/backlog.sql >/dev/null
  $PSQL -f sql/backlog-one.sql >/dev/null
  ./run-load.sh "$P-one-$n" 30 --runners "$n" --runner-poll-interval 1
done
$PSQL -f sql/backlog-clear.sql >/dev/null
