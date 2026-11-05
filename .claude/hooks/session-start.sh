#!/bin/bash
#
# Installs the Swift toolchain into the Claude Code on the web sandbox so
# `swift build` / `swift test` work during the session.  Local Claude Code
# sessions skip this (the user manages their own toolchain on the laptop).
#
# Version pin must match Dockerfile (Stage 1 FROM swift:X.Y-jammy) and
# Package.swift (swift-tools-version).  Update all three together.

set -euo pipefail

# Skip on local Claude Code sessions — the developer's toolchain is on disk.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
    exit 0
fi

# The full patch version: swift.org publishes 6.4 as `swift-6.4.0-RELEASE`
# (under `swift-6.4.0-release/`), while 6.3 was published without the patch
# component. A two-part pin 404s.
SWIFT_VERSION="6.4.0"
SWIFT_PLATFORM="ubuntu24.04"
SWIFT_RELEASE="swift-${SWIFT_VERSION}-RELEASE"
SWIFT_DIR="${HOME}/swift/${SWIFT_RELEASE}-${SWIFT_PLATFORM}"
SWIFT_BIN="${SWIFT_DIR}/usr/bin"

if [ ! -x "${SWIFT_BIN}/swift" ]; then
    echo "Installing Swift ${SWIFT_VERSION} for ${SWIFT_PLATFORM}..."
    mkdir -p "${HOME}/swift"
    TARBALL_URL="https://download.swift.org/swift-${SWIFT_VERSION}-release/${SWIFT_PLATFORM/./}/${SWIFT_RELEASE}/${SWIFT_RELEASE}-${SWIFT_PLATFORM}.tar.gz"
    TMP_TARBALL="$(mktemp -t swift-XXXXXX.tar.gz)"
    trap 'rm -f "${TMP_TARBALL}"' EXIT
    curl -fL --retry 3 --retry-delay 5 -o "${TMP_TARBALL}" "${TARBALL_URL}"
    tar -xzf "${TMP_TARBALL}" -C "${HOME}/swift"
    rm -f "${TMP_TARBALL}"
    trap - EXIT
    echo "Swift installed at ${SWIFT_DIR}"
fi

"${SWIFT_BIN}/swift" --version

# Persist PATH for the session so subsequent shells see swift.
echo "export PATH=\"${SWIFT_BIN}:\$PATH\"" >> "${CLAUDE_ENV_FILE}"

# A local Postgres for the test suite, which has no other backend. The tests
# default to localhost:5432, database chickadee_test, user and password
# postgres (DatabaseSettings.localTest). Best effort: a missing server or a
# failed start prints a note and leaves the session usable, and `swift test`
# then names the database it could not reach.
start_test_postgres() {
    local pg_bin pg_data="/tmp/chickadee-test-postgres"
    pg_bin="$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)"
    if [ -z "${pg_bin}" ] || [ ! -x "${pg_bin}/pg_ctl" ]; then
        echo "Postgres binaries not found; install PostgreSQL to run APITests."
        return 0
    fi
    if "${pg_bin}/pg_isready" -q -h localhost -p 5432; then
        echo "Postgres already accepting connections on localhost:5432."
    else
        local as_pg=()
        if [ "$(id -u)" = "0" ]; then
            as_pg=(runuser -u postgres --)
        fi
        if [ ! -s "${pg_data}/PG_VERSION" ]; then
            mkdir -p "${pg_data}"
            if [ "$(id -u)" = "0" ]; then
                chown postgres:postgres "${pg_data}"
            fi
            "${as_pg[@]}" "${pg_bin}/initdb" -D "${pg_data}" -U postgres --auth=trust -E UTF8 >/dev/null
        fi
        "${as_pg[@]}" "${pg_bin}/pg_ctl" -D "${pg_data}" -l "${pg_data}/server.log" -w \
            -o "-c listen_addresses=localhost -c max_connections=300" start >/dev/null
    fi
    psql -h localhost -U postgres -d postgres -q -c "ALTER USER postgres PASSWORD 'postgres'" >/dev/null 2>&1 || true
    if ! psql -h localhost -U postgres -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = 'chickadee_test'" 2>/dev/null | grep -q 1; then
        psql -h localhost -U postgres -d postgres -q -c "CREATE DATABASE chickadee_test" >/dev/null 2>&1 || true
    fi
    echo "Postgres ready for APITests on localhost:5432 (database chickadee_test)."
}
start_test_postgres || echo "Could not start the test Postgres; APITests need one on localhost:5432."
