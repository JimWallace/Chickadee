#!/usr/bin/env bash
set -uo pipefail

# Behaviour tests for deploy/chickadee-runner-update.sh.
#
# The script runs from cron on a runner host with docker and the network, and
# neither exists here. So this sources the script for its functions, puts stub
# `docker` and `curl` commands first on PATH and replaces `sleep`. Each stub
# records its calls; each case sets up a scenario, runs one update and asserts
# what the script did.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

STUB="$WORK/stub"
BIN="$WORK/bin"
mkdir -p "$STUB" "$BIN"

RELEASE_SHA="b485699b4cf98c8dd7acd1f8f82644073b5e2bef"
OLD_SHA="0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c"
IMAGE="ghcr.io/jimwallace/chickadee"

cat > "$BIN/docker" <<'SH'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "$STUB/calls"
case "$1" in
  pull)
    [ -f "$STUB/image_published" ] || { echo "manifest unknown" >&2; exit 1; }
    ;;
  image)
    case "$*" in
      *revision*sha256:runnerimage) cat "$STUB/runner_revision" ;;
      *revision*) cat "$STUB/image_revision" ;;
    esac
    ;;
  compose)
    case "$*" in
      *" ps "*) [ -f "$STUB/no_container" ] || echo "runnercid" ;;
      *" up "*) [ -f "$STUB/compose_up_fails" ] && exit 1 ;;
    esac
    ;;
  inspect)
    case "$*" in
      *.Image*) echo "sha256:runnerimage" ;;
      *)
        # A crashing runner restarts between any two looks at it.
        if [ -f "$STUB/runner_crashing" ]; then
          n=$(( $(cat "$STUB/runner_restarts" 2>/dev/null || echo 0) + 1 ))
          echo "$n" > "$STUB/runner_restarts"
          echo "restarting $n"
        else
          echo "running 0"
        fi
        ;;
    esac
    ;;
  logs)
    echo "--sandbox is set, but this host cannot start the sandbox"
    ;;
esac
exit 0
SH

cat > "$BIN/curl" <<'SH'
#!/usr/bin/env bash
url=""
for arg in "$@"; do
  case "$arg" in http*) url="$arg" ;; esac
done
printf 'curl %s\n' "$url" >> "$STUB/calls"
case "$url" in
  */commits/v0.5.232) printf '{"sha": "%s"}\n' "$(cat "$STUB/release_sha")" ;;
  */commits/*) exit 22 ;;
  */health)
    [ -f "$STUB/server_down" ] && exit 7
    printf '{"version": "%s"}\n' "$(cat "$STUB/server_version")"
    ;;
esac
exit 0
SH

chmod +x "$BIN/docker" "$BIN/curl"
export STUB
export PATH="$BIN:$PATH"

# shellcheck source=../deploy/chickadee-runner-update.sh
. "$REPO_ROOT/deploy/chickadee-runner-update.sh"
COMPOSE_DIR="$WORK"
touch "$WORK/docker-compose.yml"
sleep() { :; }

FAILURES=0
CASE=""
OUTPUT=""
STATUS=0

fail() {
  printf 'FAIL [%s]: %s\n' "$CASE" "$1"
  FAILURES=$(( FAILURES + 1 ))
}

calls_matching() { grep -c -- "$1" "$STUB/calls" 2>/dev/null || true; }

expect_calls() {  # $1 = pattern, $2 = expected count
  local n; n="$(calls_matching "$1")"
  [ "$n" = "$2" ] || fail "expected $2 call(s) matching '$1', saw $n"
}

expect_status() {  # $1 = expected exit status
  [ "$STATUS" = "$1" ] || fail "expected exit status $1, saw $STATUS (output: $OUTPUT)"
}

expect_output() {  # $1 = text the output must contain
  case "$OUTPUT" in
    *"$1"*) ;;
    *) fail "expected the output to contain '$1', saw: $OUTPUT" ;;
  esac
}

# Each case starts with the server on v0.5.232 and the runner on an older
# build.
start_case() {
  CASE="$1"
  rm -rf "${STUB:?}"/*
  : > "$STUB/calls"
  echo "0.5.232" > "$STUB/server_version"
  echo "$RELEASE_SHA" > "$STUB/release_sha"
  echo "$RELEASE_SHA" > "$STUB/image_revision"
  echo "$OLD_SHA" > "$STUB/runner_revision"
  touch "$STUB/image_published"
}

run_update() {
  OUTPUT="$(update_runner 2>&1)"
  STATUS=$?
}

# ---------------------------------------------------------------------------
start_case "a runner on another build moves to the server's release"
run_update
expect_status 0
expect_calls "docker pull -q $IMAGE:sha-b485699" 1
expect_calls "docker tag $IMAGE:sha-b485699 $IMAGE:latest" 1
expect_calls "docker rmi $IMAGE:sha-b485699" 1
expect_calls "docker compose .* up -d --no-deps runner" 1
expect_calls "docker compose .* pull" 0
expect_calls "docker pull -q $IMAGE:latest" 0
expect_calls "docker image prune -f" 1
expect_output "'runner' runs v0.5.232"

# ---------------------------------------------------------------------------
start_case "a runner already on the server's release is not touched"
echo "$RELEASE_SHA" > "$STUB/runner_revision"
run_update
expect_status 0
expect_calls "docker pull" 0
expect_calls "docker compose .* up" 0
[ -z "$OUTPUT" ] || fail "expected no output, saw: $OUTPUT"

# ---------------------------------------------------------------------------
start_case "a host with no runner container yet gets one"
touch "$STUB/no_container"
run_update
expect_calls "docker pull -q $IMAGE:sha-b485699" 1
expect_calls "docker compose .* up -d --no-deps runner" 1

# ---------------------------------------------------------------------------
start_case "a server that does not answer changes nothing"
touch "$STUB/server_down"
run_update
expect_status 1
expect_calls "docker pull" 0
expect_calls "docker compose .* up" 0
expect_output "reported no version"

# ---------------------------------------------------------------------------
start_case "a version with no release tag changes nothing"
echo "0.5.999" > "$STUB/server_version"
run_update
expect_status 1
expect_calls "docker pull" 0
expect_output "could not find the commit of v0.5.999"

# ---------------------------------------------------------------------------
start_case "an image that is not published yet changes nothing"
rm "$STUB/image_published"
run_update
expect_status 1
expect_calls "docker tag" 0
expect_calls "docker compose .* up" 0
expect_output "could not pull $IMAGE:sha-b485699"

# ---------------------------------------------------------------------------
start_case "an image built from another commit is not used"
echo "$OLD_SHA" > "$STUB/image_revision"
run_update
expect_status 1
expect_calls "docker tag" 0
expect_calls "docker compose .* up" 0
expect_calls "docker rmi $IMAGE:sha-b485699" 1
expect_output "expected $RELEASE_SHA"

# ---------------------------------------------------------------------------
start_case "a failed compose up is reported"
touch "$STUB/compose_up_fails"
run_update
expect_status 1
expect_output "compose up failed"

# ---------------------------------------------------------------------------
start_case "a runner that does not stay up is reported with its log"
touch "$STUB/runner_crashing"
run_update
expect_status 1
expect_calls "docker image prune" 0
expect_output "does not stay up on v0.5.232"
expect_output "cannot start the sandbox"

# ---------------------------------------------------------------------------
# macOS has no python3 until the developer tools are installed, and its
# /usr/bin/python3 is then a stub that fails.
start_case "a host without python3 reads the version and the commit"
printf '#!/bin/sh\nexit 1\n' > "$BIN/python3"
chmod +x "$BIN/python3"
run_update
rm -f "$BIN/python3"
expect_status 0
expect_calls "docker pull -q $IMAGE:sha-b485699" 1
expect_output "'runner' runs v0.5.232"

# ---------------------------------------------------------------------------
# GitHub's commit object holds nested "sha" keys after its own.
start_case "the commit is the top-level sha of the commit object"
CASE="json_string"
got="$(printf '{"sha":"%s","commit":{"tree":{"sha":"%s"}}}' "$RELEASE_SHA" "$OLD_SHA" | json_string sha)"
[ "$got" = "$RELEASE_SHA" ] || fail "expected $RELEASE_SHA, saw $got"
got="$(printf '{\n  "sha": "%s",\n  "tree": {"sha": "%s"}\n}\n' "$RELEASE_SHA" "$OLD_SHA" | json_string sha)"
[ "$got" = "$RELEASE_SHA" ] || fail "expected $RELEASE_SHA from indented JSON, saw $got"

# ---------------------------------------------------------------------------
start_case "the lock is taken once, and a second run does not get it"
LOCK_DIR="$WORK/lock"
take_lock || fail "a free lock was not taken"
[ "$(cat "$LOCK_DIR/pid")" = "$$" ] || fail "the lock does not hold the PID of its owner"
take_lock && fail "a lock held by a live process was taken again"
release_lock
[ ! -e "$LOCK_DIR" ] || fail "release_lock left the lock behind"

start_case "a lock whose owner is no longer alive is taken"
LOCK_DIR="$WORK/lock"
sh -c 'exit 0' &
dead=$!
wait "$dead"
mkdir "$LOCK_DIR"
echo "$dead" > "$LOCK_DIR/pid"
take_lock || fail "a stale lock was not taken"
[ "$(cat "$LOCK_DIR/pid")" = "$$" ] || fail "the stale lock does not hold the new owner"
release_lock

start_case "a run that finds the lock taken does nothing"
LOCK_DIR="$WORK/lock"
mkdir "$LOCK_DIR"
echo "$$" > "$LOCK_DIR/pid"
OUTPUT="$(main 2>&1)"
STATUS=$?
expect_status 0
expect_calls "curl" 0
expect_calls "docker" 0
release_lock

# ---------------------------------------------------------------------------
if [ "$FAILURES" -gt 0 ]; then
  printf 'runner-update tests: %s failure(s)\n' "$FAILURES"
  exit 1
fi
echo "runner-update tests: all cases passed"
