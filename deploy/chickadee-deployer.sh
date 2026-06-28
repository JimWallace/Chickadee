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

STATE_DIR="${CHICKADEE_STATE_DIR:-/var/lib/chickadee-deploy}"
PUBLIC_HEALTH_URL="${CHICKADEE_PUBLIC_HEALTH_URL:-https://chickadee.uwaterloo.ca/health}"

POLL_INTERVAL_SECS="${CHICKADEE_POLL_INTERVAL_SECS:-300}"
DEPLOY_GATE_LEVEL="${CHICKADEE_DEPLOY_GATE_LEVEL:-major}"     # major | minor
SNAPSHOT_BEFORE_DEPLOY="${CHICKADEE_SNAPSHOT_BEFORE_DEPLOY:-1}"
SNAPSHOT_REQUIRED="${CHICKADEE_SNAPSHOT_REQUIRED:-0}"
POST_DEPLOY_VERIFY_SECS="${CHICKADEE_POST_DEPLOY_VERIFY_SECS:-30}"

STATUS_FILE="$STATE_DIR/status.json"
HISTORY_FILE="$STATE_DIR/history.jsonl"
COMMAND_FILE="$STATE_DIR/command.json"
DEPLOYED_VERSION_FILE="$STATE_DIR/deployed_version"

PAUSED=0
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

do_deploy() {  # $1 = version tag
  local ver="$1"
  LATEST_SEEN="$ver"
  write_status deploying "deploying $ver"
  append_history "$ver" deploy start ""
  log "deploying $ver"

  if [ "$SNAPSHOT_BEFORE_DEPLOY" = "1" ] && [ -x "$SNAPSHOT_SCRIPT" ]; then
    log "snapshotting before deploy..."
    if ! "$SNAPSHOT_SCRIPT" --label "predeploy-$(strip_v "$ver")" >/dev/null 2>&1; then
      if [ "$SNAPSHOT_REQUIRED" = "1" ]; then
        append_history "$ver" deploy abort "snapshot failed (required)"
        write_status error "snapshot failed; deploy of $ver aborted"
        log "snapshot failed and SNAPSHOT_REQUIRED=1 — aborting"
        return 1
      fi
      log "snapshot failed; continuing (SNAPSHOT_REQUIRED=0)"
    fi
  fi

  if CHICKADEE_IMAGE="$IMAGE_REPO:$ver" "$DEPLOY_SCRIPT" deploy --yes; then
    if verify_post_deploy; then
      printf '%s\n' "$ver" > "$DEPLOYED_VERSION_FILE"
      DEPLOYED_VERSION="$ver"
      append_history "$ver" deploy success ""
      write_status idle "deployed $ver"
      log "deployed $ver successfully"
      return 0
    fi
    log "post-deploy health degraded — rolling back $ver"
    "$DEPLOY_SCRIPT" rollback --yes || log "rollback command failed"
    append_history "$ver" deploy rolledback "post-deploy health degraded"
    write_status error "rolled back $ver (post-deploy health degraded)"
    return 1
  fi

  # bluegreen-deploy.sh health-gates the new color BEFORE flipping nginx, so an
  # aborted swap means traffic never moved — the previous version is still live.
  append_history "$ver" deploy failed "swap aborted (new color unhealthy); previous version still live"
  write_status error "deploy of $ver aborted; previous version still live"
  log "deploy of $ver aborted; previous version still serving"
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
