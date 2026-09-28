#!/usr/bin/env bash
set -uo pipefail

# Behaviour tests for deploy/chickadee-deployer.sh.
#
# The daemon runs as root on the production host with docker, nginx and the
# network, and none of those exist here. So this sources the daemon for its
# functions, puts stub `docker` and `curl` commands first on PATH, stubs the
# deploy and snapshot scripts, and replaces the clock and `sleep` with a fake
# clock. Each stub records its calls; each case sets up a scenario, runs one
# cycle, and asserts what the daemon did and wrote.
#
# Every case below is a defect the daemon had on 2026-09-22, observed in its
# own deploy history:
#   * an expired certificate rolled back every healthy release (19 swaps in
#     90 minutes);
#   * a release was swapped to before its image existed, repeatedly;
#   * those rollbacks never counted toward the `stuck` state.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

STUB="$WORK/stub"
BIN="$WORK/bin"
mkdir -p "$STUB" "$BIN"

RELEASE_SHA="b485699b4cf98c8dd7acd1f8f82644073b5e2bef"
IMAGE="ghcr.io/jimwallace/chickadee"

# ---------------------------------------------------------------------------
# Stubs. Behaviour is read from files in $STUB so each case can change it.
# ---------------------------------------------------------------------------
cat > "$BIN/docker" <<'SH'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "$STUB/calls"
case "$1" in
  pull)
    [ -f "$STUB/image_published" ] || { echo "manifest unknown" >&2; exit 1; }
    ;;
  image)
    case "$*" in
      *revision*) cat "$STUB/image_revision" ;;
      *RepoDigests*) echo "ghcr.io/jimwallace/chickadee@sha256:0123abcd" ;;
    esac
    ;;
esac
exit 0
SH

cat > "$BIN/curl" <<'SH'
#!/usr/bin/env bash
insecure=0
url=""
for arg in "$@"; do
  case "$arg" in
    http*) url="$arg" ;;
    -*k*) [[ "$arg" == --* ]] || insecure=1 ;;
  esac
done
printf 'curl insecure=%s %s\n' "$insecure" "$url" >> "$STUB/calls"
case "$url" in
  */releases/latest) printf '{"tag_name": "%s"}\n' "$(cat "$STUB/latest_release")" ;;
  */commits/*) printf '{"sha": "%s"}\n' "$(cat "$STUB/release_sha")" ;;
  */health)
    mode="$(cat "$STUB/health")"
    if [ "$mode" = "tls" ] && [ "$insecure" = "0" ]; then
      echo "curl: (60) SSL certificate problem: certificate has expired" >&2
      exit 60
    fi
    if [ "$mode" = "down" ]; then
      echo "curl: (7) Failed to connect" >&2
      exit 7
    fi
    printf '{"version": "%s"}\n' "$(cat "$STUB/running_version")"
    ;;
esac
exit 0
SH

cat > "$WORK/deploy-script" <<'SH'
#!/usr/bin/env bash
printf 'deploy-script %s image=%s\n' "$*" "${CHICKADEE_IMAGE:-}" >> "$STUB/calls"
if [ "$1" = "deploy" ] && [ -f "$STUB/deploy_ok" ]; then
  cp "$STUB/target_version" "$STUB/running_version"
fi
[ "$1" = "rollback" ] || [ -f "$STUB/deploy_ok" ]
SH

cat > "$WORK/snapshot-script" <<'SH'
#!/usr/bin/env bash
printf 'snapshot %s\n' "$*" >> "$STUB/calls"
SH

chmod +x "$BIN/docker" "$BIN/curl" "$WORK/deploy-script" "$WORK/snapshot-script"
touch "$WORK/docker-compose.yml"

export STUB
export PATH="$BIN:$PATH"
export CHICKADEE_STATE_DIR="$WORK/state"
export CHICKADEE_DEPLOY_SCRIPT="$WORK/deploy-script"
export CHICKADEE_SNAPSHOT_SCRIPT="$WORK/snapshot-script"
export CHICKADEE_COMPOSE_DIR="$WORK"
export CHICKADEE_COMPOSE_FILE="$WORK/docker-compose.yml"

# shellcheck source=../deploy/chickadee-deployer.sh
. "$REPO_ROOT/deploy/chickadee-deployer.sh"

# The fake clock. `sleep` advances it instead of waiting.
FAKE_NOW=1000000
now_epoch() { printf '%s\n' "$FAKE_NOW"; }
sleep() { FAKE_NOW=$(( FAKE_NOW + ${1%.*} )); }
log() { :; }

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------
FAILURES=0
CASE=""

fail() {
  printf 'FAIL [%s]: %s\n' "$CASE" "$1"
  FAILURES=$(( FAILURES + 1 ))
}

calls_matching() { grep -c -- "$1" "$STUB/calls" 2>/dev/null || true; }

expect_calls() {  # $1 = pattern, $2 = expected count
  local n; n="$(calls_matching "$1")"
  [ "$n" = "$2" ] || fail "expected $2 call(s) matching '$1', saw $n"
}

expect_state() {  # $1 = expected status state
  local state; state="$(json_field "$STATUS_FILE" state)"
  [ "$state" = "$1" ] || fail "expected status state '$1', saw '$state' ($(json_field "$STATUS_FILE" detail))"
}

expect_history() {  # $1 = action, $2 = result
  grep -q "\"action\": \"$1\", \"result\": \"$2\"" "$HISTORY_FILE" 2>/dev/null \
    || fail "expected a history entry with action=$1 result=$2"
}

# ---------------------------------------------------------------------------
# Each case starts from 0.5.231 live, release v0.5.232 published.
# ---------------------------------------------------------------------------
start_case() {
  CASE="$1"
  rm -rf "$STUB"/* "$CHICKADEE_STATE_DIR"
  mkdir -p "$CHICKADEE_STATE_DIR"
  : > "$STUB/calls"
  echo "v0.5.232" > "$STUB/latest_release"
  echo "$RELEASE_SHA" > "$STUB/release_sha"
  echo "$RELEASE_SHA" > "$STUB/image_revision"
  echo "0.5.231" > "$STUB/running_version"
  echo "0.5.232" > "$STUB/target_version"
  echo "ok" > "$STUB/health"
  touch "$STUB/image_published" "$STUB/deploy_ok"
  DEPLOYED_VERSION="0.5.231"
  PAUSED=0
  APPROVED_VERSION=""
  clear_failures
}

# ---------------------------------------------------------------------------
start_case "a published release deploys its own image by digest"
run_cycle
expect_calls "docker pull -q $IMAGE:sha-b485699" 1
expect_calls "docker tag $IMAGE:sha-b485699 $IMAGE:latest" 1
expect_calls "docker rmi $IMAGE:sha-b485699" 1
expect_calls "deploy-script deploy --yes image=$IMAGE@sha256:0123abcd" 1
expect_calls "snapshot" 1
expect_calls "docker compose .* up -d --no-deps runner" 1
expect_calls "docker compose .* pull" 0
expect_state idle
[ "$DEPLOYED_VERSION" = "0.5.232" ] || fail "expected 0.5.232 deployed, saw $DEPLOYED_VERSION"

# ---------------------------------------------------------------------------
start_case "an unpublished release image waits without a swap or snapshot"
rm "$STUB/image_published"
run_cycle
run_cycle
expect_calls "deploy-script" 0
expect_calls "snapshot" 0
expect_calls "docker compose" 0
expect_state waiting_for_image
[ "$(grep -c '"action": "image"' "$HISTORY_FILE")" = "1" ] || fail "expected one image-waiting history entry for two waiting cycles"
touch "$STUB/image_published"
run_cycle
expect_calls "deploy-script deploy" 1
expect_state idle

# ---------------------------------------------------------------------------
start_case "an image whose revision is another commit is not deployed"
echo "03df65cfb5cd97613bf7356a7204e88c866ca107" > "$STUB/image_revision"
run_cycle
expect_calls "deploy-script" 0
expect_calls "docker tag" 0
expect_state waiting_for_image

# ---------------------------------------------------------------------------
start_case "a wait of more than two hours is reported as stuck"
rm "$STUB/image_published"
run_cycle
FAKE_NOW=$(( FAKE_NOW + 7200 ))
run_cycle
expect_state stuck
expect_calls "deploy-script" 0

# ---------------------------------------------------------------------------
start_case "an approval survives while the image of a gated release is built"
echo "v1.0.0" > "$STUB/latest_release"
echo "1.0.0" > "$STUB/target_version"
APPROVED_VERSION="v1.0.0"
rm "$STUB/image_published"
run_cycle
[ "$APPROVED_VERSION" = "v1.0.0" ] || fail "approval was cleared while waiting for the image"
touch "$STUB/image_published"
run_cycle
expect_calls "deploy-script deploy" 1
[ -z "$APPROVED_VERSION" ] || fail "approval was not cleared after the deploy"

# ---------------------------------------------------------------------------
start_case "an expired certificate does not roll back a healthy release"
echo "tls" > "$STUB/health"
run_cycle
expect_calls "deploy-script rollback" 0
expect_state certificate_invalid
expect_history certificate failed
grep -q 'certificate has expired' "$STATUS_FILE" || fail "status detail does not carry the curl error"
[ "$DEPLOYED_VERSION" = "0.5.232" ] || fail "expected 0.5.232 recorded as deployed, saw $DEPLOYED_VERSION"

# ---------------------------------------------------------------------------
start_case "an unhealthy release is rolled back and backed off"
echo "down" > "$STUB/health"
run_cycle
expect_calls "deploy-script rollback" 1
expect_state error
first_retry=$(( RETRY_AT - FAKE_NOW ))
[ "$first_retry" = "$POLL_INTERVAL_SECS" ] || fail "expected a first retry delay of $POLL_INTERVAL_SECS s, saw $first_retry s"
run_cycle
expect_calls "deploy-script deploy" 1
FAKE_NOW="$RETRY_AT"
run_cycle
expect_calls "deploy-script deploy" 2
second_retry=$(( RETRY_AT - FAKE_NOW ))
[ "$second_retry" = $(( POLL_INTERVAL_SECS * 2 )) ] || fail "expected the retry delay to double, saw $second_retry s"

# ---------------------------------------------------------------------------
start_case "rollbacks count toward stuck and the delay is capped"
echo "down" > "$STUB/health"
for _ in 1 2 3 4 5 6 7 8; do
  FAKE_NOW="$RETRY_AT"
  [ "$RETRY_AT" -gt 0 ] || FAKE_NOW=1000000
  run_cycle
done
expect_state stuck
[ "$CONSECUTIVE_DEPLOY_FAILURES" = "8" ] || fail "expected 8 consecutive failures, saw $CONSECUTIVE_DEPLOY_FAILURES"
[ $(( RETRY_AT - FAKE_NOW )) = "$MAX_RETRY_DELAY_SECS" ] || fail "retry delay is not capped at $MAX_RETRY_DELAY_SECS s"

# ---------------------------------------------------------------------------
start_case "a newer release is tried at once and starts a new count"
echo "down" > "$STUB/health"
run_cycle
run_cycle
expect_calls "deploy-script deploy" 1
echo "v0.5.233" > "$STUB/latest_release"
run_cycle
expect_calls "deploy-script deploy" 2
[ "$CONSECUTIVE_DEPLOY_FAILURES" = "1" ] || fail "a new version did not restart the failure count"

# ---------------------------------------------------------------------------
start_case "an approve command skips the backoff"
echo "down" > "$STUB/health"
run_cycle
printf '{"command": "approve", "version": "v0.5.232"}' > "$COMMAND_FILE"
run_cycle
expect_calls "deploy-script deploy" 2

# ---------------------------------------------------------------------------
if [ "$FAILURES" -gt 0 ]; then
  printf '%s deployer test failure(s)\n' "$FAILURES"
  exit 1
fi
echo "deployer tests: all cases passed"
