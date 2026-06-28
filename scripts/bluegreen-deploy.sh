#!/usr/bin/env bash
#
# bluegreen-deploy.sh — zero-downtime (blue-green) swap for the Chickadee server.
#
# PHASE 1 (manual). This is the proven core that later phases automate. It brings
# the new image up as an *idle* "color" container beside the live one, health-
# checks it on its own port, flips the host nginx upstream to it, drains in-flight
# requests, then stops the old color. The live service is NEVER stopped before the
# new one is proven healthy, so a bad build cannot take the site down.
#
# Design notes
# ------------
#   * It does NOT modify docker-compose.yml. The colors run as plain `docker run`
#     containers alongside your existing compose stack (db + runner stay under
#     compose, untouched). Their environment is resolved FROM compose
#     (`docker compose config`), so compose remains the single source of truth
#     for configuration — no env duplication, no drift.
#   * The runner reaches the server over the public URL, so it follows the nginx
#     flip automatically and needs no changes.
#   * "active" = the port the nginx upstream currently points at. On a fresh host
#     that is 8080 (the legacy compose `server`); the first deploy moves traffic
#     onto a color, after which colors alternate (8081 <-> 8082). The legacy
#     compose server is left running as a fallback and is never auto-stopped.
#
# One-time host setup (see docs/zero-downtime-deploy.md) — make nginx route via a
# rewritable upstream instead of a hard-coded proxy_pass:
#   1. This script creates ${NGINX_UPSTREAM_FILE} (pointing at 8080) if missing.
#   2. In your site (/etc/nginx/sites-available/chickadee) change
#        proxy_pass http://127.0.0.1:8080;
#      to
#        proxy_pass http://chickadee_backend;
#   3. sudo nginx -t && sudo nginx -s reload
#
# Usage (run as root, e.g. via sudo):
#   bluegreen-deploy.sh deploy                       # pull :latest, swap to it
#   CHICKADEE_IMAGE=ghcr.io/...:sha-abc deploy        # swap to a specific image
#   bluegreen-deploy.sh status                       # show active/idle + health
#   bluegreen-deploy.sh rollback                     # flip back to the previous color
#   bluegreen-deploy.sh deploy --dry-run             # print actions, change nothing
#
set -euo pipefail

# ----------------------------------------------------------------------------
# Configuration — override any of these via environment if your host differs.
# ----------------------------------------------------------------------------
# Default the compose directory to the repo root (this script lives in scripts/),
# so it works wherever the repo is checked out without hardcoding a home path.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_DIR="${CHICKADEE_COMPOSE_DIR:-$REPO_ROOT}"
COMPOSE_FILE="${CHICKADEE_COMPOSE_FILE:-$COMPOSE_DIR/docker-compose.yml}"
IMAGE="${CHICKADEE_IMAGE:-ghcr.io/jimwallace/chickadee:latest}"

DOCKER_NETWORK="${CHICKADEE_NETWORK:-chickadee_chickadee}"
DATA_VOLUME="${CHICKADEE_DATA_VOLUME:-chickadee_chickadee-data}"

BLUE_NAME="chickadee-server-blue";   BLUE_PORT="${CHICKADEE_BLUE_PORT:-8081}"
GREEN_NAME="chickadee-server-green"; GREEN_PORT="${CHICKADEE_GREEN_PORT:-8082}"
BOOTSTRAP_PORT=8080   # the legacy compose `server`; fallback, never auto-stopped

NGINX_UPSTREAM_FILE="${CHICKADEE_NGINX_UPSTREAM:-/etc/nginx/conf.d/chickadee-active-upstream.conf}"
UPSTREAM_NAME="chickadee_backend"

HEALTH_PATH="/health"
HEALTH_TIMEOUT_SECS="${CHICKADEE_HEALTH_TIMEOUT:-90}"
DRAIN_SECS="${CHICKADEE_DRAIN_SECS:-10}"

STATE_DIR="${CHICKADEE_STATE_DIR:-/var/lib/chickadee-deploy}"

DRY_RUN=0

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
log()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if (( DRY_RUN )); then printf '  [dry-run] %s\n' "$*"; else eval "$@"; fi; }

require() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

color_name_for_port() {
  case "$1" in
    "$BLUE_PORT")  echo "$BLUE_NAME" ;;
    "$GREEN_PORT") echo "$GREEN_NAME" ;;
    *)             echo "" ;;            # bootstrap / unknown -> no managed color
  esac
}

current_upstream_port() {
  [[ -f "$NGINX_UPSTREAM_FILE" ]] || return 0
  grep -oE '127\.0\.0\.1:[0-9]+' "$NGINX_UPSTREAM_FILE" | head -1 | cut -d: -f2
}

write_upstream() {  # $1 = port
  local port="$1"
  run "printf 'upstream %s { server 127.0.0.1:%s; }\n' '$UPSTREAM_NAME' '$port' > '$NGINX_UPSTREAM_FILE'"
}

reload_nginx() {
  if (( DRY_RUN )); then printf '  [dry-run] nginx -t && nginx -s reload\n'; return 0; fi
  nginx -t || return 1
  nginx -s reload
}

# Resolve the server service's environment from compose into a temp env-file.
# Keeps compose as the single source of truth for configuration.
resolve_env_file() {
  local out; out="$(mktemp)"; chmod 600 "$out"
  docker compose --project-directory "$COMPOSE_DIR" -f "$COMPOSE_FILE" config --format json \
    | python3 -c '
import json, sys
svc = json.load(sys.stdin)["services"]["server"]
env = svc.get("environment") or {}
# compose may render environment as a dict or a list of "K=V" strings
items = env.items() if isinstance(env, dict) else (e.split("=", 1) for e in env)
for k, v in items:
    if v is None:
        continue
    sys.stdout.write(f"{k}={v}\n")
' > "$out" || { rm -f "$out"; die "could not resolve server env from compose"; }
  [[ -s "$out" ]] || { rm -f "$out"; die "resolved server env was empty"; }
  echo "$out"
}

wait_healthy() {  # $1 = port
  local port="$1" deadline=$((SECONDS + HEALTH_TIMEOUT_SECS))
  log "Waiting for new container health on 127.0.0.1:${port}${HEALTH_PATH} (timeout ${HEALTH_TIMEOUT_SECS}s)..."
  if (( DRY_RUN )); then printf '  [dry-run] poll until healthy\n'; return 0; fi
  until curl -sf "http://127.0.0.1:${port}${HEALTH_PATH}" >/dev/null 2>&1; do
    (( SECONDS >= deadline )) && return 1
    sleep 2
  done
  return 0
}

ensure_dirs() { run "mkdir -p '$STATE_DIR'"; }

# ----------------------------------------------------------------------------
# Commands
# ----------------------------------------------------------------------------
cmd_status() {
  local active idle
  active="$(current_upstream_port || true)"; active="${active:-<none/8080>}"
  log "nginx upstream file : $NGINX_UPSTREAM_FILE"
  log "active port         : $active"
  for slot in "$BLUE_NAME:$BLUE_PORT" "$GREEN_NAME:$GREEN_PORT"; do
    local name="${slot%%:*}" port="${slot##*:}" state health
    state="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo absent)"
    health="$(curl -sf "http://127.0.0.1:${port}${HEALTH_PATH}" >/dev/null 2>&1 && echo ok || echo down)"
    log "color $name (port $port): container=$state  http=$health"
  done
}

cmd_deploy() {
  require docker; require curl; require python3; require nginx
  ensure_dirs

  # Bootstrap the upstream include if a previous run never created it.
  if [[ ! -f "$NGINX_UPSTREAM_FILE" ]]; then
    warn "Upstream include missing; creating it pointing at the current server (:$BOOTSTRAP_PORT)."
    warn "Remember the one-time site edit: proxy_pass http://${UPSTREAM_NAME}; (see header)."
    write_upstream "$BOOTSTRAP_PORT"
  fi

  local active_port idle_port idle_name
  active_port="$(current_upstream_port || true)"; active_port="${active_port:-$BOOTSTRAP_PORT}"
  if [[ "$active_port" == "$BLUE_PORT" ]]; then
    idle_port="$GREEN_PORT"; idle_name="$GREEN_NAME"
  else
    idle_port="$BLUE_PORT"; idle_name="$BLUE_NAME"
  fi
  log "Active=:$active_port  ->  deploying new image to idle color $idle_name (:$idle_port)"
  log "Image: $IMAGE"

  run "docker pull '$IMAGE'"

  local envfile=""
  if (( ! DRY_RUN )); then envfile="$(resolve_env_file)"; trap '[[ -n "$envfile" ]] && rm -f "$envfile"' EXIT; fi

  # (Re)create the idle color. If anything below fails, the active color is
  # untouched and still serving — that is the whole safety guarantee.
  run "docker rm -f '$idle_name' >/dev/null 2>&1 || true"
  run "docker run -d --name '$idle_name' \
        --restart unless-stopped \
        --network '$DOCKER_NETWORK' --network-alias server \
        -p '127.0.0.1:${idle_port}:8080' \
        -v '${DATA_VOLUME}:/data' \
        ${envfile:+--env-file '$envfile'} \
        '$IMAGE'"

  if ! wait_healthy "$idle_port"; then
    warn "New container failed health check. Aborting — active (:$active_port) is untouched."
    run "docker rm -f '$idle_name' >/dev/null 2>&1 || true"
    die "deploy aborted; no traffic was moved."
  fi
  log "New container is healthy."

  # Flip nginx, with rollback of the include if the config does not validate.
  local backup=""
  if [[ -f "$NGINX_UPSTREAM_FILE" ]] && (( ! DRY_RUN )); then
    backup="$(mktemp)"; cp "$NGINX_UPSTREAM_FILE" "$backup"
  fi
  log "Flipping nginx upstream -> :$idle_port"
  write_upstream "$idle_port"
  if ! reload_nginx; then
    warn "nginx validation/reload failed; restoring previous upstream."
    [[ -n "$backup" ]] && cp "$backup" "$NGINX_UPSTREAM_FILE" && nginx -s reload || true
    run "docker rm -f '$idle_name' >/dev/null 2>&1 || true"
    [[ -n "$backup" ]] && rm -f "$backup"
    die "deploy aborted at nginx flip; active (:$active_port) is untouched."
  fi
  [[ -n "$backup" ]] && rm -f "$backup"

  # Record state for `rollback`.
  run "printf '%s\n' '$idle_port'   > '$STATE_DIR/active'"
  run "printf '%s\n' '$active_port' > '$STATE_DIR/previous'"

  log "Draining old color for ${DRAIN_SECS}s before stopping it..."
  (( DRY_RUN )) || sleep "$DRAIN_SECS"

  # Stop only a *managed color*; never the legacy compose server (fallback).
  local old_name; old_name="$(color_name_for_port "$active_port")"
  if [[ -n "$old_name" ]]; then
    log "Stopping old color $old_name (:$active_port). Kept (not removed) for fast rollback."
    run "docker stop '$old_name' >/dev/null 2>&1 || true"
  else
    log "Previous active was :$active_port (legacy compose server) — left running as fallback."
  fi

  log "Deploy complete. Live on $idle_name (:$idle_port)."
}

cmd_rollback() {
  require docker; require curl; require nginx
  [[ -f "$STATE_DIR/previous" ]] || die "no previous state recorded; cannot rollback automatically."
  local prev; prev="$(cat "$STATE_DIR/previous")"
  local prev_name; prev_name="$(color_name_for_port "$prev")"
  log "Rolling back to :$prev ${prev_name:+($prev_name)}"

  # Make sure the rollback target is actually up.
  if [[ -n "$prev_name" ]]; then
    if [[ "$(docker inspect -f '{{.State.Status}}' "$prev_name" 2>/dev/null || echo absent)" != "running" ]]; then
      run "docker start '$prev_name'"
    fi
    wait_healthy "$prev" || die "rollback target $prev_name is not healthy; aborting."
  else
    wait_healthy "$prev" || die "rollback target :$prev (legacy server) is not healthy; aborting."
  fi

  local now_active; now_active="$(current_upstream_port || true)"
  write_upstream "$prev"
  reload_nginx || die "nginx reload failed during rollback."
  run "printf '%s\n' '$prev'        > '$STATE_DIR/active'"
  run "printf '%s\n' '$now_active'  > '$STATE_DIR/previous'"
  log "Rolled back. Live on :$prev."
}

# ----------------------------------------------------------------------------
# Entry
# ----------------------------------------------------------------------------
SUBCOMMAND="${1:-}"; shift || true
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) die "unknown argument: $arg" ;;
  esac
done

case "$SUBCOMMAND" in
  deploy)   cmd_deploy ;;
  rollback) cmd_rollback ;;
  status)   cmd_status ;;
  *) die "usage: $0 {deploy|rollback|status} [--dry-run]" ;;
esac
