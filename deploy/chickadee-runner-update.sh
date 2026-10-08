#!/usr/bin/env bash
#
# chickadee-runner-update.sh — move a runner host's Compose runner to the
# release that the server runs. Run it from cron on each runner host.
#
# The server host's deployer refreshes the runner beside the server. A runner
# on a separate host has no deployer, and its cron job used to run
# `docker compose pull && docker compose up -d`. That pulls :latest, which is
# the newest build of main to FINISH, not the release: it can be a build that
# is not released, and it can move backwards (see stage_release_image in
# chickadee-deployer.sh). So a runner could grade on a build that the server
# never ran.
#
# This script follows the server, not the registry:
#
#   1. It reads the version that the server reports at its /health URL.
#   2. It finds the commit of that release tag.
#   3. When the runner container already runs the image of that commit, it
#      stops. It pulls nothing and restarts nothing.
#   4. Otherwise it pulls the image by its :sha-<commit> tag, checks that the
#      image's revision label is that commit, tags it :latest on this host and
#      recreates only the runner service.
#   5. It waits, and checks that the runner stays up.
#
# Because it follows the server, the runner never runs ahead of the server, and
# after a rollback on the server the runner follows it back.
#
# Usage (all flags are optional):
#
#   chickadee-runner-update.sh [--health-url URL] [--compose-dir DIR]
#                              [--service NAME]
#
# Exit status: 0 when the runner runs the server's release (already, or after
# this run), 1 when it could not be updated or does not stay up. It prints
# nothing when there is nothing to do, so a cron job mails only on a change or
# a failure.
#
# It runs on Linux and on macOS with Docker Desktop. macOS has bash 3.2, no
# flock and no python3 until the developer tools are installed, and its cron
# finds no docker on PATH. So the script uses no mapfile, no flock and no
# python3, and it adds the directories where Docker Desktop and Homebrew put
# docker to PATH.
set -uo pipefail

PATH="$PATH:/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin"

REPO="JimWallace/Chickadee"
IMAGE_REPO="ghcr.io/jimwallace/chickadee"
# The source label that docker/metadata-action puts on every Chickadee image.
IMAGE_SOURCE="https://github.com/JimWallace/Chickadee"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEALTH_URL="https://chickadee.uwaterloo.ca/health"
COMPOSE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVICE="runner"
# The lock directory that main() holds while it runs.
LOCK_DIR=/tmp/chickadee-runner-update.lock
[ -d /run/lock ] && [ -w /run/lock ] && LOCK_DIR=/run/lock/chickadee-runner-update.lock
# How long to wait after `compose up` before asking Docker whether the runner
# is still up. The runner checks its own command at startup (the `--sandbox`
# probe) and exits within a few seconds when the check fails.
SETTLE_SECS=15

ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '%s [runner-update] %s\n' "$(ts)" "$*"; }

# The first string value of key $1 in the JSON on stdin. Both documents read
# here hold the key first at the top level: /health holds "version" once, and
# GitHub's commit object starts with its own "sha", before the nested ones.
json_string() {  # $1 = key
  grep -o "\"$1\" *: *\"[^\"]*\"" | head -n1 | sed 's/.*: *"\(.*\)"/\1/'
}

server_version() {
  curl -fsS --max-time 10 "$HEALTH_URL" 2>/dev/null | json_string version
}

release_commit() {  # $1 = version tag
  curl -fsS --max-time 30 "https://api.github.com/repos/$REPO/commits/$1" 2>/dev/null \
    | json_string sha | grep -E '^[0-9a-f]{40}$'
}

# shellcheck source=../scripts/lib/deployment-target.sh
. "$SCRIPT_DIR/../scripts/lib/deployment-target.sh"

compose() {
  local files=() file
  while IFS= read -r file; do files+=("$file"); done < <(chickadee_compose_file_args "$COMPOSE_DIR")
  docker compose --project-directory "$COMPOSE_DIR" "${files[@]}" "$@"
}

runner_container_id() {
  compose ps -a -q "$SERVICE" 2>/dev/null | head -n1
}

# The commit the runner container's image was built from, or nothing.
runner_revision() {
  local cid image
  cid="$(runner_container_id)"
  [ -n "$cid" ] || return 0
  image="$(docker inspect -f '{{.Image}}' "$cid" 2>/dev/null)"
  [ -n "$image" ] || return 0
  docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$image" 2>/dev/null
}

# "<status> <restart count>", for example "running 0", or "missing -".
runner_state() {
  local cid; cid="$(runner_container_id)"
  if [ -z "$cid" ]; then printf 'missing -'; return 0; fi
  docker inspect -f '{{.State.Status}} {{.RestartCount}}' "$cid" 2>/dev/null || printf 'missing -'
}

update_runner() {
  local version sha ref rev before after cid
  version="$(server_version)"
  if [ -z "$version" ]; then
    log "the server at $HEALTH_URL reported no version; the runner is not changed"
    return 1
  fi
  sha="$(release_commit "v$version")"
  if [ -z "$sha" ]; then
    log "could not find the commit of v$version; the runner is not changed"
    return 1
  fi
  if [ "$(runner_revision)" = "$sha" ]; then
    return 0
  fi

  ref="$IMAGE_REPO:sha-${sha:0:7}"
  if ! docker pull -q "$ref" >/dev/null 2>&1; then
    log "could not pull $ref; the runner is not changed"
    return 1
  fi
  rev="$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$ref" 2>/dev/null)"
  if [ "$rev" != "$sha" ]; then
    log "image $ref has revision ${rev:-<none>}, expected $sha; the runner is not changed"
    docker rmi "$ref" >/dev/null 2>&1 || true
    return 1
  fi
  # The Compose file names :latest. The :sha- tag is removed again, so that one
  # tag per release does not stay on the disk.
  if ! docker tag "$ref" "$IMAGE_REPO:latest" >/dev/null 2>&1; then
    log "could not tag $ref as $IMAGE_REPO:latest; the runner is not changed"
    return 1
  fi
  docker rmi "$ref" >/dev/null 2>&1 || true

  log "recreating '$SERVICE' on v$version ($ref); the runner first finishes its running jobs"
  if ! compose up -d --no-deps "$SERVICE" >/dev/null 2>&1; then
    log "compose up failed; the runner may still run the old image"
    return 1
  fi

  before="$(runner_state)"
  sleep "$SETTLE_SECS"
  after="$(runner_state)"
  if [ "${after%% *}" != "running" ] || [ "${after#* }" != "${before#* }" ]; then
    cid="$(runner_container_id)"
    log "'$SERVICE' does not stay up on v$version ($after). Its last log lines:"
    [ -n "$cid" ] && docker logs --tail 5 "$cid" 2>&1
    return 1
  fi
  # Remove the old image. Plain `prune -f` removes only images with no name,
  # and on Docker's containerd image store a pulled image keeps its
  # `repo@sha256:...` name, so old releases stayed on the disk (29 GB on the
  # server host on 2026-10-07). `-a` removes images that no container uses. The
  # label filter limits it to Chickadee images, because on a shared Mac the
  # owner's other images must stay.
  docker image prune -a -f --filter "label=org.opencontainers.image.source=$IMAGE_SOURCE" >/dev/null 2>&1 || true
  log "'$SERVICE' runs v$version"
  return 0
}

# A drain can last up to the runner's stop_grace_period, longer than the time
# between two cron runs, and two runs must not recreate the runner at once.
# mkdir is the lock, because it is atomic on every file system and macOS has
# no flock. The directory holds the PID of its owner. A lock whose owner is no
# longer alive (the run was killed) is stale, and the next run takes it.
take_lock() {
  local owner
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "$$" > "$LOCK_DIR/pid"
    return 0
  fi
  owner="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
  if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
    return 1
  fi
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR" 2>/dev/null || return 1
  echo "$$" > "$LOCK_DIR/pid"
}

release_lock() {
  rm -rf "$LOCK_DIR"
}

main() {
  # A run that finds the lock taken leaves the work to the one that has it.
  take_lock || return 0
  trap release_lock EXIT
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --health-url)  HEALTH_URL="$2"; shift 2 ;;
      --compose-dir) COMPOSE_DIR="$2"; shift 2 ;;
      --service)     SERVICE="$2"; shift 2 ;;
      *) echo "usage: $0 [--health-url URL] [--compose-dir DIR] [--service NAME]" >&2; return 2 ;;
    esac
  done
  update_runner
}

# Run only when executed. The tests source this file for its functions.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
