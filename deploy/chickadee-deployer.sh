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
# The version those failures belong to. A different release starts a new count.
FAILING_VERSION=""
# Epoch before which a failing version is not retried. Retrying every poll put a
# snapshot and a blue-green swap-and-rollback on the host every five minutes: on
# 2026-09-22 an expired certificate caused 19 of them in 90 minutes. The delay
# doubles per consecutive failure, from POLL_INTERVAL_SECS up to this ceiling.
RETRY_AT=0
MAX_RETRY_DELAY_SECS=3600
# A release whose image is not published yet is WAITING, not failing. It costs
# nothing to re-check, so it is re-checked every poll, but a wait this long means
# the build failed or published under another commit, and the state says so.
WAITING_VERSION=""
WAITING_SINCE=0
WAIT_STUCK_AFTER_SECS=7200
# Set by stage_release_image: the digest reference bluegreen-deploy.sh deploys.
STAGED_IMAGE=""
WAIT_REASON=""
# Set by verify_post_deploy when the public URL failed TLS verification while
# the application behind it answered.
CERT_PROBLEM=""
APPROVED_VERSION=""
DEPLOYED_VERSION="0.0.0"
LATEST_SEEN=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_epoch() { date +%s; }
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

# The commit a release tag points at. The image built from that commit is the
# release, and it is published as :sha-<first 7 characters>.
fetch_release_commit() {  # $1 = version tag
  curl -fsS --max-time 30 "https://api.github.com/repos/$REPO/commits/$1" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("sha",""))' 2>/dev/null
}

# Bookkeeping only, so it does not verify the certificate: an expired
# certificate must not make the deployer lose track of what is running.
read_running_version() {
  curl -fsSk --max-time 10 "$PUBLIC_HEALTH_URL" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version",""))' 2>/dev/null
}

# curl exit codes that mean the TLS handshake or certificate check failed, as
# opposed to the server not answering: 35 SSL connect error, 51 and 60 peer
# certificate rejected (60 includes an expired certificate), 58 and 59 local
# certificate or cipher problems, 77 CA bundle unreadable, 80 SSL shutdown, 83
# issuer check, 90 and 91 pinned key and certificate status.
TLS_CURL_EXITS=" 35 51 58 59 60 77 80 83 90 91 "

# Prints one of: ok, tls:<curl error>, down.
#
# TLS terminates at the host nginx, in front of both colors, so a certificate
# failure says nothing about the release behind it. Until 2026-09-22 this probe
# could not tell the two apart, and an expired certificate rolled back every
# healthy release for 90 minutes. A TLS failure is re-probed without
# verification: if the application answers, the release is healthy and the
# certificate is reported as its own problem.
probe_public_health() {
  local err rc
  err="$(curl -fsS --max-time 5 -o /dev/null "$PUBLIC_HEALTH_URL" 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    echo ok
    return
  fi
  case "$TLS_CURL_EXITS" in
    *" $rc "*)
      if curl -fsSk --max-time 5 -o /dev/null "$PUBLIC_HEALTH_URL" >/dev/null 2>&1; then
        printf 'tls:%s\n' "$(printf '%s' "$err" | head -1)"
        return
      fi
      ;;
  esac
  echo down
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
  local deadline fails result
  CERT_PROBLEM=""
  deadline=$(( $(now_epoch) + POST_DEPLOY_VERIFY_SECS ))
  fails=0
  while [ "$(now_epoch)" -lt "$deadline" ]; do
    result="$(probe_public_health)"
    case "$result" in
      ok)
        fails=0
        ;;
      tls:*)
        fails=0
        CERT_PROBLEM="${result#tls:}"
        ;;
      *)
        fails=$(( fails + 1 ))
        [ "$fails" -ge 3 ] && return 1
        ;;
    esac
    sleep 3
  done
  return 0
}

# ---------------------------------------------------------------------------
# Stage the exact image of a release before deploying it.
#
# The daemon used to deploy whatever :latest was. :latest is pushed by every
# build of main, in the order the builds FINISH, and the release is published
# before its own build does. So the first swaps of every release ran the
# previous version, reported success with it running, and repeated each poll:
# v0.5.232 was swapped five times, with a snapshot and a runner restart each
# time, before its image existed. Worse, :latest can move BACKWARDS: the build
# of the commit before a release can finish after the release's build.
#
# So the release image is pulled by its immutable :sha-<commit> tag, and its
# revision label must name the release commit. It is then tagged :latest on the
# host (so the Compose runner uses it too) and deployed
# by digest. The :sha- tag is removed again, because bluegreen-deploy.sh prunes
# only untagged images and a tag per release would fill the disk.
#
# Returns 0 with STAGED_IMAGE set, or 1 with WAIT_REASON set.
# ---------------------------------------------------------------------------
stage_release_image() {  # $1 = version tag
  local ver="$1" sha ref rev digest
  STAGED_IMAGE=""
  sha="$(fetch_release_commit "$ver")"
  if [ -z "$sha" ]; then
    WAIT_REASON="could not resolve the commit of $ver"
    return 1
  fi
  ref="$IMAGE_REPO:sha-${sha:0:7}"
  if ! docker pull -q "$ref" >/dev/null 2>&1; then
    WAIT_REASON="image $ref is not published yet"
    return 1
  fi
  rev="$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$ref" 2>/dev/null)"
  if [ "$rev" != "$sha" ]; then
    WAIT_REASON="image $ref has revision ${rev:-<none>}, expected $sha"
    return 1
  fi
  digest="$(docker image inspect -f '{{index .RepoDigests 0}}' "$ref" 2>/dev/null)"
  if [ -z "$digest" ]; then
    WAIT_REASON="image $ref has no registry digest"
    return 1
  fi
  if ! docker tag "$ref" "$IMAGE_REPO:latest" >/dev/null 2>&1; then
    WAIT_REASON="could not tag $ref as $IMAGE_REPO:latest"
    return 1
  fi
  docker rmi "$ref" >/dev/null 2>&1 || true
  STAGED_IMAGE="$digest"
  return 0
}

# ---------------------------------------------------------------------------
# Failure accounting. Every failed attempt comes here: a refused swap, a
# rollback after the cutover, and a required snapshot that failed. Rollbacks
# used to be left out, so a release that rolled back every time never became
# `stuck`.
# ---------------------------------------------------------------------------
record_failure() {  # $1 = version tag, $2 = what happened (status detail)
  local ver="$1" detail="$2" delay exp
  if [ "$ver" != "$FAILING_VERSION" ]; then
    FAILING_VERSION="$ver"
    CONSECUTIVE_DEPLOY_FAILURES=0
  fi
  CONSECUTIVE_DEPLOY_FAILURES=$(( CONSECUTIVE_DEPLOY_FAILURES + 1 ))
  delay="$POLL_INTERVAL_SECS"
  exp=1
  while [ "$exp" -lt "$CONSECUTIVE_DEPLOY_FAILURES" ] && [ "$delay" -lt "$MAX_RETRY_DELAY_SECS" ]; do
    delay=$(( delay * 2 ))
    exp=$(( exp + 1 ))
  done
  [ "$delay" -gt "$MAX_RETRY_DELAY_SECS" ] && delay="$MAX_RETRY_DELAY_SECS"
  RETRY_AT=$(( $(now_epoch) + delay ))
  if [ "$CONSECUTIVE_DEPLOY_FAILURES" -ge "$STUCK_AFTER_FAILURES" ]; then
    write_status stuck "deploy of $ver has failed $CONSECUTIVE_DEPLOY_FAILURES times in a row; previous version still live; next attempt in $(( delay / 60 )) min: $detail"
    log "deploy of $ver STUCK after $CONSECUTIVE_DEPLOY_FAILURES consecutive failures; next attempt in ${delay}s: $detail"
  else
    write_status error "$detail; next attempt in $(( delay / 60 )) min"
    log "$detail; next attempt in ${delay}s"
  fi
}

clear_failures() {
  FAILING_VERSION=""
  CONSECUTIVE_DEPLOY_FAILURES=0
  RETRY_AT=0
  WAITING_VERSION=""
  WAITING_SINCE=0
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
# share the Job / TestProperties / result schemas). We recreate only the runner
# on the image the swap just deployed (--no-deps leaves db, and any legacy
# Compose server, alone; bluegreen-deploy.sh retires the latter). A job interrupted by the brief restart is re-queued by the
# server's StuckSubmissionReaperMonitor, and the fresh runner reconnects within a
# poll interval.
#
# It does NOT pull. stage_release_image already tagged the verified release
# image :latest on this host, and a pull here would fetch whatever :latest is in
# the registry, which can be an older build (see stage_release_image). Compose
# sees the local :latest changed and recreates the runner on it.
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
  if docker compose --project-directory "$COMPOSE_DIR" "${COMPOSE_FILES[@]}" up -d --no-deps "$RUNNER_SERVICE" >/dev/null 2>&1; then
    append_history "$ver" runner-refresh ok "runner '$RUNNER_SERVICE' recreated on new image"
    log "runner refresh complete."
  else
    append_history "$ver" runner-refresh failed "compose up failed; runner may be stale"
    log "WARN: runner refresh failed; server is live but the runner may be on a stale image."
  fi
}

# Returns 0 when deployed, 1 when the attempt failed (counted by
# record_failure), 2 when the release image is not available yet (waiting).
do_deploy() {  # $1 = version tag
  local ver="$1"
  LATEST_SEEN="$ver"

  if ! stage_release_image "$ver"; then
    if [ "$WAITING_VERSION" != "$ver" ]; then
      WAITING_VERSION="$ver"
      WAITING_SINCE="$(now_epoch)"
      append_history "$ver" image waiting "$WAIT_REASON"
      log "waiting for the image of $ver: $WAIT_REASON"
    fi
    local waited=$(( $(now_epoch) - WAITING_SINCE ))
    if [ "$waited" -ge "$WAIT_STUCK_AFTER_SECS" ]; then
      write_status stuck "no deployable image for $ver after $(( waited / 60 )) min: $WAIT_REASON"
    else
      write_status waiting_for_image "$WAIT_REASON"
    fi
    return 2
  fi
  WAITING_VERSION=""
  WAITING_SINCE=0

  write_status deploying "deploying $ver"
  append_history "$ver" deploy start "$STAGED_IMAGE"
  log "deploying $ver ($STAGED_IMAGE)"

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
        record_failure "$ver" "snapshot failed (required); deploy of $ver aborted: $snap_reason"
        rm -f "$snap_log"
        return 1
      fi
      append_history "$ver" snapshot failed "$snap_reason"
      log "snapshot failed; continuing (SNAPSHOT_REQUIRED=0): $snap_reason"
    fi
    rm -f "$snap_log"
  fi

  local deploy_log; deploy_log="$(mktemp)"
  # `tee` keeps the deploy output in the journal AND captures it, so the history
  # detail can say what actually went wrong. `pipefail` is set at the top of this
  # file, so the `if` still tests the deploy script rather than tee.
  if CHICKADEE_IMAGE="$STAGED_IMAGE" "$DEPLOY_SCRIPT" deploy --yes 2>&1 | tee "$deploy_log"; then
    rm -f "$deploy_log"
    if verify_post_deploy; then
      local running; running="$(read_running_version)"
      DEPLOYED_VERSION="${running:-$(strip_v "$ver")}"
      printf '%s\n' "$DEPLOYED_VERSION" > "$DEPLOYED_VERSION_FILE"
      append_history "$ver" deploy success "running=$DEPLOYED_VERSION"
      refresh_runner "$ver"
      clear_failures
      if [ -n "$CERT_PROBLEM" ]; then
        # The release is live and healthy. The certificate is a host problem
        # (see deploy/README.md "Certificate renewal"), reported on its own.
        append_history "$ver" certificate failed "$CERT_PROBLEM"
        write_status certificate_invalid "deployed $DEPLOYED_VERSION, but the public TLS certificate failed verification: $CERT_PROBLEM"
        log "deploy complete; running $DEPLOYED_VERSION; CERTIFICATE PROBLEM: $CERT_PROBLEM"
      else
        write_status idle "deployed $DEPLOYED_VERSION (release $ver)"
        log "deploy complete; running version now $DEPLOYED_VERSION (target release $ver)"
      fi
      return 0
    fi
    log "post-deploy health degraded — rolling back $ver"
    "$DEPLOY_SCRIPT" rollback --yes || log "rollback command failed"
    append_history "$ver" deploy rolledback "post-deploy health degraded"
    record_failure "$ver" "rolled back $ver (post-deploy health degraded)"
    return 1
  fi

  # bluegreen-deploy.sh health-gates the new color BEFORE flipping nginx, so an
  # aborted swap means traffic never moved — the previous version is still live.
  # What FAILED, though, varies: the swap may have been refused, or the container
  # may never have started at all. Report what the run printed rather than
  # asserting a cause.
  local reason; reason="$(deploy_failure_reason "$deploy_log")"
  rm -f "$deploy_log"
  append_history "$ver" deploy failed "$reason"
  record_failure "$ver" "deploy of $ver aborted; previous version still live: $reason"
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
    run_cycle
    sleep "$POLL_INTERVAL_SECS"
  done
}

# One poll: commands, then at most one deploy attempt.
run_cycle() {
  handle_commands

  if [ "$PAUSED" = "1" ]; then
    write_status paused "auto-deploy paused"
    return
  fi

  local latest
  latest="$(fetch_latest_release)"
  if [ -z "$latest" ]; then
    log "could not fetch latest release; retrying next cycle"
    return
  fi
  LATEST_SEEN="$latest"

  if ! is_newer "$latest" "$DEPLOYED_VERSION"; then
    write_status idle "up to date ($DEPLOYED_VERSION)"
    return
  fi

  if is_gated "$latest" "$DEPLOYED_VERSION" && [ "$APPROVED_VERSION" != "$latest" ]; then
    log "release $latest crosses the $DEPLOY_GATE_LEVEL gate — holding for approval"
    write_status pending_approval "release $latest needs approval ($DEPLOY_GATE_LEVEL bump)"
    append_history "$latest" gate held "awaiting approval"
    return
  fi

  # Back off a version that keeps failing. A newer release, or an operator's
  # approve/deploy command for this one, is attempted at once. The status the
  # last failure wrote stays in place until then.
  if [ "$latest" = "$FAILING_VERSION" ] && [ "$APPROVED_VERSION" != "$latest" ] \
     && [ "$(now_epoch)" -lt "$RETRY_AT" ]; then
    return
  fi

  do_deploy "$latest"
  # An approval is kept while the image is still being built: clearing it would
  # send a gated release back to pending_approval.
  [ "$?" -eq 2 ] || APPROVED_VERSION=""
}

# Run the daemon only when executed. The tests source this file for its
# functions.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main
fi
