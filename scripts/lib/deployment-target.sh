#!/usr/bin/env bash
# deployment-target.sh — resolve "which server is actually live, and how do I
# talk to it". Sourced by snapshot.sh and restore.sh; not executable on its own.
#
# Two deployment shapes exist and both are supported:
#
#   Compose      docker-compose.yml owns a `server` service, and
#                `docker compose ps -q server` finds it. This is dev, CI, and
#                any self-hosted deployment that has not adopted blue-green.
#
#   Blue-green   bluegreen-deploy.sh starts the server with a plain
#                `docker run` under a colour name (chickadee-server-blue /
#                -green) on 127.0.0.1:8081 / :8082, and flips an nginx upstream
#                between them. There is NO compose `server` container at all.
#
# That second shape is why this file exists. snapshot.sh and restore.sh both
# asked `docker compose exec server env` for the database settings and
# `docker compose ps -q server` for the running build's identity. Under
# blue-green both return nothing, silently:
#
#   * snapshot.sh fell through to sourcing .env, which on a host that sets
#     DATABASE_BACKEND in compose rather than .env resolves to the `sqlite`
#     default — so it refused to run. Production went 82 consecutive nights
#     with no backup and logged the same refusal into a file nobody read.
#
#   * restore.sh wrote empty build_version / image_digest, leaving its
#     version-skew gate reading only the VERSION file — which tracks the git
#     checkout, not the deployed image, and on a blue-green host those diverge
#     routinely because the deployer pulls `:latest` while the clone follows
#     main. Worse, its `docker compose stop server` was a no-op, so a restore
#     would have reloaded the database underneath a server still writing to it.
#
# The resolution logic is kept as pure functions over observations, with thin
# collectors around them, so the decisions can be tested without Docker.
# scripts/deployment-target-tests.sh covers them.

# Blue-green colour names and ports. Same defaults and same override variables
# as bluegreen-deploy.sh, so an operator who moved a port moves it for all
# three scripts at once.
CHICKADEE_BLUE_NAME="chickadee-server-blue"
CHICKADEE_GREEN_NAME="chickadee-server-green"
CHICKADEE_BLUE_PORT="${CHICKADEE_BLUE_PORT:-8081}"
CHICKADEE_GREEN_PORT="${CHICKADEE_GREEN_PORT:-8082}"
CHICKADEE_NGINX_UPSTREAM="${CHICKADEE_NGINX_UPSTREAM:-/etc/nginx/conf.d/chickadee-active-upstream.conf}"

# ---------------------------------------------------------------------------
# Compose file selection
# ---------------------------------------------------------------------------

# Print the `-f` arguments for every compose file that applies.
#
# Compose auto-loads docker-compose.override.yml ONLY when no -f is given. Every
# script here passes -f explicitly (they must, since they run from cron and from
# the deployer with an arbitrary working directory), which silently suppresses
# it. A deployment that moved its host-specific configuration into an override
# file would therefore have had it ignored by the very scripts that resolve the
# server's environment — booting the server on the base file's defaults.
chickadee_compose_file_args() {  # $1 = compose dir, $2 = base file (optional)
    local dir="$1"
    local base="${2:-$dir/docker-compose.yml}"
    printf -- '-f\n%s\n' "$base"
    if [ -f "$dir/docker-compose.override.yml" ]; then
        printf -- '-f\n%s\n' "$dir/docker-compose.override.yml"
    fi
}

# ---------------------------------------------------------------------------
# Pure resolution (no Docker calls — see the tests)
# ---------------------------------------------------------------------------

# Map a blue-green port to its colour name, or print nothing.
chickadee_colour_for_port() {  # $1 = port
    case "$1" in
        "$CHICKADEE_BLUE_PORT")  printf '%s\n' "$CHICKADEE_BLUE_NAME" ;;
        "$CHICKADEE_GREEN_PORT") printf '%s\n' "$CHICKADEE_GREEN_NAME" ;;
        *)                       printf '' ;;
    esac
}

# Decide which single container to READ from (env, image digest, /health).
# Prints three space-separated fields: MODE NAME PORT.
#
#   compose <cid> 8080      a compose-managed server service is running
#   bluegreen <name> <port> a colour is running; nginx names it, or it is the
#                           only one up
#   none                    nothing resolvable
#
# When both colours are running and nginx does not say which is live, this
# deliberately answers `none` rather than guessing. Reading the wrong colour
# would record a draining container's identity into a snapshot manifest, which
# is worse than recording nothing: an empty field is treated as unknown by
# restore.sh, while a wrong one is compared and trusted.
chickadee_resolve_server_target() {  # $1=compose_cid $2=active_port $3=blue_state $4=green_state
    local compose_cid="$1" active_port="$2" blue_state="$3" green_state="$4"

    if [ -n "$compose_cid" ]; then
        printf 'compose %s 8080\n' "$compose_cid"
        return 0
    fi

    local blue_up=0 green_up=0
    [ "$blue_state" = "running" ] && blue_up=1
    [ "$green_state" = "running" ] && green_up=1

    if [ -n "$active_port" ]; then
        local named; named="$(chickadee_colour_for_port "$active_port")"
        if [ "$named" = "$CHICKADEE_BLUE_NAME" ] && [ "$blue_up" -eq 1 ]; then
            printf 'bluegreen %s %s\n' "$CHICKADEE_BLUE_NAME" "$CHICKADEE_BLUE_PORT"
            return 0
        fi
        if [ "$named" = "$CHICKADEE_GREEN_NAME" ] && [ "$green_up" -eq 1 ]; then
            printf 'bluegreen %s %s\n' "$CHICKADEE_GREEN_NAME" "$CHICKADEE_GREEN_PORT"
            return 0
        fi
    fi

    if [ "$blue_up" -eq 1 ] && [ "$green_up" -eq 0 ]; then
        printf 'bluegreen %s %s\n' "$CHICKADEE_BLUE_NAME" "$CHICKADEE_BLUE_PORT"
        return 0
    fi
    if [ "$green_up" -eq 1 ] && [ "$blue_up" -eq 0 ]; then
        printf 'bluegreen %s %s\n' "$CHICKADEE_GREEN_NAME" "$CHICKADEE_GREEN_PORT"
        return 0
    fi

    printf 'none\n'
}

# List EVERY running server container, one per line.
#
# Separate from the resolver above on purpose. Reading wants the one live
# server; stopping wants all of them. During a blue-green swap both colours run,
# and the old one is kept running-then-stopped for fast rollback — so a restore
# that stopped only the container nginx points at could still be reloading the
# database underneath the other one. Ambiguity is a reason to stop more, and a
# reason to read less.
chickadee_running_server_names() {  # $1=compose_cid $2=blue_state $3=green_state
    [ -n "$1" ] && printf '%s\n' "$1"
    [ "$2" = "running" ] && printf '%s\n' "$CHICKADEE_BLUE_NAME"
    [ "$3" = "running" ] && printf '%s\n' "$CHICKADEE_GREEN_NAME"
    return 0
}

# Decide whether a blue-green cutover retires the legacy compose `server`.
# Prints the container to stop, or nothing.
#
# bluegreen-deploy.sh used to leave that container running forever "as a
# fallback". It is a whole server: it runs its own health-alert sweep against
# the same webhook, and the local runner can reach it through the compose
# service name `server`, while nginx sends it no traffic, so no admin page shows
# it. In Sept 2026 production paged "Runners not polling" every 30 minutes while
# the live server saw those runners poll every 30 seconds.
#
# It is still the rollback target on the FIRST cutover, when traffic leaves
# :8080 for a colour, so it is kept then. On every later cutover the previous
# live server is a colour and the legacy container is nobody's rollback target.
chickadee_legacy_server_to_retire() {  # $1=compose_cid $2=port that was live before the cutover
    local compose_cid="$1" previous_port="$2"
    [ -n "$compose_cid" ] || return 0
    [ -n "$(chickadee_colour_for_port "$previous_port")" ] || return 0
    printf '%s\n' "$compose_cid"
}

# ---------------------------------------------------------------------------
# Observation collectors (these do call Docker)
# ---------------------------------------------------------------------------

chickadee_container_state() {  # $1 = container name
    docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null | tr -d '[:space:]'
}

chickadee_active_upstream_port() {
    [ -f "$CHICKADEE_NGINX_UPSTREAM" ] || return 0
    grep -oE '127\.0\.0\.1:[0-9]+' "$CHICKADEE_NGINX_UPSTREAM" 2>/dev/null \
        | head -1 | cut -d: -f2
}

# Resolve the live server by asking Docker, then deciding with the pure
# function above. Prints "MODE NAME PORT".
chickadee_server_target() {  # $1 = compose command string
    local compose="$1"
    local compose_cid
    compose_cid="$($compose ps -q server 2>/dev/null | head -n1 || true)"
    chickadee_resolve_server_target \
        "$compose_cid" \
        "$(chickadee_active_upstream_port || true)" \
        "$(chickadee_container_state "$CHICKADEE_BLUE_NAME")" \
        "$(chickadee_container_state "$CHICKADEE_GREEN_NAME")"
}

chickadee_all_running_servers() {  # $1 = compose command string
    local compose="$1"
    local compose_cid
    compose_cid="$($compose ps -q server 2>/dev/null | head -n1 || true)"
    chickadee_running_server_names \
        "$compose_cid" \
        "$(chickadee_container_state "$CHICKADEE_BLUE_NAME")" \
        "$(chickadee_container_state "$CHICKADEE_GREEN_NAME")"
}
