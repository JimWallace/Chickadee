#!/usr/bin/env bash
# deployment-target-tests.sh — self-tests for scripts/lib/deployment-target.sh.
#
# Covers the decisions, not the Docker calls: the library is split so that
# everything that could route a restore at the wrong container is a pure
# function over observations, and the collectors around them are one-liners.
#
# Runs in format-lint. No Docker required.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/deployment-target.sh
. "$repo_root/scripts/lib/deployment-target.sh"

passed=0
failed=0

check() {  # $1 = description, $2 = expected, $3 = actual
    if [ "$2" = "$3" ]; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
        printf 'FAIL: %s\n      expected: %s\n      actual:   %s\n' "$1" "$2" "$3" >&2
    fi
}

# ---------------------------------------------------------------------------
# chickadee_compose_file_args
# ---------------------------------------------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
touch "$tmp/docker-compose.yml"

check "base compose file only" \
    "-f $tmp/docker-compose.yml" \
    "$(chickadee_compose_file_args "$tmp" | tr '\n' ' ' | sed 's/ $//')"

touch "$tmp/docker-compose.override.yml"
check "override file is included when present" \
    "-f $tmp/docker-compose.yml -f $tmp/docker-compose.override.yml" \
    "$(chickadee_compose_file_args "$tmp" | tr '\n' ' ' | sed 's/ $//')"

# The deploy scripts honour CHICKADEE_COMPOSE_FILE, so the base file is
# separable from the directory the override is looked for in.
touch "$tmp/custom.yml"
check "an explicit base file still picks up the override beside it" \
    "-f $tmp/custom.yml -f $tmp/docker-compose.override.yml" \
    "$(chickadee_compose_file_args "$tmp" "$tmp/custom.yml" | tr '\n' ' ' | sed 's/ $//')"

# ---------------------------------------------------------------------------
# chickadee_resolve_server_target — which container to READ from
# ---------------------------------------------------------------------------

# A compose-managed server outranks everything: that deployment is not
# blue-green, and its server is on the compose port.
check "compose service wins when present" \
    "compose abc123 8080" \
    "$(chickadee_resolve_server_target "abc123" "" "" "")"

check "compose service wins even if colours are also up" \
    "compose abc123 8080" \
    "$(chickadee_resolve_server_target "abc123" "8082" "running" "running")"

# nginx names the live colour.
check "nginx upstream names blue" \
    "bluegreen chickadee-server-blue 8081" \
    "$(chickadee_resolve_server_target "" "8081" "running" "exited")"

check "nginx upstream names green" \
    "bluegreen chickadee-server-green 8082" \
    "$(chickadee_resolve_server_target "" "8082" "exited" "running")"

# Mid-swap: both colours up, nginx has already been flipped to green. Reading
# blue here would record a draining container into the manifest.
check "both colours up, nginx decides" \
    "bluegreen chickadee-server-green 8082" \
    "$(chickadee_resolve_server_target "" "8082" "running" "running")"

# A stale upstream file naming a colour that is no longer running must not win
# over the colour that actually is.
check "stale upstream falls through to the only running colour" \
    "bluegreen chickadee-server-green 8082" \
    "$(chickadee_resolve_server_target "" "8081" "exited" "running")"

check "no upstream file, single colour running" \
    "bluegreen chickadee-server-blue 8081" \
    "$(chickadee_resolve_server_target "" "" "running" "exited")"

# The ambiguous case: both up, nothing says which is live. Answering `none`
# means restore.sh reports unknown identity rather than comparing against the
# wrong container and passing its skew gate.
check "both colours up with no upstream is unresolvable" \
    "none" \
    "$(chickadee_resolve_server_target "" "" "running" "running")"

check "an unrecognised upstream port is not a colour" \
    "none" \
    "$(chickadee_resolve_server_target "" "9999" "running" "running")"

check "nothing running at all" \
    "none" \
    "$(chickadee_resolve_server_target "" "" "exited" "")"

# ---------------------------------------------------------------------------
# chickadee_running_server_names — what to STOP
# ---------------------------------------------------------------------------

check "stop list covers the compose service" \
    "abc123" \
    "$(chickadee_running_server_names "abc123" "" "")"

# The reason this is a separate function: a restore must stop BOTH colours,
# including the drained one kept for rollback, or it reloads the database
# underneath a server that can still write to it.
check "stop list covers both colours mid-swap" \
    "chickadee-server-blue chickadee-server-green" \
    "$(chickadee_running_server_names "" "running" "running" | tr '\n' ' ' | sed 's/ $//')"

check "stop list skips a stopped colour" \
    "chickadee-server-green" \
    "$(chickadee_running_server_names "" "exited" "running")"

check "stop list is empty when nothing is up" \
    "" \
    "$(chickadee_running_server_names "" "exited" "exited")"

# ---------------------------------------------------------------------------
# chickadee_legacy_server_to_retire — the compose server left behind by blue-green
# ---------------------------------------------------------------------------

# A later cutover: blue was live, so blue is the rollback target, and the legacy
# container is a second server that nothing routes to.
check "a colour-to-colour cutover retires the legacy server" \
    "abc123" \
    "$(chickadee_legacy_server_to_retire "abc123" "8081")"

check "a cutover from green retires it too" \
    "abc123" \
    "$(chickadee_legacy_server_to_retire "abc123" "8082")"

# The first cutover: traffic leaves :8080, so the legacy server IS the rollback
# target and must keep running.
check "the first cutover keeps the legacy server for rollback" \
    "" \
    "$(chickadee_legacy_server_to_retire "abc123" "8080")"

check "an unknown previous port keeps it" \
    "" \
    "$(chickadee_legacy_server_to_retire "abc123" "")"

check "nothing to retire when no legacy server runs" \
    "" \
    "$(chickadee_legacy_server_to_retire "" "8081")"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
