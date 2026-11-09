#!/usr/bin/env bash
# Starts the release server against the benchmark database, from the
# repository root (it serves Public/). Uses only variables the server already
# reads.
. "$(dirname "$0")/env.sh"
cd "$REPO" || exit 1
[ -f "$WORK/runner-secret" ] || head -c 24 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' > "$WORK/runner-secret"
export DATABASE_HOST=${PGHOST:-localhost} DATABASE_PORT=5432 DATABASE_NAME=$PERF_DB
export DATABASE_USER=${PGUSER:-postgres} DATABASE_PASSWORD=${PGPASSWORD:-postgres}
export AUTH_MODE=local ENABLE_NON_SSO_AUTH_MODES=true
RUNNER_SHARED_SECRET="$(cat "$WORK/runner-secret")"
export RUNNER_SHARED_SECRET
export LOG_LEVEL=${LOG_LEVEL:-warning}
exec .build/release/chickadee-server serve --hostname 127.0.0.1 --port "$PERF_PORT" --env production
