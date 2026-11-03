# scratch-database.sh — a throwaway Postgres database for one server boot.
# Sourced by the browser harnesses (Tools/editor-smoke-test/run-smoke.sh and
# Tools/visual-regression/run-*.sh); not executable on its own.
#
# Each harness boots a fresh chickadee-server and expects an empty database,
# and some CI jobs boot several servers in a row in one job. Postgres is the
# only backend, so each boot gets its own database, created here and dropped
# by the harness's EXIT trap.
#
# The admin connection uses the variables the API test suite already reads:
# TEST_DATABASE_HOST, TEST_DATABASE_PORT, TEST_DATABASE_USER and
# TEST_DATABASE_PASSWORD. They default to a local Postgres on localhost:5432
# with user and password `postgres`, the same defaults as the test suite.
# The new database's settings are exported as the DATABASE_* variables that
# the server reads.

chickadee_scratch_db_psql() {
    PGPASSWORD="$CHICKADEE_SCRATCH_DB_PASSWORD" psql \
        -h "$CHICKADEE_SCRATCH_DB_HOST" \
        -p "$CHICKADEE_SCRATCH_DB_PORT" \
        -U "$CHICKADEE_SCRATCH_DB_USER" \
        -d postgres \
        -v ON_ERROR_STOP=1 -q -X "$@"
}

# Create the database and export DATABASE_* for the server. $1 is a short
# lowercase label for the database name, such as `smoke`.
chickadee_scratch_db_create() {
    if ! command -v psql >/dev/null 2>&1; then
        echo "scratch-database: psql not found; install the PostgreSQL client" >&2
        return 2
    fi
    CHICKADEE_SCRATCH_DB_HOST="${TEST_DATABASE_HOST:-localhost}"
    CHICKADEE_SCRATCH_DB_PORT="${TEST_DATABASE_PORT:-5432}"
    CHICKADEE_SCRATCH_DB_USER="${TEST_DATABASE_USER:-postgres}"
    CHICKADEE_SCRATCH_DB_PASSWORD="${TEST_DATABASE_PASSWORD:-postgres}"
    CHICKADEE_SCRATCH_DB_NAME="chickadee_${1}_$$_$(date +%s)_${RANDOM}"
    if ! chickadee_scratch_db_psql -c "CREATE DATABASE \"$CHICKADEE_SCRATCH_DB_NAME\""; then
        echo "scratch-database: could not create $CHICKADEE_SCRATCH_DB_NAME on" \
            "$CHICKADEE_SCRATCH_DB_HOST:$CHICKADEE_SCRATCH_DB_PORT" >&2
        CHICKADEE_SCRATCH_DB_NAME=""
        return 2
    fi
    export DATABASE_HOST="$CHICKADEE_SCRATCH_DB_HOST"
    export DATABASE_PORT="$CHICKADEE_SCRATCH_DB_PORT"
    export DATABASE_NAME="$CHICKADEE_SCRATCH_DB_NAME"
    export DATABASE_USER="$CHICKADEE_SCRATCH_DB_USER"
    export DATABASE_PASSWORD="$CHICKADEE_SCRATCH_DB_PASSWORD"
}

# Drop the database. Safe to call when creation never ran or failed, and
# after the server has exited. FORCE ends any connection a server left open.
chickadee_scratch_db_drop() {
    if [ -z "${CHICKADEE_SCRATCH_DB_NAME:-}" ]; then
        return 0
    fi
    chickadee_scratch_db_psql \
        -c "DROP DATABASE IF EXISTS \"$CHICKADEE_SCRATCH_DB_NAME\" WITH (FORCE)" \
        >/dev/null 2>&1 || true
    CHICKADEE_SCRATCH_DB_NAME=""
}
