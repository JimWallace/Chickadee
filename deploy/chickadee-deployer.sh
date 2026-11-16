#!/usr/bin/env bash
#
# chickadee-deployer.sh — zero-downtime auto-deploy daemon (Phase 2).
#
# Polls GitHub Releases for a new version and blue-green-deploys it via
# scripts/bluegreen-deploy.sh. The deploy mode (docs/release-gate.md) decides
# which releases deploy on their own and which wait for an admin's approval:
#   autonomous    — a patch or a minor deploys; a major waits
#   gated-minors  — a patch deploys; a minor or a major waits (the default)
#   manual        — every release waits
# Each deploy is preceded by a snapshot and followed by a short health
# verification that auto-rolls-back if the new release degrades after the
# cutover.
#
# State / IPC lives in $STATE_DIR (shared with bluegreen-deploy.sh):
#   status.json        — current state, written every cycle (read by the app)
#   history.jsonl      — append-only deploy log
#   deployed_version   — the version currently live (the daemon's source of truth)
#   mode               — the deploy mode; absent means gated-minors
#   paused             — present while auto-deploy is paused
#   approved           — the release that was approved, until it deploys
#   pending-notes.json — the release notes of what the held release would ship
#   command.json       — commands FROM the host operator:
#                        {"command":"pause|resume|approve|rollback|deploy|mode","version":"vX.Y.Z","mode":"..."}
#   requests/*.json    — requests FROM the app (the admin page), the one
#                        directory the app may write. Only approve-the-held-
#                        release, mode, pause and resume are accepted; see
#                        handle_requests.
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
# shellcheck source=../scripts/lib/snapshot-retention.sh
. "$REPO_ROOT/scripts/lib/snapshot-retention.sh"
# See the note in bluegreen-deploy.sh: an explicit -f suppresses
# docker-compose.override.yml, so it is added by hand or the runner refresh
# below recreates the runner from the base file alone.
mapfile -t COMPOSE_FILES < <(chickadee_compose_file_args "$COMPOSE_DIR" "$COMPOSE_FILE")

STATE_DIR="${CHICKADEE_STATE_DIR:-/var/lib/chickadee-deploy}"
PUBLIC_HEALTH_URL="${CHICKADEE_PUBLIC_HEALTH_URL:-https://chickadee.uwaterloo.ca/health}"

POLL_INTERVAL_SECS="${CHICKADEE_POLL_INTERVAL_SECS:-300}"
SNAPSHOT_BEFORE_DEPLOY="${CHICKADEE_SNAPSHOT_BEFORE_DEPLOY:-1}"
SNAPSHOT_REQUIRED="${CHICKADEE_SNAPSHOT_REQUIRED:-0}"
POST_DEPLOY_VERIFY_SECS="${CHICKADEE_POST_DEPLOY_VERIFY_SECS:-30}"
REFRESH_RUNNER="${CHICKADEE_REFRESH_RUNNER:-1}"
RUNNER_SERVICE="${CHICKADEE_RUNNER_SERVICE:-runner}"

STATUS_FILE="$STATE_DIR/status.json"
HISTORY_FILE="$STATE_DIR/history.jsonl"
COMMAND_FILE="$STATE_DIR/command.json"
DEPLOYED_VERSION_FILE="$STATE_DIR/deployed_version"
# The deploy mode, set from the admin page (a request) or by the host. It
# replaced CHICKADEE_DEPLOY_GATE_LEVEL (docs/release-gate.md), which is no
# longer read: a file the admin page can change, not an environment variable.
MODE_FILE="$STATE_DIR/mode"
DEFAULT_MODE="gated-minors"
# Pause and approval outlive a restart, including the one after the daemon
# updates its own scripts. Before, a pause lived only in the shell, and an
# approved release was held again after that restart.
PAUSED_FILE="$STATE_DIR/paused"
APPROVED_FILE="$STATE_DIR/approved"
PENDING_NOTES_FILE="$STATE_DIR/pending-notes.json"
REQUESTS_DIR="$STATE_DIR/requests"
# A request file larger than this is refused unread.
MAX_REQUEST_BYTES=4096
# Requests read per poll. The rest wait, so a flood of files cannot flood the
# history.
MAX_REQUESTS_PER_POLL=50

PAUSED=0
# The release this daemon holds for approval, or empty.
HELD_VERSION=""
# The held release whose notes pending-notes.json carries.
NOTES_FOR=""

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
# Free space a deploy needs before it pulls: a release image is about 5 GB on
# disk, and the predeploy snapshot comes on top. On 2026-10-07 the disk filled,
# Postgres stopped and the site went down. A pull onto a nearly full disk can
# be the write that fills it, so below this the daemon first reclaims space,
# and if that is not enough it holds the deploy in state `disk_low`, which the
# server's deployerUnhealthy rule pages on. A constant, not an environment
# variable, by the standing rule.
MIN_FREE_KIB_FOR_DEPLOY=$(( 10 * 1024 * 1024 ))
# The release held for disk space, so the history says so once per release.
DISK_LOW_VERSION=""
DISK_REASON=""
# How long refresh_runner waits after `compose up` before it asks Docker whether
# the runner is still up. The runner checks its own command at startup (the
# `--sandbox` probe) and exits within a few seconds when the check fails.
RUNNER_SETTLE_SECS=15
# Set by stage_release_image: the digest reference bluegreen-deploy.sh deploys,
# and the commit the release names.
STAGED_IMAGE=""
STAGED_COMMIT=""
# The release whose self-update was skipped, so the history says so once.
SELF_UPDATE_SKIPPED_FOR=""
WAIT_REASON=""
# Set by do_deploy: 1 when the attempt waits because the release image is not
# published, which is when a fallback release may go out instead.
IMAGE_NOT_READY=0
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

valid_mode() {
  case "$1" in
    autonomous | gated-minors | manual) return 0 ;;
  esac
  return 1
}

# The deploy mode from $MODE_FILE. An absent or unreadable file, or one that
# names no mode, means the default.
current_mode() {
  local mode=""
  [ -f "$MODE_FILE" ] && mode="$(tr -d '[:space:]' < "$MODE_FILE" 2>/dev/null)"
  if valid_mode "$mode"; then printf '%s' "$mode"; else printf '%s' "$DEFAULT_MODE"; fi
}

set_mode() {  # $1 = a valid mode
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$1" > "$MODE_FILE"
}

set_paused() {  # $1 = 1 or 0
  PAUSED="$1"
  mkdir -p "$STATE_DIR"
  if [ "$1" = "1" ]; then : > "$PAUSED_FILE"; else rm -f "$PAUSED_FILE"; fi
}

set_approved() {  # $1 = version tag, or empty to clear
  APPROVED_VERSION="$1"
  if [ -n "$1" ]; then
    mkdir -p "$STATE_DIR"
    printf '%s\n' "$1" > "$APPROVED_FILE"
  else
    rm -f "$APPROVED_FILE"
  fi
}

# True (0) if deploying $1 over current $2 waits for approval in the current
# mode. A major always waits. In manual every newer release waits; in
# gated-minors a minor waits too; in autonomous only a major waits.
is_gated() {
  local new="$1" cur="$2"
  if [ "$(major_of "$new")" -gt "$(major_of "$cur")" ]; then
    return 0
  fi
  case "$(current_mode)" in
    manual) return 0 ;;
    autonomous) return 1 ;;
  esac
  if [ "$(major_of "$new")" -eq "$(major_of "$cur")" ] \
     && [ "$(minor_of "$new")" -gt "$(minor_of "$cur")" ]; then
    return 0
  fi
  return 1
}

# The kind of bump from $2 to $1, for the status detail.
bump_kind() {
  local new="$1" cur="$2"
  if [ "$(major_of "$new")" -gt "$(major_of "$cur")" ]; then echo major
  elif [ "$(minor_of "$new")" -gt "$(minor_of "$cur")" ]; then echo minor
  else echo patch
  fi
}

fetch_latest_release() {
  curl -fsS --max-time 30 "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tag_name",""))' 2>/dev/null
}

# The release tags (vX.Y.Z only) with the commit each names, one
# "tag<TAB>commit" per line, newest first. One API call for all of them, so the
# fallback below costs one request a poll, not one per release: the API is
# unauthenticated and allows 60 requests an hour.
fetch_release_tags() {
  curl -fsS --max-time 30 "https://api.github.com/repos/$REPO/tags?per_page=100" 2>/dev/null \
    | python3 -c '
import json, re, sys
for t in json.load(sys.stdin):
    name = t.get("name", "")
    sha = (t.get("commit") or {}).get("sha", "")
    if re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", name) and sha:
        print(name + "\t" + sha)
' 2>/dev/null | sort -t "$(printf '\t')" -k1,1Vr
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
  python3 - "$STATUS_FILE" "$1" "$DEPLOYED_VERSION" "$LATEST_SEEN" "$2" "$PAUSED" "$(scripts_revision)" \
    "$(current_mode)" "$HELD_VERSION" "$APPROVED_VERSION" <<'PY' 2>/dev/null || true
import json, os, sys, datetime
path, state, deployed, latest, detail, paused, scripts, mode, held, approved = sys.argv[1:11]
tmp = path + ".tmp"
json.dump({
    "state": state,
    "deployedVersion": deployed,
    "latestSeen": latest,
    "detail": detail,
    "paused": paused == "1",
    "mode": mode,
    "heldVersion": held or None,
    "approvedVersion": approved or None,
    "scriptsRevision": scripts,
    "updatedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}, open(tmp, "w"), indent=2)
os.replace(tmp, path)
PY
}

append_history() {  # $1=version $2=action $3=result $4=detail [$5=user]
  mkdir -p "$STATE_DIR"
  python3 - "$HISTORY_FILE" "$1" "$2" "$3" "$4" "${5:-}" <<'PY' 2>/dev/null || true
import json, sys, datetime
path, version, action, result, detail, user = sys.argv[1:7]
entry = {
    "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "version": version, "action": action, "result": result, "detail": detail,
}
if user:
    entry["user"] = user
open(path, "a").write(json.dumps(entry) + "\n")
PY
}

# Pulls the most informative line out of a failed deploy run, for the history
# detail. The daemon used to record a fixed "new color unhealthy" string for
# EVERY non-zero exit — including runs where the container never started, so the
# health gate was never reached. That message sent an incident responder after
# the wrong subsystem for a day. Whatever the deploy actually printed is better
# than a guess, so record that.
deploy_failure_reason() {  # $1 = captured output file, $2 = text when no line matches (optional)
  local line
  line="$(grep -aiE 'error|cannot|refused|denied|no such|not found|failed' "$1" 2>/dev/null | tail -1)"
  line="$(printf '%s' "$line" | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g')"
  [ -n "$line" ] || line="${2:-deploy script exited non-zero with no recognisable error line}"
  printf '%s' "${line:0:400}"
}

json_field() {  # $1=file $2=key
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$1" "$2" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Command handling (host operator -> daemon, via command.json). Only the host
# can write command.json, so it keeps the commands the app may not send:
# rollback, and approving any version (deploy).
# ---------------------------------------------------------------------------
handle_commands() {
  [ -f "$COMMAND_FILE" ] || return 0
  local cmd ver mode
  cmd="$(json_field "$COMMAND_FILE" command)"
  ver="$(json_field "$COMMAND_FILE" version)"
  mode="$(json_field "$COMMAND_FILE" mode)"
  rm -f "$COMMAND_FILE"
  case "$cmd" in
    pause)    set_paused 1; log "paused by command"; append_history "" pause ok "host command" ;;
    resume)   set_paused 0; log "resumed by command"; append_history "" resume ok "host command" ;;
    approve)  set_approved "$ver"; log "approved $ver for the next cycle"; append_history "$ver" approve ok "host command" ;;
    rollback) log "rollback requested"; "$DEPLOY_SCRIPT" rollback --yes && append_history "" rollback ok "" || append_history "" rollback failed "" ;;
    deploy)   set_approved "$ver"; log "manual deploy requested for $ver"; append_history "$ver" approve ok "host deploy command" ;;
    mode)
      if valid_mode "$mode"; then
        set_mode "$mode"; log "mode set to $mode by command"; append_history "" mode ok "$mode (host command)"
      else
        log "unknown mode in command: $mode"; append_history "" mode refused "unknown mode in host command"
      fi
      ;;
    "")       ;;
    *)        log "unknown command: $cmd" ;;
  esac
}

# ---------------------------------------------------------------------------
# Requests from the app (the admin page -> daemon, via requests/*.json).
#
# The app mounts $STATE_DIR read-only, so it can never move traffic, except
# for this one directory, which it may write (bluegreen-deploy.sh). A request
# is a request, not a command: the daemon validates each one and accepts
# exactly these (docs/release-gate.md, "The admin page asks; the daemon
# decides"):
#   {"request":"approve","version":"vX.Y.Z","user":"..."}  only the held release
#   {"request":"mode","mode":"autonomous|gated-minors|manual","user":"..."}
#   {"request":"pause","user":"..."}, {"request":"resume","user":"..."}
# Everything else is refused: an unknown request, a rollback or a deploy, a
# version that is not the held one, a file over $MAX_REQUEST_BYTES bytes, an
# entry that is not a regular file. Each request, accepted or refused, is one
# line in the history with the username the app wrote into it. So a
# compromised app can deploy sooner a release that CI built and this daemon
# would deploy anyway, change the mode, or pause. It cannot name an image,
# choose an older version, or roll back.
# ---------------------------------------------------------------------------

# Prints one line per request file, oldest first, and removes each file:
#   accept US request US argument US user US file
#   refuse US reason US (empty) US user US file
# US is the ASCII unit separator (0x1f), not a tab: read collapses adjacent
# whitespace separators, so an empty field would shift the rest. Every field
# is cleaned of control characters, the separator included. Only names that end
# in .json are read, so the app writes a .tmp file and renames it.
read_requests() {
  python3 - "$REQUESTS_DIR" "$MAX_REQUEST_BYTES" "$MAX_REQUESTS_PER_POLL" <<'PY' 2>/dev/null
import json, os, re, shutil, stat, sys, time
folder, limit, per_poll = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
stale_after = 3600

def clean(value, size=64):
    return re.sub(r"[\x00-\x1f\x7f]", " ", str(value))[:size].strip()

def read_regular(path):
    """The file's bytes, or a refusal. The app owns this folder and can swap
    an entry between two looks at it, so the file is opened without following
    a link and without blocking on a FIFO, and checked again once open."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return None, "not a regular file"
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            return None, "not a regular file"
        if info.st_size > limit:
            return None, "larger than %d bytes" % limit
        data = os.read(fd, limit + 1)
        if len(data) > limit:
            return None, "larger than %d bytes" % limit
        return data, None
    finally:
        os.close(fd)

def decide(path, info):
    if not stat.S_ISREG(info.st_mode):
        return ("refuse", "not a regular file", ""), ""
    if info.st_size > limit:
        return ("refuse", "larger than %d bytes" % limit, ""), ""
    data, refusal = read_regular(path)
    if refusal:
        return ("refuse", refusal, ""), ""
    try:
        body = json.loads(data.decode("utf-8"))
    except ValueError:
        body = None
    if not isinstance(body, dict):
        return ("refuse", "not a JSON object", ""), ""
    user = clean(body.get("user", ""))
    kind = body.get("request")
    if kind == "approve":
        version = body.get("version")
        if isinstance(version, str) and re.fullmatch(r"v\d+\.\d+\.\d+", version):
            return ("accept", "approve", version), user
        return ("refuse", "approve names no version of the form vX.Y.Z", ""), user
    if kind == "mode":
        if body.get("mode") in ("autonomous", "gated-minors", "manual"):
            return ("accept", "mode", body["mode"]), user
        return ("refuse", "mode names no known mode", ""), user
    if kind in ("pause", "resume"):
        return ("accept", kind, ""), user
    if kind in ("rollback", "deploy"):
        return ("refuse", "%s is a host action, not a request" % kind, ""), user
    return ("refuse", "unknown request %s" % clean(kind, 32), ""), user

def remove(path, info):
    try:
        if stat.S_ISDIR(info.st_mode):
            shutil.rmtree(path)
        else:
            os.unlink(path)
    except OSError:
        pass

try:
    names = os.listdir(folder)
except OSError:
    sys.exit(0)
now = time.time()
entries = []
for name in names:
    path = os.path.join(folder, name)
    try:
        info = os.lstat(path)
    except OSError:
        continue
    if name.endswith(".json"):
        entries.append((info.st_mtime, name, path, info))
    elif now - info.st_mtime > stale_after:
        # A .tmp the app never renamed, or anything else left behind.
        remove(path, info)
entries.sort(key=lambda e: (e[0], e[1]))
for _, name, path, info in entries[:per_poll]:
    verdict, user = decide(path, info)
    remove(path, info)
    print("\x1f".join([verdict[0], verdict[1], verdict[2], user, clean(name, 128)]))
if len(entries) > per_poll:
    # The rest wait for the next poll, so a flood cannot fill the history.
    print("\x1f".join(["refuse", "%d more requests wait for the next poll" % (len(entries) - per_poll), "", "", "-"]))
PY
}

handle_requests() {
  [ -d "$REQUESTS_DIR" ] || return 0
  local status what arg user file by
  while IFS=$'\x1f' read -r status what arg user file; do
    [ -n "$status" ] || continue
    by="${user:-unknown}"
    if [ "$status" != "accept" ]; then
      log "refused request $file from $by: $what"
      append_history "" request refused "$what ($file)" "$by"
      continue
    fi
    case "$what" in
      approve)
        if [ -n "$HELD_VERSION" ] && [ "$arg" = "$HELD_VERSION" ]; then
          set_approved "$arg"
          log "approved $arg by $by"
          append_history "$arg" approve accepted "admin page" "$by"
        else
          log "refused approval of $arg from $by: held is ${HELD_VERSION:-nothing}"
          append_history "$arg" approve refused "not the held release (held: ${HELD_VERSION:-nothing})" "$by"
        fi
        ;;
      mode)
        set_mode "$arg"
        log "mode set to $arg by $by"
        append_history "" mode accepted "$arg" "$by"
        ;;
      pause)
        set_paused 1
        log "paused by $by"
        append_history "" pause accepted "admin page" "$by"
        ;;
      resume)
        set_paused 0
        log "resumed by $by"
        append_history "" resume accepted "admin page" "$by"
        ;;
    esac
  done < <(read_requests)
}

# ---------------------------------------------------------------------------
# The held release's notes, for the admin page: every GitHub release after the
# deployed version up to the held one, and the merged pull requests labelled
# minor-release among the commits between them. The app shows this file and
# never calls GitHub itself. Written once per held release, and again on the
# next poll while a fetch fails. GitHub's compare lists at most 250 commits,
# so a hold longer than that can miss a contract flag; the release notes are
# complete either way.
# ---------------------------------------------------------------------------
write_pending_notes() {  # $1 = held version tag
  local held="$1" releases compare minor
  releases="$(mktemp)"; compare="$(mktemp)"; minor="$(mktemp)"
  local fetched=1
  curl -fsS --max-time 30 "https://api.github.com/repos/$REPO/releases?per_page=100" > "$releases" 2>/dev/null || fetched=0
  curl -fsS --max-time 30 "https://api.github.com/repos/$REPO/compare/v$(strip_v "$DEPLOYED_VERSION")...$held" > "$compare" 2>/dev/null || fetched=0
  curl -fsS --max-time 30 "https://api.github.com/search/issues?q=repo:$REPO+is:pr+is:merged+label:minor-release&per_page=100" > "$minor" 2>/dev/null || fetched=0
  mkdir -p "$STATE_DIR"
  python3 - "$PENDING_NOTES_FILE" "$DEPLOYED_VERSION" "$held" "$releases" "$compare" "$minor" "$fetched" <<'PY' 2>/dev/null || true
import datetime, json, os, re, sys
path, deployed, held, releases_file, compare_file, minor_file, complete = sys.argv[1:8]

def load(name):
    try:
        with open(name) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None

def key(tag):
    try:
        return tuple(int(part) for part in str(tag).lstrip("v").split("."))
    except ValueError:
        return None

low, high = key(deployed), key(held)
releases = []
listed = load(releases_file)
for release in listed if isinstance(listed, list) else []:
    tag = release.get("tag_name") or ""
    version = key(tag)
    if None in (version, low, high) or not (low < version <= high):
        continue
    releases.append({
        "tag": tag,
        "name": release.get("name") or tag,
        "publishedAt": release.get("published_at"),
        "url": release.get("html_url"),
        "body": (release.get("body") or "")[:20000],
    })
releases.sort(key=lambda r: key(r["tag"]), reverse=True)

# The pull requests the commits between the two versions came from: a squash
# merge ends its subject with "(#N)", a merge commit starts "Merge pull request #N".
numbers = set()
compare = load(compare_file)
for commit in (compare or {}).get("commits") or []:
    lines = ((commit.get("commit") or {}).get("message") or "").splitlines()
    subject = lines[0] if lines else ""
    for found in re.findall(r"\(#(\d+)\)\s*$|^Merge pull request #(\d+)", subject):
        numbers.update(int(n) for n in found if n)
contract = []
search = load(minor_file)
for item in (search or {}).get("items") or []:
    if item.get("number") in numbers:
        contract.append({"number": item["number"], "title": item.get("title") or "", "url": item.get("html_url")})
contract.sort(key=lambda p: p["number"])

tmp = path + ".tmp"
json.dump({
    "deployedVersion": deployed,
    "heldVersion": held,
    "releases": releases,
    "minorReleasePullRequests": contract,
    "complete": complete == "1",
    "writtenAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}, open(tmp, "w"), indent=2)
os.replace(tmp, path)
PY
  rm -f "$releases" "$compare" "$minor"
  # A failed fetch (a rate limit, a timeout) is tried again on the next poll,
  # so the admin page does not show partial notes for the whole hold.
  if [ "$fetched" = "1" ]; then NOTES_FOR="$held"; else NOTES_FOR=""; fi
}

# Nothing is held: forget the held release and its notes.
clear_held() {
  HELD_VERSION=""
  NOTES_FOR=""
  rm -f "$PENDING_NOTES_FILE"
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
# Keep the daemon's own scripts at the release it deploys.
#
# The daemon runs from a git clone on the host ($REPO_ROOT), and for months
# nothing updated that clone: fixes to this script reached production only when
# someone remembered `git pull`. On 2026-10-05 the host still ran the version
# from before image staging, and it recorded three "successful" deploys of
# v0.5.464 that ran 0.5.463.
#
# So, once the release image is staged, the clone is brought to the release's
# own commit (a detached checkout of the tag, which must name the same commit
# as the image) and the daemon restarts on the new scripts. git runs as the
# clone's owner, so no root-owned file lands in it. A clone with local changes
# is left alone, and the history says why. A paused daemon deploys nothing, so
# it updates nothing.
# ---------------------------------------------------------------------------
repo_git() {
  local owner home
  owner="$(stat -c %U "$REPO_ROOT" 2>/dev/null)"
  if [ "$(id -u)" = 0 ] && [ -n "$owner" ] && [ "$owner" != root ]; then
    home="$(getent passwd "$owner" | cut -d: -f6)"
    runuser -u "$owner" -- env HOME="${home:-/}" git -C "$REPO_ROOT" "$@"
  else
    git -C "$REPO_ROOT" "$@"
  fi
}

scripts_revision() {
  repo_git rev-parse --short=12 HEAD 2>/dev/null || true
}

restart_self() {
  log "restarting on the updated scripts"
  exec "$SCRIPT_DIR/chickadee-deployer.sh"
}

# Returns 0 when it checked out the release's scripts (the caller restarts),
# 1 when the scripts stay as they are.
update_own_scripts() {  # $1 = version tag, $2 = the release commit
  local ver="$1" sha="$2" current tagged
  [ -n "$sha" ] || return 1
  current="$(repo_git rev-parse HEAD 2>/dev/null)"
  [ "$current" = "$sha" ] && return 1
  if [ -n "$(repo_git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    if [ "$SELF_UPDATE_SKIPPED_FOR" != "$ver" ]; then
      SELF_UPDATE_SKIPPED_FOR="$ver"
      append_history "$ver" deployer-update skipped "the clone at $REPO_ROOT has local changes; its scripts stay at ${current:0:12}"
      log "not updating the deployer scripts: the clone at $REPO_ROOT has local changes"
    fi
    return 1
  fi
  if ! repo_git fetch --quiet origin "+refs/tags/$ver:refs/tags/$ver" >/dev/null 2>&1; then
    append_history "$ver" deployer-update failed "could not fetch tag $ver"
    return 1
  fi
  tagged="$(repo_git rev-parse "$ver^{commit}" 2>/dev/null)"
  if [ "$tagged" != "$sha" ]; then
    append_history "$ver" deployer-update failed "tag $ver names ${tagged:-nothing}, the release names $sha"
    return 1
  fi
  if ! repo_git checkout --quiet --detach "$sha" >/dev/null 2>&1; then
    append_history "$ver" deployer-update failed "git checkout of $sha failed"
    return 1
  fi
  append_history "$ver" deployer-update ok "${current:0:12}..${sha:0:12}"
  return 0
}

# ---------------------------------------------------------------------------
# Verify that a release image was built by this repository's own pipeline
# (#3069).
#
# docker-build.yml signs every image it pushes: a Sigstore build-provenance
# attestation, stored beside the image in GHCR, that names the workflow, the
# ref and the commit that built the digest. The revision label checked in
# stage_release_image is written by whoever builds the image, so anyone who
# can push to the registry can forge it. The signature cannot be forged
# without GitHub's OIDC token for this repository's workflow.
#
# So the image digest must carry a provenance attestation signed by
# docker-build.yml at refs/tags/<the release tag>. A main-branch build, a
# build from any other workflow or repository, or an unsigned image is
# refused, and the release waits (state waiting_for_image) with the reason.
#
# cosign does the check. It needs no GitHub token. It is installed once into
# the state directory from its GitHub release, with the SHA-256 pinned here,
# not read from the release, so a replaced asset is refused. To upgrade,
# change the version and both hashes (the cosign-linux-* lines of the
# release's cosign_checksums.txt). Sigstore's trust root is cached under the
# state directory too: the systemd sandbox keeps /root read-only.
# ---------------------------------------------------------------------------
COSIGN_VERSION="3.1.4"
COSIGN_SHA256_AMD64="424e2c97d0b45fd7a6b608a87f090f35633f4c23ece5f092d48bba11aaf4bbfa"
COSIGN_SHA256_ARM64="ade83b7aac62e131cacfe96d958948b2150cc9efec46a570a2649b8e27dedad2"
COSIGN=""
SIGNER_WORKFLOW="https://github.com/$REPO/.github/workflows/docker-build.yml"
OIDC_ISSUER="https://token.actions.githubusercontent.com"

# Sets COSIGN to a verified binary. Returns 1 with WAIT_REASON set.
ensure_cosign() {
  local arch want dir bin tmp
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64; want="$COSIGN_SHA256_AMD64" ;;
    aarch64|arm64) arch=arm64; want="$COSIGN_SHA256_ARM64" ;;
    *) WAIT_REASON="no pinned cosign for architecture $(uname -m)"; return 1 ;;
  esac
  dir="$STATE_DIR/bin"
  bin="$dir/cosign-$COSIGN_VERSION-$arch"
  if [ -x "$bin" ] && [ "$(sha256sum "$bin" | cut -d' ' -f1)" = "$want" ]; then
    COSIGN="$bin"
    return 0
  fi
  mkdir -p "$dir"
  tmp="$(mktemp "$dir/cosign.XXXXXX")"
  if ! curl -fsSL --max-time 120 -o "$tmp" \
      "https://github.com/sigstore/cosign/releases/download/v$COSIGN_VERSION/cosign-linux-$arch"; then
    rm -f "$tmp"
    WAIT_REASON="could not download cosign $COSIGN_VERSION to verify the image signature"
    return 1
  fi
  if [ "$(sha256sum "$tmp" | cut -d' ' -f1)" != "$want" ]; then
    rm -f "$tmp"
    WAIT_REASON="the cosign $COSIGN_VERSION download does not match its pinned SHA-256"
    return 1
  fi
  chmod 755 "$tmp" && mv "$tmp" "$bin"
  COSIGN="$bin"
  return 0
}

# $1 = the image digest reference, $2 = the release tag.
# Returns 0 when docker-build.yml at refs/tags/<tag> signed a provenance
# attestation for that digest. Returns 1 with WAIT_REASON set.
verify_release_image() {
  local ref="$1" ver="$2" out
  ensure_cosign || return 1
  mkdir -p "$STATE_DIR/sigstore"
  if out="$(TUF_ROOT="$STATE_DIR/sigstore" "$COSIGN" verify-attestation \
      --type slsaprovenance1 \
      --certificate-oidc-issuer "$OIDC_ISSUER" \
      --certificate-identity "$SIGNER_WORKFLOW@refs/tags/$ver" \
      "$ref" 2>&1 >/dev/null)"; then
    return 0
  fi
  WAIT_REASON="image $ref has no provenance signed by docker-build.yml at $ver: $(printf '%s' "$out" | tail -n 1 | cut -c1-200)"
  return 1
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
  STAGED_COMMIT=""
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
  # The signature is checked on the digest, which is what gets deployed, and
  # before the image gets the :latest tag that the Compose runner uses.
  if ! verify_release_image "$digest" "$ver"; then
    docker rmi "$ref" >/dev/null 2>&1 || true
    return 1
  fi
  if ! docker tag "$ref" "$IMAGE_REPO:latest" >/dev/null 2>&1; then
    WAIT_REASON="could not tag $ref as $IMAGE_REPO:latest"
    return 1
  fi
  docker rmi "$ref" >/dev/null 2>&1 || true
  STAGED_IMAGE="$digest"
  STAGED_COMMIT="$sha"
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
  if ! docker compose --project-directory "$COMPOSE_DIR" "${COMPOSE_FILES[@]}" up -d --no-deps "$RUNNER_SERVICE" >/dev/null 2>&1; then
    append_history "$ver" runner-refresh failed "compose up failed; runner may be stale"
    log "WARN: runner refresh failed; server is live but the runner may be on a stale image."
    return 0
  fi

  # `compose up` returns when the container starts, not when the runner works.
  # A runner that cannot keep a promise its command makes (`--sandbox` on a
  # host that refuses user namespaces) exits at startup, and Docker restarts it
  # in a loop. Before this check, that loop was recorded here as "ok".
  local before after reason
  before="$(runner_container_state)"
  sleep "$RUNNER_SETTLE_SECS"
  after="$(runner_container_state)"
  if [ "${after%% *}" != "running" ] || [ "${after#* }" != "${before#* }" ]; then
    reason="$(runner_exit_reason)"
    append_history "$ver" runner-refresh failed "runner '$RUNNER_SERVICE' does not stay up: $reason"
    log "WARN: runner '$RUNNER_SERVICE' does not stay up; server is live but nothing grades on this host: $reason"
    return 0
  fi
  append_history "$ver" runner-refresh ok "runner '$RUNNER_SERVICE' recreated on new image"
  # bluegreen-deploy.sh prunes before its pull, while the runner still uses the
  # previous image. Now the runner has moved, so that image is free. `-a`,
  # because an image pulled by digest keeps a name and plain `-f` skips it; an
  # image that a container uses is never removed.
  docker image prune -a -f >/dev/null 2>&1 || true
  log "runner refresh complete."
}

# The Compose runner's container ID, or nothing when it has no container.
runner_container_id() {
  docker compose --project-directory "$COMPOSE_DIR" "${COMPOSE_FILES[@]}" ps -a -q "$RUNNER_SERVICE" 2>/dev/null | head -n1
}

# "<status> <restart count>" for the Compose runner, for example "running 0".
# Prints "missing -" when it has no container.
runner_container_state() {
  local cid; cid="$(runner_container_id)"
  if [ -z "$cid" ]; then printf 'missing -'; return 0; fi
  docker inspect -f '{{.State.Status}} {{.RestartCount}}' "$cid" 2>/dev/null || printf 'missing -'
}

# The last error line the Compose runner wrote, for the history detail.
runner_exit_reason() {
  local cid out reason
  cid="$(runner_container_id)"
  [ -n "$cid" ] || { printf 'the runner has no container'; return 0; }
  out="$(mktemp)"
  docker logs --tail 20 "$cid" >"$out" 2>&1
  reason="$(deploy_failure_reason "$out" "the runner wrote no recognisable error line")"
  rm -f "$out"
  printf '%s' "$reason"
}

# ---------------------------------------------------------------------------
# Free space before a deploy.
#
# Two file systems take a deploy's writes: Docker's data root (the image) and
# this clone (backups/, the snapshot). On the production host they are the same
# disk, and elsewhere the smaller of the two decides. An unknown answer does not
# block a deploy: a host that cannot report its disk is no worse off than
# before this check.
# ---------------------------------------------------------------------------
free_kib_at() {  # $1 = path
  df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $4}'
}

deploy_free_kib() {
  local docker_root a b
  docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)"
  a="$(free_kib_at "${docker_root:-/}")"
  b="$(free_kib_at "$REPO_ROOT")"
  if [ -z "$a" ]; then printf '%s' "$b"; return 0; fi
  if [ -z "$b" ] || [ "$a" -lt "$b" ]; then printf '%s' "$a"; else printf '%s' "$b"; fi
}

# Returns 0 when there is room for a deploy (after reclaiming space if needed),
# 1 with DISK_REASON set when there is not.
ensure_disk_for_deploy() {
  local free
  free="$(deploy_free_kib)"
  [ -n "$free" ] || return 0
  [ "$free" -ge "$MIN_FREE_KIB_FOR_DEPLOY" ] && return 0
  log "only $(( free / 1024 / 1024 )) GiB free before a deploy; reclaiming images and old snapshots"
  # Both are safe at any time: an image that a container uses is never removed,
  # and the snapshot rule keeps the newest predeploy snapshots.
  docker image prune -a -f >/dev/null 2>&1 || true
  prune_snapshots "$REPO_ROOT/backups" "$SNAPSHOT_KEEP_PREDEPLOY" "$SNAPSHOT_RETENTION_DAYS" >/dev/null 2>&1 || true
  free="$(deploy_free_kib)"
  [ -n "$free" ] || return 0
  [ "$free" -ge "$MIN_FREE_KIB_FOR_DEPLOY" ] && return 0
  DISK_REASON="only $(( free / 1024 / 1024 )) GiB free after removing unused images and old snapshots; a deploy needs $(( MIN_FREE_KIB_FOR_DEPLOY / 1024 / 1024 )) GiB. Free space on the host."
  return 1
}

# Returns 0 when deployed, 1 when the attempt failed (counted by
# record_failure), 2 when the release image is not available yet (waiting).
# A deploy is also held (2) while the host is too short of disk space to pull.
do_deploy() {  # $1 = version tag
  local ver="$1"
  IMAGE_NOT_READY=0
  # A fallback deploy is older than the newest release, which stays the one
  # the status reports as seen.
  if [ -z "$LATEST_SEEN" ] || is_newer "$ver" "$LATEST_SEEN"; then
    LATEST_SEEN="$ver"
  fi

  if ! ensure_disk_for_deploy; then
    if [ "$DISK_LOW_VERSION" != "$ver" ]; then
      DISK_LOW_VERSION="$ver"
      append_history "$ver" disk low "$DISK_REASON"
      log "holding $ver: $DISK_REASON"
    fi
    write_status disk_low "$DISK_REASON"
    return 2
  fi
  DISK_LOW_VERSION=""

  if ! stage_release_image "$ver"; then
    # Only an image that is not published yet lets an older release go out. An
    # image that is published but refused (another revision, no digest) holds
    # the deploy as before.
    case "$WAIT_REASON" in
      *"is not published yet") IMAGE_NOT_READY=1 ;;
    esac
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

  if update_own_scripts "$ver" "$STAGED_COMMIT"; then
    restart_self
    return 2
  fi

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
      # Healthy is not enough: the server must report the version this release
      # names. Until 2026-10-05 a success was recorded with whatever answered,
      # and three "successful" deploys of v0.5.464 ran 0.5.463.
      if [ "$running" != "$(strip_v "$ver")" ]; then
        log "post-deploy version check failed: running ${running:-<unknown>}, expected $(strip_v "$ver") — rolling back $ver"
        "$DEPLOY_SCRIPT" rollback --yes || log "rollback command failed"
        append_history "$ver" deploy rolledback "running ${running:-<unknown>}, expected $(strip_v "$ver")"
        record_failure "$ver" "rolled back $ver: the server reported version ${running:-<unknown>}, expected $(strip_v "$ver")"
        return 1
      fi
      DEPLOYED_VERSION="$running"
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
  load_state

  log "started: repo=$REPO baseline=$DEPLOYED_VERSION mode=$(current_mode) paused=$PAUSED interval=${POLL_INTERVAL_SECS}s"
  write_status idle "started; baseline $DEPLOYED_VERSION"

  while true; do
    run_cycle
    sleep "$POLL_INTERVAL_SECS"
  done
}

# What the files remember across a restart: pause, the approval, and the
# release held for approval (from the last status, so an approval sent just
# before a restart still finds it).
load_state() {
  if [ -f "$PAUSED_FILE" ]; then PAUSED=1; else PAUSED=0; fi
  APPROVED_VERSION=""
  [ -f "$APPROVED_FILE" ] && APPROVED_VERSION="$(tr -d '[:space:]' < "$APPROVED_FILE" 2>/dev/null)"
  HELD_VERSION=""
  [ -f "$STATUS_FILE" ] && HELD_VERSION="$(json_field "$STATUS_FILE" heldVersion)"
  [ "$HELD_VERSION" = "None" ] && HELD_VERSION=""
  NOTES_FOR=""
  if [ -f "$PENDING_NOTES_FILE" ] && [ "$(json_field "$PENDING_NOTES_FILE" complete)" = "True" ]; then
    NOTES_FOR="$(json_field "$PENDING_NOTES_FILE" heldVersion)"
  fi
  return 0
}

# One poll: host commands, app requests, then at most one deploy attempt.
run_cycle() {
  handle_commands
  handle_requests

  if [ "$PAUSED" = "1" ]; then
    if [ -n "$HELD_VERSION" ]; then
      write_status paused "auto-deploy paused; $HELD_VERSION waits for approval"
    else
      write_status paused "auto-deploy paused"
    fi
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
    clear_held
    [ -z "$APPROVED_VERSION" ] || set_approved ""
    write_status idle "up to date ($DEPLOYED_VERSION)"
    return
  fi

  if is_gated "$latest" "$DEPLOYED_VERSION" && [ "$APPROVED_VERSION" != "$latest" ]; then
    local kind mode
    kind="$(bump_kind "$latest" "$DEPLOYED_VERSION")"
    mode="$(current_mode)"
    # The history says so once per held release, not once per poll.
    if [ "$HELD_VERSION" != "$latest" ]; then
      HELD_VERSION="$latest"
      log "release $latest ($kind) waits for approval in mode $mode"
      append_history "$latest" gate held "$kind release; awaiting approval (mode $mode)"
    fi
    if [ "$NOTES_FOR" != "$latest" ] || [ ! -f "$PENDING_NOTES_FILE" ]; then
      write_pending_notes "$latest"
    fi
    write_status pending_approval "release $latest needs approval ($kind release, mode $mode)"
    return
  fi
  clear_held

  # Back off a version that keeps failing. A newer release, or an operator's
  # approve/deploy command for this one, is attempted at once. The status the
  # last failure wrote stays in place until then.
  if [ "$latest" = "$FAILING_VERSION" ] && [ "$APPROVED_VERSION" != "$latest" ] \
     && [ "$(now_epoch)" -lt "$RETRY_AT" ]; then
    return
  fi

  do_deploy "$latest"
  local rc=$?
  # An approval is kept while the image is still being built: clearing it would
  # send a gated release back to pending_approval.
  [ "$rc" -eq 2 ] || set_approved ""

  if [ "$rc" -eq 2 ] && [ "$IMAGE_NOT_READY" = "1" ]; then
    deploy_newest_published "$latest"
  fi
}

# ---------------------------------------------------------------------------
# Deploy the newest release that has an image while the newest release waits.
#
# The daemon used to target only the newest release. Each merge to main makes a
# release, and its image takes about 30 minutes to build, so on a day of quick
# merges the target moved before its image existed and production waited for
# hours: on 2026-11-16 it stayed on 0.5.964 from 19:57 to after 22:32 UTC while
# v0.5.965 to v0.5.969 were built. A tag build that failed held it the same way.
#
# So while the newest release waits for its image, the daemon deploys the
# newest older release that is newer than production, has a published image,
# is not held at the gate and is not backed off after a failure. The newest
# release keeps its own wait clock, so a build that never publishes still
# becomes `stuck`.
# ---------------------------------------------------------------------------
MAX_FALLBACK_CANDIDATES=5
# Fallback releases whose image was published but failed to stage, so each is
# tried once while the same newest release waits, not on every poll.
REFUSED_FALLBACKS=""
REFUSED_FALLBACKS_FOR=""

pick_fallback_release() {  # $1 = the newest release; prints the tag
  local latest="$1" tag sha checked=0
  while IFS="$(printf '\t')" read -r tag sha; do
    [ -n "$tag" ] && [ -n "$sha" ] || continue
    is_newer "$latest" "$tag" || continue
    is_newer "$tag" "$DEPLOYED_VERSION" || continue
    if is_gated "$tag" "$DEPLOYED_VERSION" && [ "$APPROVED_VERSION" != "$tag" ]; then
      continue
    fi
    if [ "$tag" = "$FAILING_VERSION" ] && [ "$(now_epoch)" -lt "$RETRY_AT" ]; then
      continue
    fi
    case " $REFUSED_FALLBACKS " in
      *" $tag "*) continue ;;
    esac
    [ "$checked" -lt "$MAX_FALLBACK_CANDIDATES" ] || return 1
    checked=$(( checked + 1 ))
    if timeout 30 docker manifest inspect "$IMAGE_REPO:sha-${sha:0:7}" >/dev/null 2>&1; then
      printf '%s\n' "$tag"
      return 0
    fi
  done < <(fetch_release_tags)
  return 1
}

deploy_newest_published() {  # $1 = the newest release, which waits
  local latest="$1" fallback waiting_version waiting_since rc
  if [ "$REFUSED_FALLBACKS_FOR" != "$latest" ]; then
    REFUSED_FALLBACKS_FOR="$latest"
    REFUSED_FALLBACKS=""
  fi
  fallback="$(pick_fallback_release "$latest")" || return 0
  [ -n "$fallback" ] || return 0
  log "the image of $latest is not published yet; deploying $fallback, the newest release that has one"
  append_history "$fallback" fallback chosen "the image of $latest is not published yet"
  waiting_version="$WAITING_VERSION"
  waiting_since="$WAITING_SINCE"
  do_deploy "$fallback"
  rc=$?
  if [ "$rc" -eq 2 ] && [ -z "$STAGED_IMAGE" ]; then
    REFUSED_FALLBACKS="$REFUSED_FALLBACKS $fallback"
    append_history "$fallback" fallback refused "$WAIT_REASON"
  fi
  WAITING_VERSION="$waiting_version"
  WAITING_SINCE="$waiting_since"
}

# Run the daemon only when executed. The tests source this file for its
# functions.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main
fi
