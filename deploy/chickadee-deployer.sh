#!/usr/bin/env bash
#
# chickadee-deployer.sh — zero-downtime auto-deploy daemon (Phase 2).
#
# Polls GitHub Releases for a new version and blue-green-deploys it via
# scripts/bluegreen-deploy.sh, fully automatically. MAJOR version bumps are held
# for human approval (SemVer gate); non-major bumps deploy on their own. Each
# deploy is preceded by a snapshot and followed by a short health verification
# that auto-rolls-back if the new release degrades after the cutover.
#
# State / IPC lives in $STATE_DIR (shared with bluegreen-deploy.sh):
#   status.json       — current state, written every cycle (read by the admin MCP surface)
#   history.jsonl     — append-only deploy log
#   deployed_version  — the version currently live (the daemon's source of truth)
#   command.json      — commands FROM the operator/MCP: {"command":"pause|resume|approve|rollback|deploy","version":"vX.Y.Z"}
#
# Runs as root via systemd (needs docker + nginx). See chickadee-deployer.service.
#
# NOTE: deliberately NOT `set -e` — a long-running daemon must survive transient
# failures (a flaky GitHub poll, a momentary network blip) and keep looping.
set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration — override via /etc/chickadee-deployer.env (EnvironmentFile).
# ---------------------------------------------------------------------------
REPO="${CHICKADEE_REPO:-JimWallace/Chickadee}"
IMAGE_REPO="${CHICKADEE_IMAGE_REPO:-ghcr.io/jimwallace/chickadee}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEPLOY_SCRIPT="${CHICKADEE_DEPLOY_SCRIPT:-$REPO_ROOT/scripts/bluegreen-deploy.sh}"
SNAPSHOT_SCRIPT="${CHICKADEE_SNAPSHOT_SCRIPT:-$REPO_ROOT/scripts/snapshot.sh}"

# Compose stack the runner service lives in. bluegreen-deploy.sh only swaps the
# SERVER color containers; the Compose runner is left untouched, so we refresh it
# here after a healthy swap (see refresh_runner). Same names bluegreen-deploy.sh
# uses, so an operator override applies to both scripts.
COMPOSE_DIR="${CHICKADEE_COMPOSE_DIR:-$REPO_ROOT}"
COMPOSE_FILE="${CHICKADEE_COMPOSE_FILE:-$COMPOSE_DIR/docker-compose.yml}"
# shellcheck source=../scripts/lib/deployment-target.sh
. "$REPO_ROOT/scripts/lib/deployment-target.sh"
# See the note in bluegreen-deploy.sh: an explicit -f suppresses
# docker-compose.override.yml, so it is added by hand or the runner refresh
# below recreates the runner from the base file alone.
mapfile -t COMPOSE_FILES < <(chickadee_compose_file_args "$COMPOSE_DIR" "$COMPOSE_FILE")

STATE_DIR="${CHICKADEE_STATE_DIR:-/var/lib/chickadee-deploy}"
PUBLIC_HEALTH_URL="${CHICKADEE_PUBLIC_HEALTH_URL:-https://chickadee.uwaterloo.ca/health}"

POLL_INTERVAL_SECS="${CHICKADEE_POLL_INTERVAL_SECS:-300}"
DEPLOY_GATE_LEVEL="${CHICKADEE_DEPLOY_GATE_LEVEL:-major}"     # major | minor
SNAPSHOT_BEFORE_DEPLOY="${CHICKADEE_SNAPSHOT_BEFORE_DEPLOY:-1}"
SNAPSHOT_REQUIRED="${CHICKADEE_SNAPSHOT_REQUIRED:-0}"
POST_DEPLOY_VERIFY_SECS="${CHICKADEE_POST_DEPLOY_VERIFY_SECS:-30}"
REFRESH_RUNNER="${CHICKADEE_REFRESH_RUNNER:-1}"
RUNNER_SERVICE="${CHICKADEE_RUNNER_SERVICE:-runner}"

STATUS_FILE="$STATE_DIR/status.json"
HISTORY_FILE="$STATE_DIR/history.jsonl"
COMMAND_FILE="$STATE_DIR/command.json"
DEPLOYED_VERSION_FILE="$STATE_DIR/deployed_version"

PAUSED=0

# Consecutive failed deploys of the same version. A deploy that fails once is
# ordinary; one that fails identically for hours is a condition no rule here used
# to name, so the daemon retried ~500 times over two days while every status read
# "error" and nothing escalated. Past this count the state becomes `stuck`, which
# the admin diagnostics surface reports distinctly from a single failure.
CONSECUTIVE_DEPLOY_FAILURES=0
STUCK_AFTER_FAILURES=5
APPROVED_VERSION=""
DEPLOYED_VERSION="0.0.0"
LATEST_SEEN=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '%s [deployer] %s\n' "$(ts)" "$*"; }

strip_v()  { printf '%s' "${1#v}"; }
major_of() { strip_v "$1" | cut -d. -f1; }
minor_of() { strip_v "$1" | cut -d. -f2; }

# True (0) if $1 is a strictly newer semver than $2.
is_newer() {
  local a b top
  a="$(strip_v "$1")"; b="$(strip_v "$2")"
  [ "$a" = "$b" ] && return 1
  top="$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -1)"
  [ "$top" = "$a" ]
}

# True (0) if deploying $1 over current $2 crosses the configured gate.
is_gated() {
  local new="$1" cur="$2"
  if [ "$(major_of "$new")" -gt "$(major_of "$cur")" ]; then
    return 0
  fi
  if [ "$DEPLOY_GATE_LEVEL" = "minor" ] \
     && [ "$(major_of "$new")" -eq "$(major_of "$cur")" ] \
     && [ "$(minor_of "$new")" -gt "$(minor_of "$cur")" ]; then
    return 0
  fi
  return 1
}

fetch_latest_release() {
  curl -fsS --max-time 30 "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tag_name",""))' 2>/dev/null
}

read_running_version() {
  curl -fsS --max-time 10 "$PUBLIC_HEALTH_URL" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version",""))' 2>/dev/null
}

write_status() {  # $1=state $2=detail
  mkdir -p "$STATE_DIR"
  python3 - "$STATUS_FILE" "$1" "$DEPLOYED_VERSION" "$LATEST_SEEN" "$2" "$PAUSED" <<'PY' 2>/dev/null || true
import json, sys, datetime
path, state, deployed, latest, detail, paused = sys.argv[1:7]
json.dump({
    "state": state,
    "deployedVersion": deployed,
    "latestSeen": latest,
    "detail": detail,
    "paused": paused == "1",
    "updatedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}, open(path, "w"), indent=2)
PY
}

append_history() {  # $1=version $2=action $3=result $4=detail
  mkdir -p "$STATE_DIR"
  python3 - "$HISTORY_FILE" "$1" "$2" "$3" "$4" <<'PY' 2>/dev/null || true
import json, sys, datetime
path, version, action, result, detail = sys.argv[1:6]
line = json.dumps({
    "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "version": version, "action": action, "result": result, "detail": detail,
})
open(path, "a").write(line + "\n")
PY
}

# Pulls the most informative line out of a failed deploy run, for the history
# detail. The daemon used to record a fixed "new color unhealthy" string for
# EVERY non-zero exit — including runs where the container never started, so the
# health gate was never reached. That message sent an incident responder after
# the wrong subsystem for a day. Whatever the deploy actually printed is better
# than a guess, so record that.
deploy_failure_reason() {  # $1 = captured output file
  local line
  line="$(grep -aiE 'error|cannot|refused|denied|no such|not found|failed' "$1" 2>/dev/null | tail -1)"
  line="$(printf '%s' "$line" | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g')"
  [ -n "$line" ] || line="deploy script exited non-zero with no recognisable error line"
  printf '%s' "${line:0:400}"
}

json_field() {  # $1=file $2=key
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$1" "$2" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Command handling (operator / MCP -> daemon, via command.json)
# ---------------------------------------------------------------------------
handle_commands() {
  [ -f "$COMMAND_FILE" ] || return 0
  local cmd ver
  cmd="$(json_field "$COMMAND_FILE" command)"
  ver="$(json_field "$COMMAND_FILE" version)"
  rm -f "$COMMAND_FILE"
  case "$cmd" in
    pause)    PAUSED=1; log "paused by command"; append_history "" pause ok "" ;;
    resume)   PAUSED=0; log "resumed by command"; append_history "" resume ok "" ;;
    approve)  APPROVED_VERSION="$ver"; log "approved $ver for the next cycle" ;;
    rollback) log "rollback requested"; "$DEPLOY_SCRIPT" rollback --yes && append_history "" rollback ok "" || append_history "" rollback failed "" ;;
    deploy)   APPROVED_VERSION="$ver"; log "manual deploy requested for $ver" ;;
    "")       ;;
    *)        log "unknown command: $cmd" ;;
  esac
}

# ---------------------------------------------------------------------------
# Deploy a specific version tag, with snapshot + post-deploy verification.
# ---------------------------------------------------------------------------
verify_post_deploy() {
  local deadline fails
  deadline=$(( $(date +%s) + POST_DEPLOY_VERIFY_SECS ))
  fails=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if curl -fsS --max-time 5 "$PUBLIC_HEALTH_URL" >/dev/null 2>&1; then
      fails=0
    else
      fails=$(( fails + 1 ))
      [ "$fails" -ge 3 ] && return 1
    fi
    sleep 3
  done
  return 0
}

# ---------------------------------------------------------------------------
# Refresh the Compose runner onto the just-deployed image.
#
# bluegreen-deploy.sh only swaps the SERVER color containers; by design it leaves
# the Compose `runner` (and `db`) untouched. That is right for the stateful db,
# but it strands the runner on whatever image it was last `compose up`'d with —
# so it keeps grading on a stale build (a lagging runnerVersion on /admin/runners)
# while the server advances release after release.
#
# The runner has no inbound traffic — it polls — so it needs a rolling restart,
# not a blue-green cutover, and it should stay in lockstep with the server (they
# share the Job / TestProperties / result schemas). We pull the same :latest the
# swap just deployed and recreate only the runner (--no-deps leaves the fallback
# server + db alone). A job interrupted by the brief restart is re-queued by the
# server's StuckSubmissionReaperMonitor, and the fresh runner reconnects within a
# poll interval.
#
# Best-effort: the server is already live and serving, so a runner-refresh hiccup
# is logged but never fails or rolls back the deploy.
# ---------------------------------------------------------------------------
refresh_runner() {  # $1 = version tag (history label only)
  local ver="$1"
  [ "$REFRESH_RUNNER" = "1" ] || return 0

  if [ ! -f "$COMPOSE_FILE" ]; then
    log "runner refresh skipped: no compose file at $COMPOSE_FILE"
    append_history "$ver" runner-refresh skipped "no compose file at $COMPOSE_FILE"
    return 0
  fi

  log "refreshing Compose runner '$RUNNER_SERVICE' onto the new image..."
  if docker compose --project-directory "$COMPOSE_DIR" "${COMPOSE_FILES[@]}" pull "$RUNNER_SERVICE" >/dev/null 2>&1 \
     && docker compose --project-directory "$COMPOSE_DIR" "${COMPOSE_FILES[@]}" up -d --no-deps "$RUNNER_SERVICE" >/dev/null 2>&1; then
    append_history "$ver" runner-refresh ok "runner '$RUNNER_SERVICE' recreated on new image"
    log "runner refresh complete."
  else
    append_history "$ver" runner-refresh failed "compose pull/up failed; runner may be stale"
    log "WARN: runner refresh failed; server is live but the runner may be on a stale image."
  fi
}

do_deploy() {  # $1 = version tag
  local ver="$1"
  LATEST_SEEN="$ver"
  write_status deploying "deploying $ver"
  append_history "$ver" deploy start ""
  log "deploying $ver"

  if [ "$SNAPSHOT_BEFORE_DEPLOY" = "1" ] && [ -x "$SNAPSHOT_SCRIPT" ]; then
    log "snapshotting before deploy..."
    # Output was sent to /dev/null here, so a snapshot that failed on every
    # single deploy for months said only "snapshot failed" and never why.
    local snap_log snap_reason
    snap_log="$(mktemp)"
    if ! "$SNAPSHOT_SCRIPT" --label "predeploy-$(strip_v "$ver")" >"$snap_log" 2>&1; then
      snap_reason="$(deploy_failure_reason "$snap_log")"
      if [ "$SNAPSHOT_REQUIRED" = "1" ]; then
        append_history "$ver" deploy abort "snapshot failed (required): $snap_reason"
        write_status error "snapshot failed; deploy of $ver aborted"
        log "snapshot failed and SNAPSHOT_REQUIRED=1 — aborting: $snap_reason"
        rm -f "$snap_log"
        return 1
      fi
      append_history "$ver" snapshot failed "$snap_reason"
      log "snapshot failed; continuing (SNAPSHOT_REQUIRED=0): $snap_reason"
    fi
    rm -f "$snap_log"
  fi

  # We deploy :latest, not :vX.Y.Z. The build only publishes per-release image
  # tags on a git-tag workflow run, but auto-release pushes the tag with the
  # default GITHUB_TOKEN, which (by GitHub's design) does not trigger the build —
  # so :X.Y.Z is never published. :latest IS rebuilt on every release and is the
  # version we just gated on via the Releases API. After the swap we record the
  # ACTUAL running version so the deployed-version bookkeeping stays accurate even
  # if :latest moved between the release check and the pull.
  local deploy_log; deploy_log="$(mktemp)"
  # `tee` keeps the deploy output in the journal AND captures it, so the history
  # detail can say what actually went wrong. `pipefail` is set at the top of this
  # file, so the `if` still tests the deploy script rather than tee.
  if CHICKADEE_IMAGE="$IMAGE_REPO:latest" "$DEPLOY_SCRIPT" deploy --yes 2>&1 | tee "$deploy_log"; then
    if verify_post_deploy; then
      local running; running="$(read_running_version)"
      DEPLOYED_VERSION="${running:-$(strip_v "$ver")}"
      printf '%s\n' "$DEPLOYED_VERSION" > "$DEPLOYED_VERSION_FILE"
      append_history "$ver" deploy success "running=$DEPLOYED_VERSION"
      refresh_runner "$ver"
      write_status idle "deployed $DEPLOYED_VERSION (release $ver)"
      log "deploy complete; running version now $DEPLOYED_VERSION (target release $ver)"
      CONSECUTIVE_DEPLOY_FAILURES=0
      rm -f "$deploy_log"
      return 0
    fi
    log "post-deploy health degraded — rolling back $ver"
    "$DEPLOY_SCRIPT" rollback --yes || log "rollback command failed"
    append_history "$ver" deploy rolledback "post-deploy health degraded"
    write_status error "rolled back $ver (post-deploy health degraded)"
    rm -f "$deploy_log"
    return 1
  fi

  # bluegreen-deploy.sh health-gates the new color BEFORE flipping nginx, so an
  # aborted swap means traffic never moved — the previous version is still live.
  # What FAILED, though, varies: the swap may have been refused, or the container
  # may never have started at all. Report what the run printed rather than
  # asserting a cause.
  local reason; reason="$(deploy_failure_reason "$deploy_log")"
  rm -f "$deploy_log"
  CONSECUTIVE_DEPLOY_FAILURES=$(( CONSECUTIVE_DEPLOY_FAILURES + 1 ))
  append_history "$ver" deploy failed "$reason"
  if [ "$CONSECUTIVE_DEPLOY_FAILURES" -ge "$STUCK_AFTER_FAILURES" ]; then
    write_status stuck "deploy of $ver has failed $CONSECUTIVE_DEPLOY_FAILURES times in a row; previous version still live: $reason"
    log "deploy of $ver STUCK after $CONSECUTIVE_DEPLOY_FAILURES consecutive failures: $reason"
  else
    write_status error "deploy of $ver aborted; previous version still live: $reason"
    log "deploy of $ver aborted; previous version still serving: $reason"
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
main() {
  mkdir -p "$STATE_DIR"

  if [ -f "$DEPLOYED_VERSION_FILE" ]; then
    DEPLOYED_VERSION="$(cat "$DEPLOYED_VERSION_FILE")"
  else
    DEPLOYED_VERSION="$(read_running_version)"
    [ -n "$DEPLOYED_VERSION" ] || DEPLOYED_VERSION="0.0.0"
    printf '%s\n' "$DEPLOYED_VERSION" > "$DEPLOYED_VERSION_FILE"
  fi
  LATEST_SEEN="$DEPLOYED_VERSION"

  log "started: repo=$REPO baseline=$DEPLOYED_VERSION gate=$DEPLOY_GATE_LEVEL interval=${POLL_INTERVAL_SECS}s"
  write_status idle "started; baseline $DEPLOYED_VERSION"

  while true; do
    handle_commands

    if [ "$PAUSED" = "1" ]; then
      write_status paused "auto-deploy paused"
      sleep "$POLL_INTERVAL_SECS"; continue
    fi

    local latest
    latest="$(fetch_latest_release)"
    if [ -z "$latest" ]; then
      log "could not fetch latest release; retrying next cycle"
      sleep "$POLL_INTERVAL_SECS"; continue
    fi
    LATEST_SEEN="$latest"

    if ! is_newer "$latest" "$DEPLOYED_VERSION"; then
      write_status idle "up to date ($DEPLOYED_VERSION)"
      sleep "$POLL_INTERVAL_SECS"; continue
    fi

    if is_gated "$latest" "$DEPLOYED_VERSION" && [ "$APPROVED_VERSION" != "$latest" ]; then
      log "release $latest crosses the $DEPLOY_GATE_LEVEL gate — holding for approval"
      write_status pending_approval "release $latest needs approval ($DEPLOY_GATE_LEVEL bump)"
      append_history "$latest" gate held "awaiting approval"
      sleep "$POLL_INTERVAL_SECS"; continue
    fi

    do_deploy "$latest"
    APPROVED_VERSION=""
    sleep "$POLL_INTERVAL_SECS"
  done
}

main
