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
# An image is published when the case says every image is (image_published), or
# names its short commit (published_<sha7>).
ref="${*: -1}"
short="${ref##*:sha-}"
published() { [ -f "$STUB/image_published" ] || [ -f "$STUB/published_$short" ]; }
case "$1" in
  pull)
    published || { echo "manifest unknown" >&2; exit 1; }
    ;;
  manifest)
    published || { echo "manifest unknown" >&2; exit 1; }
    ;;
  image)
    case "$*" in
      *revision*)
        if [ -f "$STUB/revision_$short" ]; then cat "$STUB/revision_$short"; else cat "$STUB/image_revision"; fi
        ;;
      *RepoDigests*) echo "ghcr.io/jimwallace/chickadee@sha256:0123abcd" ;;
      # Reclaiming space frees enough when the case says so.
      *prune*) [ -f "$STUB/prune_frees" ] && echo $(( 50 * 1024 * 1024 )) > "$STUB/free_kib" ;;
    esac
    ;;
  compose)
    case "$*" in
      *" ps "*) echo "runnercid" ;;
    esac
    ;;
  inspect)
    # A crashing runner restarts between any two looks at it.
    if [ -f "$STUB/runner_crashing" ]; then
      n=$(( $(cat "$STUB/runner_restarts" 2>/dev/null || echo 0) + 1 ))
      echo "$n" > "$STUB/runner_restarts"
      echo "restarting $n"
    else
      echo "running 0"
    fi
    ;;
  logs)
    cat "$STUB/runner_logs" 2>/dev/null
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
  */commits/*)
    tag="${url##*/}"
    if [ -f "$STUB/sha_$tag" ]; then sha="$(cat "$STUB/sha_$tag")"; else sha="$(cat "$STUB/release_sha")"; fi
    printf '{"sha": "%s"}\n' "$sha"
    ;;
  */tags\?*) cat "$STUB/tags" 2>/dev/null || echo '[]' ;;
  */releases\?*) [ -f "$STUB/releases_fail" ] && exit 22; cat "$STUB/releases_json" 2>/dev/null ;;
  */compare/*) [ -f "$STUB/compare_fail" ] && exit 22; cat "$STUB/compare_json" 2>/dev/null ;;
  */search/issues*) cat "$STUB/search_json" 2>/dev/null ;;
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

# Free space in KiB for every path: plenty unless the case sets free_kib, and
# unknown when it sets df_fails.
cat > "$BIN/df" <<'SH'
#!/usr/bin/env bash
printf 'df %s\n' "$*" >> "$STUB/calls"
[ -f "$STUB/df_fails" ] && exit 1
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/test 97517568 0 $(cat "$STUB/free_kib" 2>/dev/null || echo $(( 100 * 1024 * 1024 ))) 0% /"
SH

cat > "$WORK/deploy-script" <<'SH'
#!/usr/bin/env bash
printf 'deploy-script %s image=%s\n' "$*" "${CHICKADEE_IMAGE:-}" >> "$STUB/calls"
if [ "$1" = "deploy" ] && [ -f "$STUB/deploy_ok" ] && [ ! -f "$STUB/deploy_runs_old_build" ]; then
  cp "$STUB/target_version" "$STUB/running_version"
fi
[ "$1" = "rollback" ] || [ -f "$STUB/deploy_ok" ]
SH

cat > "$WORK/snapshot-script" <<'SH'
#!/usr/bin/env bash
printf 'snapshot %s\n' "$*" >> "$STUB/calls"
SH

# cosign verifies the image signature. It fails when the case says the image
# is unsigned.
cat > "$BIN/cosign" <<'SH'
#!/usr/bin/env bash
printf 'cosign %s\n' "$*" >> "$STUB/calls"
[ ! -f "$STUB/unsigned" ] || { echo "Error: no matching attestations" >&2; exit 1; }
SH

chmod +x "$BIN/docker" "$BIN/curl" "$BIN/df" "$BIN/cosign" "$WORK/deploy-script" "$WORK/snapshot-script"
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

# The daemon's git clone, and its restart. The real ones would run git on this
# repository and replace the test process.
repo_git() {
  printf 'git %s\n' "$*" >> "$STUB/calls"
  case "$1" in
    rev-parse)
      case "$2" in
        HEAD) cat "$STUB/git_head" ;;
        --short=12) cut -c1-12 "$STUB/git_head" ;;
        *) cat "$STUB/git_tag_commit" ;;
      esac
      ;;
    status) cat "$STUB/git_dirty" 2>/dev/null ;;
    fetch) [ ! -f "$STUB/git_fetch_fails" ] ;;
    checkout) printf '%s\n' "$4" > "$STUB/git_head" ;;
  esac
}
restart_self() { printf 'restart-self\n' >> "$STUB/calls"; }

# The real installer downloads from GitHub. Keep it under another name for the
# case that tests its hash check, and use the stub everywhere else.
eval "real_$(declare -f ensure_cosign)"
ensure_cosign() {
  if [ -f "$STUB/cosign_missing" ]; then
    WAIT_REASON="could not download cosign"
    return 1
  fi
  COSIGN="$BIN/cosign"
}

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
  echo "$RELEASE_SHA" > "$STUB/git_head"
  echo "$RELEASE_SHA" > "$STUB/git_tag_commit"
  DEPLOYED_VERSION="0.5.231"
  PAUSED=0
  APPROVED_VERSION=""
  REFUSED_FALLBACKS=""
  REFUSED_FALLBACKS_FOR=""
  HELD_VERSION=""
  NOTES_FOR=""
  PRERELEASE_VERSION=""
  PRERELEASE_NOTES_FOR=""
  PRERELEASE_NOTES_RETRY_AT=0
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
expect_calls "cosign verify-attestation --type slsaprovenance1 --certificate-oidc-issuer https://token.actions.githubusercontent.com --certificate-identity https://github.com/JimWallace/Chickadee/.github/workflows/docker-build.yml@refs/tags/v0.5.232 $IMAGE@sha256:0123abcd" 1

# ---------------------------------------------------------------------------
start_case "an image without a signed provenance is not deployed"
touch "$STUB/unsigned"
run_cycle
expect_calls "cosign verify-attestation" 1
expect_calls "docker tag" 0
expect_calls "docker rmi $IMAGE:sha-b485699" 1
expect_calls "deploy-script" 0
expect_calls "snapshot" 0
expect_state waiting_for_image
grep -q "no provenance signed by docker-build.yml at v0.5.232" "$STATUS_FILE" \
  || fail "expected the status to name the missing signature"

# ---------------------------------------------------------------------------
start_case "no cosign means no deploy"
touch "$STUB/cosign_missing"
run_cycle
expect_calls "docker tag" 0
expect_calls "deploy-script" 0
expect_state waiting_for_image

# ---------------------------------------------------------------------------
start_case "a cosign download that does not match the pinned hash is refused"
# The curl stub writes nothing, so the download is empty and its hash is wrong.
if real_ensure_cosign; then
  fail "expected the installer to refuse a download with the wrong hash"
fi
case "$WAIT_REASON" in
  *"does not match its pinned SHA-256"*) ;;
  *) fail "expected a hash mismatch, saw: $WAIT_REASON" ;;
esac
[ -z "$(find "$CHICKADEE_STATE_DIR/bin" -name 'cosign-*' 2>/dev/null)" ] \
  || fail "a refused download must not be installed"

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
start_case "a runner that stays up records the refresh as ok"
run_cycle
expect_history runner-refresh ok
expect_calls "docker inspect" 2

# ---------------------------------------------------------------------------
start_case "a runner that exits at startup records the refresh as failed, with its error"
touch "$STUB/runner_crashing"
printf '%s\n' "Error: the sandbox is on, but this host cannot start the sandbox: unshare: write failed /proc/self/uid_map: Operation not permitted" \
  "A container that drops capabilities or uses the default seccomp profile refuses user and mount namespaces. Allow them, or start the runner with --no-sandbox." \
  > "$STUB/runner_logs"
run_cycle
expect_history runner-refresh failed
grep -q 'runner-refresh.*uid_map: Operation not permitted' "$HISTORY_FILE" \
  || fail "the history detail does not carry the runner's error line"
expect_calls "deploy-script rollback" 0
expect_state idle
[ "$DEPLOYED_VERSION" = "0.5.232" ] || fail "a runner failure changed the deployed version to $DEPLOYED_VERSION"

# ---------------------------------------------------------------------------
OLD_SHA="03df65cfb5cd97613bf7356a7204e88c866ca107"

start_case "an older clone is brought to the release commit and the daemon restarts"
echo "$OLD_SHA" > "$STUB/git_head"
run_cycle
expect_calls "git fetch --quiet origin +refs/tags/v0.5.232:refs/tags/v0.5.232" 1
expect_calls "git checkout --quiet --detach $RELEASE_SHA" 1
expect_calls "restart-self" 1
expect_history deployer-update ok
expect_calls "snapshot" 0
expect_calls "deploy-script" 0

# ---------------------------------------------------------------------------
start_case "a clone already at the release does not fetch, and deploys"
run_cycle
expect_calls "git fetch" 0
expect_calls "restart-self" 0
expect_calls "deploy-script deploy" 1
[ "$(json_field "$STATUS_FILE" scriptsRevision)" = "${RELEASE_SHA:0:12}" ] \
  || fail "status.json does not carry the scripts revision"

# ---------------------------------------------------------------------------
start_case "a clone with local changes is left alone, said once, and the deploy goes on"
echo "$OLD_SHA" > "$STUB/git_head"
echo " M deploy/chickadee-deployer.sh" > "$STUB/git_dirty"
run_cycle
expect_calls "git checkout" 0
expect_calls "restart-self" 0
expect_history deployer-update skipped
expect_calls "deploy-script deploy" 1
echo "v0.5.232" > "$STUB/latest_release"
DEPLOYED_VERSION="0.5.231"
run_cycle
[ "$(grep -c '"action": "deployer-update"' "$HISTORY_FILE")" = "1" ] || fail "the skip was recorded more than once"

# ---------------------------------------------------------------------------
start_case "a tag that names another commit than the release is refused"
echo "$OLD_SHA" > "$STUB/git_head"
echo "$OLD_SHA" > "$STUB/git_tag_commit"
run_cycle
expect_calls "git checkout" 0
expect_calls "restart-self" 0
expect_history deployer-update failed
expect_calls "deploy-script deploy" 1

# ---------------------------------------------------------------------------
start_case "a failed fetch keeps the current scripts and deploys"
echo "$OLD_SHA" > "$STUB/git_head"
touch "$STUB/git_fetch_fails"
run_cycle
expect_calls "git checkout" 0
expect_history deployer-update failed
expect_calls "deploy-script deploy" 1

# ---------------------------------------------------------------------------
start_case "a healthy server that reports another version is rolled back, not recorded"
touch "$STUB/deploy_runs_old_build"
run_cycle
expect_calls "deploy-script rollback" 1
expect_history deploy rolledback
expect_state error
grep -q 'reported version 0.5.231, expected 0.5.232' "$STATUS_FILE" \
  || fail "the status detail does not name the running and expected versions"
[ "$DEPLOYED_VERSION" = "0.5.231" ] || fail "a version mismatch was recorded as deployed: $DEPLOYED_VERSION"
expect_calls "docker compose .* up -d --no-deps runner" 0

# ---------------------------------------------------------------------------
start_case "a runner refresh removes the image the runner stopped using"
run_cycle
expect_history runner-refresh ok
expect_calls "docker image prune -a -f" 1

# ---------------------------------------------------------------------------
start_case "a runner that does not stay up leaves its images alone"
touch "$STUB/runner_crashing"
run_cycle
expect_history runner-refresh failed
expect_calls "docker image prune" 0

# ---------------------------------------------------------------------------
start_case "a host short of disk space reclaims, then holds the deploy without pulling"
echo $(( 4 * 1024 * 1024 )) > "$STUB/free_kib"
run_cycle
run_cycle
expect_calls "docker image prune -a -f" 2
expect_calls "docker pull" 0
expect_calls "snapshot" 0
expect_calls "deploy-script" 0
expect_state disk_low
grep -q 'only 4 GiB free' "$STATUS_FILE" || fail "the status detail does not say how much is free"
[ "$(grep -c '"action": "disk"' "$HISTORY_FILE")" = "1" ] || fail "expected one disk-low history entry for two held cycles"
[ "$DEPLOYED_VERSION" = "0.5.231" ] || fail "a held deploy changed the deployed version: $DEPLOYED_VERSION"

# ---------------------------------------------------------------------------
start_case "a host whose reclaim frees enough space deploys"
echo $(( 4 * 1024 * 1024 )) > "$STUB/free_kib"
touch "$STUB/prune_frees"
run_cycle
expect_calls "deploy-script deploy" 1
expect_state idle
[ "$DEPLOYED_VERSION" = "0.5.232" ] || fail "expected 0.5.232 deployed, saw $DEPLOYED_VERSION"

# ---------------------------------------------------------------------------
start_case "a host that cannot report its free space still deploys"
touch "$STUB/df_fails"
run_cycle
expect_calls "deploy-script deploy" 1
expect_calls "docker image prune -a -f" 1
expect_state idle

# ---------------------------------------------------------------------------
# While the newest release waits for its image, the newest older release that
# has one goes out. Production stayed on 0.5.964 for hours on 2026-11-16
# because every merge moved the target before its image existed.
# ---------------------------------------------------------------------------
OLD_SHA="03df65cfb5cd97613bf7356a7204e88c866ca107"
MID_SHA="5f1e2d3c4b5a69788796a5b4c3d2e1f0a9b8c7d6"

fallback_case() {  # $1 = case name. v0.5.234 waits; v0.5.233 is built.
  start_case "$1"
  echo "v0.5.234" > "$STUB/latest_release"
  echo "$RELEASE_SHA" > "$STUB/sha_v0.5.234"
  echo "$OLD_SHA" > "$STUB/sha_v0.5.233"
  echo "$MID_SHA" > "$STUB/sha_v0.5.232"
  cat > "$STUB/tags" <<JSON
[{"name": "v0.5.232", "commit": {"sha": "$MID_SHA"}},
 {"name": "v0.5.234", "commit": {"sha": "$RELEASE_SHA"}},
 {"name": "not-a-release", "commit": {"sha": "$OLD_SHA"}},
 {"name": "v0.5.233", "commit": {"sha": "$OLD_SHA"}},
 {"name": "v0.5.231", "commit": {"sha": "$MID_SHA"}}]
JSON
  rm "$STUB/image_published"
  touch "$STUB/published_${OLD_SHA:0:7}" "$STUB/published_${MID_SHA:0:7}"
  echo "$OLD_SHA" > "$STUB/revision_${OLD_SHA:0:7}"
  echo "$MID_SHA" > "$STUB/revision_${MID_SHA:0:7}"
  echo "0.5.233" > "$STUB/target_version"
  echo "$OLD_SHA" > "$STUB/git_head"
  echo "$OLD_SHA" > "$STUB/git_tag_commit"
}

# ---------------------------------------------------------------------------
fallback_case "a newest release without an image does not hold back an older one that has one"
run_cycle
expect_calls "deploy-script deploy --yes" 1
expect_calls "docker pull -q $IMAGE:sha-${OLD_SHA:0:7}" 1
expect_calls "docker pull -q $IMAGE:sha-${MID_SHA:0:7}" 0
expect_history fallback chosen
[ "$DEPLOYED_VERSION" = "0.5.233" ] || fail "expected the fallback 0.5.233 deployed, saw $DEPLOYED_VERSION"
[ "$LATEST_SEEN" = "v0.5.234" ] || fail "expected v0.5.234 still reported as the latest seen, saw $LATEST_SEEN"
[ "$WAITING_VERSION" = "v0.5.234" ] || fail "the newest release lost its wait clock: $WAITING_VERSION"
run_cycle
expect_calls "deploy-script deploy --yes" 1
expect_state waiting_for_image
touch "$STUB/published_${RELEASE_SHA:0:7}"
echo "0.5.234" > "$STUB/target_version"
echo "$RELEASE_SHA" > "$STUB/git_head"
echo "$RELEASE_SHA" > "$STUB/git_tag_commit"
run_cycle
expect_calls "deploy-script deploy --yes" 2
expect_state idle
[ "$DEPLOYED_VERSION" = "0.5.234" ] || fail "expected 0.5.234 deployed once built, saw $DEPLOYED_VERSION"

# ---------------------------------------------------------------------------
fallback_case "a newest release that never builds still becomes stuck after a fallback"
run_cycle
[ "$DEPLOYED_VERSION" = "0.5.233" ] || fail "expected the fallback 0.5.233 deployed, saw $DEPLOYED_VERSION"
FAKE_NOW=$(( FAKE_NOW + 7200 ))
run_cycle
expect_state stuck

# ---------------------------------------------------------------------------
fallback_case "no fallback when no older release has an image"
rm "$STUB/published_${OLD_SHA:0:7}" "$STUB/published_${MID_SHA:0:7}"
run_cycle
expect_calls "deploy-script" 0
expect_calls "docker manifest inspect" 2
expect_state waiting_for_image
[ "$DEPLOYED_VERSION" = "0.5.231" ] || fail "a deploy happened without an image: $DEPLOYED_VERSION"

# ---------------------------------------------------------------------------
fallback_case "a fallback that is backed off after a failure is skipped"
FAILING_VERSION="v0.5.233"
RETRY_AT=$(( FAKE_NOW + 600 ))
echo "0.5.232" > "$STUB/target_version"
echo "$MID_SHA" > "$STUB/git_head"
echo "$MID_SHA" > "$STUB/git_tag_commit"
run_cycle
expect_calls "docker pull -q $IMAGE:sha-${OLD_SHA:0:7}" 0
[ "$DEPLOYED_VERSION" = "0.5.232" ] || fail "expected 0.5.232 deployed past the backed-off 0.5.233, saw $DEPLOYED_VERSION"

# ---------------------------------------------------------------------------
fallback_case "a disk hold does not send a fallback out"
echo $(( 4 * 1024 * 1024 )) > "$STUB/free_kib"
run_cycle
expect_calls "docker manifest" 0
expect_calls "deploy-script" 0
expect_state disk_low

# ---------------------------------------------------------------------------
fallback_case "a fallback whose image fails to stage is tried once, then the next one goes out"
echo "03df65c0000000000000000000000000000000ff" > "$STUB/revision_${OLD_SHA:0:7}"
run_cycle
expect_calls "deploy-script" 0
expect_history fallback refused
echo "0.5.232" > "$STUB/target_version"
echo "$MID_SHA" > "$STUB/git_head"
echo "$MID_SHA" > "$STUB/git_tag_commit"
run_cycle
expect_calls "docker pull -q $IMAGE:sha-${OLD_SHA:0:7}" 1
[ "$DEPLOYED_VERSION" = "0.5.232" ] || fail "expected 0.5.232 deployed after 0.5.233 was refused, saw $DEPLOYED_VERSION"

# ---------------------------------------------------------------------------
start_case "a newest image that is published but refused sends no fallback out"
echo "03df65cfb5cd97613bf7356a7204e88c866ca107" > "$STUB/image_revision"
run_cycle
expect_calls "docker manifest" 0
expect_calls "deploy-script" 0
expect_state waiting_for_image

# ---------------------------------------------------------------------------
# The release gate (docs/release-gate.md): deploy modes, the admin page's
# request channel, and what survives a restart.
# ---------------------------------------------------------------------------
REQ="$CHICKADEE_STATE_DIR/requests"

request() {  # $1 = file name, $2 = JSON body
  mkdir -p "$REQ"
  printf '%s' "$2" > "$REQ/$1"
}

expect_history_line() {  # $1 = a regex one history line must match
  grep -qE -- "$1" "$HISTORY_FILE" 2>/dev/null || fail "expected a history line matching '$1'"
}

expect_status_field() {  # $1 = key, $2 = expected value
  local v; v="$(json_field "$STATUS_FILE" "$1")"
  [ "$v" = "$2" ] || fail "expected status $1='$2', saw '$v'"
}

minor_release() {  # the next release is the minor v0.6.0
  echo "v0.6.0" > "$STUB/latest_release"
  echo "0.6.0" > "$STUB/target_version"
}

# ---------------------------------------------------------------------------
start_case "with no mode file, a patch deploys (gated-minors is the default)"
run_cycle
expect_calls "deploy-script deploy" 1
expect_status_field mode gated-minors

# ---------------------------------------------------------------------------
start_case "with no mode file, a minor is held once and its notes are written"
minor_release
cat > "$STUB/releases_json" <<'JSON'
[{"tag_name": "v0.6.0", "name": "Chickadee v0.6.0", "body": "- **Kernels.** Re-vendored (#3100).", "html_url": "https://example/r/600", "published_at": "2026-11-20T00:00:00Z"},
 {"tag_name": "v0.5.232", "name": "Chickadee v0.5.232", "body": "- A fix (#3099).", "html_url": "https://example/r/5232", "published_at": "2026-11-19T00:00:00Z"},
 {"tag_name": "v0.5.231", "name": "Chickadee v0.5.231", "body": "- Already live.", "html_url": "https://example/r/5231", "published_at": "2026-11-18T00:00:00Z"}]
JSON
cat > "$STUB/compare_json" <<'JSON'
{"commits": [{"commit": {"message": "A fix (#3099)"}}, {"commit": {"message": "Re-vendor the xeus kernels (#3100)\n\nbody"}}]}
JSON
cat > "$STUB/search_json" <<'JSON'
{"items": [{"number": 3100, "title": "Re-vendor the xeus kernels", "html_url": "https://example/pull/3100"}, {"number": 2000, "title": "An older minor", "html_url": "https://example/pull/2000"}]}
JSON
run_cycle
run_cycle
expect_calls "deploy-script" 0
expect_state pending_approval
expect_status_field heldVersion v0.6.0
[ "$(grep -c '"action": "gate"' "$HISTORY_FILE")" = "1" ] || fail "expected one gate-held history entry for two held cycles"
[ -f "$PENDING_NOTES_FILE" ] || fail "no pending-notes.json while holding"
python3 - "$PENDING_NOTES_FILE" <<'PY' || fail "pending-notes.json does not carry the releases in range and the minor-release pull request"
import json, sys
notes = json.load(open(sys.argv[1]))
assert notes["heldVersion"] == "v0.6.0", notes
assert [r["tag"] for r in notes["releases"]] == ["v0.6.0", "v0.5.232"], notes["releases"]
assert [p["number"] for p in notes["minorReleasePullRequests"]] == [3100], notes["minorReleasePullRequests"]
PY
expect_calls "curl insecure=0 https://api.github.com/repos/.*/compare/" 1

# ---------------------------------------------------------------------------
start_case "autonomous deploys a minor"
minor_release
echo "autonomous" > "$CHICKADEE_STATE_DIR/mode"
run_cycle
expect_calls "deploy-script deploy" 1
expect_status_field mode autonomous

# ---------------------------------------------------------------------------
start_case "autonomous still holds a major"
echo "v1.0.0" > "$STUB/latest_release"
echo "autonomous" > "$CHICKADEE_STATE_DIR/mode"
run_cycle
expect_calls "deploy-script" 0
expect_state pending_approval

# ---------------------------------------------------------------------------
start_case "manual holds a patch"
echo "manual" > "$CHICKADEE_STATE_DIR/mode"
run_cycle
expect_calls "deploy-script" 0
expect_state pending_approval
expect_status_field heldVersion v0.5.232

# ---------------------------------------------------------------------------
start_case "a mode file that names no mode means gated-minors"
minor_release
echo "yolo" > "$CHICKADEE_STATE_DIR/mode"
run_cycle
expect_calls "deploy-script" 0
expect_status_field mode gated-minors

# ---------------------------------------------------------------------------
start_case "an approve request for the held release deploys it and is recorded with its user"
minor_release
run_cycle
request "001-approve.json" '{"request": "approve", "version": "v0.6.0", "user": "alice"}'
run_cycle
expect_calls "deploy-script deploy" 1
expect_history_line '"action": "approve", "result": "accepted".*"user": "alice"'
[ -z "$(ls -A "$REQ")" ] || fail "the request file was not removed"
[ ! -f "$APPROVED_FILE" ] || fail "the approval was not cleared after the deploy"
[ ! -f "$PENDING_NOTES_FILE" ] || fail "pending-notes.json outlived the deploy"

# ---------------------------------------------------------------------------
start_case "an approve request for another version is refused"
minor_release
run_cycle
request "001-approve.json" '{"request": "approve", "version": "v0.5.232", "user": "mallory"}'
run_cycle
expect_calls "deploy-script" 0
expect_state pending_approval
expect_history_line '"version": "v0.5.232", "action": "approve", "result": "refused".*"user": "mallory"'

# ---------------------------------------------------------------------------
start_case "a newer release that appears after an approval is held for its own approval"
minor_release
run_cycle
request "001-approve.json" '{"request": "approve", "version": "v0.6.0", "user": "alice"}'
echo "v0.6.1" > "$STUB/latest_release"
run_cycle
expect_calls "deploy-script" 0
expect_status_field heldVersion v0.6.1

# ---------------------------------------------------------------------------
start_case "rollback, deploy, unknown, oversized, malformed and symlinked requests are refused and removed"
request "01.json" '{"request": "rollback", "user": "mallory"}'
request "02.json" '{"request": "deploy", "version": "v0.5.100", "user": "mallory"}'
request "03.json" '{"request": "shell", "user": "mallory"}'
request "04.json" "{\"request\": \"pause\", \"user\": \"mallory\", \"pad\": \"$(head -c 5000 /dev/zero | tr '\0' x)\"}"
request "05.json" 'not json'
ln -s /etc/passwd "$REQ/06.json"
request "07.txt" '{"request": "pause"}'
run_cycle
expect_calls "deploy-script rollback" 0
[ "$PAUSED" = "0" ] || fail "an oversized pause request was accepted"
[ "$(grep -c '"action": "request", "result": "refused"' "$HISTORY_FILE")" = "6" ] || fail "expected six refused requests in the history"
expect_history_line 'rollback is a host action'
expect_history_line 'larger than 4096 bytes'
expect_history_line 'not a regular file'
[ "$(ls -A "$REQ")" = "07.txt" ] || fail "expected only the non-.json file to remain, saw: $(ls -A "$REQ" | tr '\n' ' ')"
[ "$DEPLOYED_VERSION" = "0.5.232" ] || fail "refused requests stopped the ordinary patch deploy"

# ---------------------------------------------------------------------------
start_case "a FIFO or a directory named .json does not hang or repeat, and a flood waits"
mkdir -p "$REQ"
mkfifo "$REQ/01.json"
mkdir -p "$REQ/02.json/inside"
for n in $(seq 10 70); do request "$n.json" '{"request": "resume", "user": "flood"}'; done
run_cycle
expect_history_line 'not a regular file \(01.json\)'
expect_history_line 'not a regular file \(02.json\)'
expect_history_line '13 more requests wait for the next poll'
[ ! -e "$REQ/01.json" ] && [ ! -e "$REQ/02.json" ] || fail "the FIFO or the directory was not removed"
before="$(grep -c 'not a regular file' "$HISTORY_FILE")"
run_cycle
[ "$(grep -c 'not a regular file' "$HISTORY_FILE")" = "$before" ] || fail "a removed entry was refused again"
[ -z "$(ls -A "$REQ")" ] || fail "the waiting requests were not read on the next poll"

# ---------------------------------------------------------------------------
start_case "notes whose fetch failed are fetched again on the next poll"
minor_release
touch "$STUB/releases_fail"
run_cycle
rm "$STUB/releases_fail"
run_cycle
expect_calls "curl insecure=0 https://api.github.com/repos/.*/compare/" 2
run_cycle
expect_calls "curl insecure=0 https://api.github.com/repos/.*/compare/" 2

# ---------------------------------------------------------------------------
start_case "a pause request persists, holds an approved release, and resume releases it"
minor_release
run_cycle
request "001-approve.json" '{"request": "approve", "version": "v0.6.0", "user": "alice"}'
request "002-pause.json" '{"request": "pause", "user": "alice"}'
touch -t 202601010000 "$REQ/001-approve.json"
run_cycle
expect_state paused
expect_calls "deploy-script" 0
[ -f "$PAUSED_FILE" ] || fail "pause was not written to the state folder"
[ "$(cat "$APPROVED_FILE" 2>/dev/null)" = "v0.6.0" ] || fail "the approval was not written to the state folder"
# A restart (the daemon updating its own scripts) keeps both.
PAUSED=0; APPROVED_VERSION=""; HELD_VERSION=""
load_state
[ "$PAUSED" = "1" ] || fail "pause did not survive a restart"
[ "$APPROVED_VERSION" = "v0.6.0" ] || fail "the approval did not survive a restart"
[ "$HELD_VERSION" = "v0.6.0" ] || fail "the held release did not survive a restart"
run_cycle
expect_calls "deploy-script" 0
request "003-resume.json" '{"request": "resume", "user": "bob"}'
run_cycle
expect_calls "deploy-script deploy" 1
[ ! -f "$PAUSED_FILE" ] || fail "resume did not remove the paused file"
expect_history_line '"action": "resume", "result": "accepted".*"user": "bob"'

# ---------------------------------------------------------------------------
start_case "a mode request writes the mode file, in both directions"
request "001-mode.json" '{"request": "mode", "mode": "autonomous", "user": "alice"}'
run_cycle
[ "$(cat "$CHICKADEE_STATE_DIR/mode")" = "autonomous" ] || fail "the mode request did not write the mode file"
expect_history_line '"action": "mode", "result": "accepted", "detail": "autonomous".*"user": "alice"'
request "002-mode.json" '{"request": "mode", "mode": "manual", "user": "alice"}'
request "003-mode.json" '{"request": "mode", "mode": "anything", "user": "alice"}'
touch -t 202601010000 "$REQ/002-mode.json"
run_cycle
[ "$(cat "$CHICKADEE_STATE_DIR/mode")" = "manual" ] || fail "a later invalid mode request changed the mode"
expect_history_line 'mode names no known mode'

# ---------------------------------------------------------------------------
start_case "a host command can still approve any version and persists the pause"
printf '{"command": "pause"}' > "$COMMAND_FILE"
run_cycle
[ -f "$PAUSED_FILE" ] || fail "a host pause was not written to the state folder"
printf '{"command": "mode", "mode": "manual"}' > "$COMMAND_FILE"
run_cycle
[ "$(cat "$CHICKADEE_STATE_DIR/mode")" = "manual" ] || fail "a host mode command did not write the mode file"
printf '{"command": "resume"}' > "$COMMAND_FILE"
run_cycle
expect_state pending_approval
printf '{"command": "approve", "version": "v0.5.232"}' > "$COMMAND_FILE"
run_cycle
expect_calls "deploy-script deploy" 1

# ---------------------------------------------------------------------------
# The pre-release channel (docs/release-gate.md, "Pre-release channel").
# ---------------------------------------------------------------------------
start_case "versions order rc suffixes correctly"
newer() { is_newer "$1" "$2" || fail "expected $1 > $2"; }
not_newer() { ! is_newer "$1" "$2" || fail "expected $1 not > $2"; }
newer v0.7.0-rc.3 0.6.12
newer v0.7.0-rc.10 v0.7.0-rc.9
newer v0.7.0 0.7.0-rc.3
newer v0.7.1 v0.7.0
not_newer v0.7.0-rc.3 0.7.0
not_newer v0.7.0-rc.9 v0.7.0-rc.10
not_newer v0.6.12 0.7.0-rc.1
not_newer v0.7.0-rc.2 0.7.0-rc.2
[ "$(bump_kind v0.7.0-rc.1 0.6.12)" = "minor" ] || fail "an rc of the next minor is not a minor bump"

PRERELEASES_JSON='[{"tag_name": "v0.6.0-rc.2", "prerelease": true},
 {"tag_name": "v0.6.0-rc.10", "prerelease": true},
 {"tag_name": "v0.6.0-rc.9", "prerelease": true},
 {"tag_name": "v0.6.1-rc.1", "prerelease": true, "draft": true},
 {"tag_name": "v0.5.232", "prerelease": false}]'

# ---------------------------------------------------------------------------
start_case "the default channel never deploys a pre-release on its own, however new"
printf '%s' "$PRERELEASES_JSON" > "$STUB/releases_json"
cat > "$STUB/tags" <<JSON
[{"name": "v0.6.0-rc.10", "commit": {"sha": "$RELEASE_SHA"}},
 {"name": "v0.5.232", "commit": {"sha": "$RELEASE_SHA"}}]
JSON
echo "autonomous" > "$CHICKADEE_STATE_DIR/mode"
run_cycle
expect_calls "curl insecure=0 https://api.github.com/repos/.*/releases/latest" 1
expect_calls "deploy-script deploy" 1
[ "$DEPLOYED_VERSION" = "0.5.232" ] || fail "expected 0.5.232 deployed, saw $DEPLOYED_VERSION"
expect_status_field channel releases
[ -z "$(fetch_release_tags | grep -- '-rc\.')" ] || fail "the default channel lists a pre-release tag as a fallback"

# ---------------------------------------------------------------------------
start_case "the prereleases channel deploys the newest pre-release"
printf '%s' "$PRERELEASES_JSON" > "$STUB/releases_json"
echo "prereleases" > "$CHICKADEE_STATE_DIR/channel"
echo "autonomous" > "$CHICKADEE_STATE_DIR/mode"
echo "0.6.0-rc.10" > "$STUB/target_version"
run_cycle
expect_calls "curl insecure=0 https://api.github.com/repos/.*/releases/latest" 0
expect_calls "deploy-script deploy" 1
[ "$DEPLOYED_VERSION" = "0.6.0-rc.10" ] || fail "expected 0.6.0-rc.10 deployed, saw $DEPLOYED_VERSION"
expect_status_field channel prereleases
cat > "$STUB/tags" <<JSON
[{"name": "v0.6.0-rc.9", "commit": {"sha": "a"}},
 {"name": "v0.6.0", "commit": {"sha": "b"}},
 {"name": "v0.6.0-rc.10", "commit": {"sha": "c"}},
 {"name": "v0.5.232", "commit": {"sha": "d"}}]
JSON
[ "$(fetch_release_tags | cut -f1 | tr '\n' ' ')" = "v0.6.0 v0.6.0-rc.10 v0.6.0-rc.9 v0.5.232 " ] \
  || fail "the prereleases channel orders its fallback tags wrongly: $(fetch_release_tags | cut -f1 | tr '\n' ' ')"

# ---------------------------------------------------------------------------
start_case "on the prereleases channel in gated-minors, an rc of the next minor is held"
printf '%s' "$PRERELEASES_JSON" > "$STUB/releases_json"
echo "prereleases" > "$CHICKADEE_STATE_DIR/channel"
run_cycle
expect_calls "deploy-script" 0
expect_state pending_approval
expect_status_field heldVersion v0.6.0-rc.10
request "001-approve.json" '{"request": "approve", "version": "v0.6.0-rc.10", "user": "alice"}'
echo "0.6.0-rc.10" > "$STUB/target_version"
run_cycle
expect_calls "deploy-script deploy" 1

# ---------------------------------------------------------------------------
start_case "a held rc lists its own notes, not every earlier rc"
cat > "$STUB/releases_json" <<'JSON'
[{"tag_name": "v0.6.0-rc.2", "prerelease": true, "body": "- Fragments (#3100)."},
 {"tag_name": "v0.6.0-rc.1", "prerelease": true, "body": "- Fragments (#3100)."},
 {"tag_name": "v0.5.232", "prerelease": false, "body": "- A fix."}]
JSON
echo "prereleases" > "$CHICKADEE_STATE_DIR/channel"
run_cycle
expect_status_field heldVersion v0.6.0-rc.2
python3 - "$PENDING_NOTES_FILE" <<'PY' || fail "the notes of a held rc list other pre-releases"
import json, sys
notes = json.load(open(sys.argv[1]))
assert [r["tag"] for r in notes["releases"]] == ["v0.6.0-rc.2", "v0.5.232"], notes["releases"]
PY

# ---------------------------------------------------------------------------
start_case "the channel is host-only: a request to change it is refused"
request "001-channel.json" '{"request": "channel", "channel": "prereleases", "user": "mallory"}'
run_cycle
[ ! -f "$CHICKADEE_STATE_DIR/channel" ] || fail "a request changed the channel"
expect_history_line 'the release channel is a host setting.*"user": "mallory"'
printf '{"command": "channel", "channel": "prereleases"}' > "$COMMAND_FILE"
run_cycle
[ "$(cat "$CHICKADEE_STATE_DIR/channel")" = "prereleases" ] || fail "a host channel command did not write the channel file"
printf '{"command": "channel", "channel": "nightly"}' > "$COMMAND_FILE"
run_cycle
[ "$(cat "$CHICKADEE_STATE_DIR/channel")" = "prereleases" ] || fail "an unknown channel replaced the channel"

# ---------------------------------------------------------------------------
# The Coming next card: production offers the newest pre-release for an
# explicit approval, and no mode deploys it.
# ---------------------------------------------------------------------------
offer_case() {  # $1 = case name. Production is up to date; rc.10 is newest.
  start_case "$1"
  echo "v0.5.231" > "$STUB/latest_release"
  printf '%s' "$PRERELEASES_JSON" > "$STUB/releases_json"
  echo '{"commits": [{"commit": {"message": "Re-vendor (#3100)"}}]}' > "$STUB/compare_json"
  echo '{"items": [{"number": 3100, "title": "Re-vendor", "html_url": "https://example/pull/3100"}]}' > "$STUB/search_json"
}

offer_case "production offers the newest pre-release with its notes and deploys nothing"
run_cycle
expect_calls "deploy-script" 0
expect_state idle
expect_status_field prereleaseVersion v0.6.0-rc.10
python3 - "$PRERELEASE_NOTES_FILE" <<'PY' || fail "prerelease-notes.json does not carry the offered rc and its minor-release pull request"
import json, sys
notes = json.load(open(sys.argv[1]))
assert notes["heldVersion"] == "v0.6.0-rc.10", notes
assert [p["number"] for p in notes["minorReleasePullRequests"]] == [3100], notes
PY

offer_case "no mode deploys an offered pre-release"
for mode in autonomous gated-minors manual; do
  echo "$mode" > "$CHICKADEE_STATE_DIR/mode"
  run_cycle
done
expect_calls "deploy-script" 0
expect_status_field prereleaseVersion v0.6.0-rc.10

offer_case "an approve request for the offered pre-release deploys exactly it"
run_cycle
request "001-approve.json" '{"request": "approve", "version": "v0.6.0-rc.10", "user": "alice"}'
echo "0.6.0-rc.10" > "$STUB/target_version"
run_cycle
expect_calls "deploy-script deploy" 1
[ "$DEPLOYED_VERSION" = "0.6.0-rc.10" ] || fail "expected 0.6.0-rc.10 deployed, saw $DEPLOYED_VERSION"
expect_history_line '"version": "v0.6.0-rc.10", "action": "approve", "result": "accepted", "detail": "admin page \(pre-release\)".*"user": "alice"'
[ ! -f "$APPROVED_FILE" ] || fail "the approval outlived the deploy"
[ ! -f "$PRERELEASE_NOTES_FILE" ] || fail "prerelease-notes.json outlived the deploy of its rc"

offer_case "an approval of another pre-release than the offered one is refused"
run_cycle
request "001-approve.json" '{"request": "approve", "version": "v0.6.0-rc.9", "user": "mallory"}'
run_cycle
expect_calls "deploy-script" 0
expect_history_line '"version": "v0.6.0-rc.9", "action": "approve", "result": "refused".*"user": "mallory"'

start_case "after an approved pre-release, the minor it leads to waits in gated-minors"
DEPLOYED_VERSION="0.6.0-rc.10"
echo "0.6.0-rc.10" > "$STUB/running_version"
minor_release
run_cycle
expect_calls "deploy-script" 0
expect_state pending_approval
expect_status_field heldVersion v0.6.0
[ "$(bump_kind v0.6.0 0.6.0-rc.10)" = "minor" ] || fail "the minor after a running rc is not a minor bump"
echo "autonomous" > "$CHICKADEE_STATE_DIR/mode"
run_cycle
expect_calls "deploy-script deploy" 1

offer_case "an approval of an rc retires when the minor is cut first"
run_cycle
request "001-approve.json" '{"request": "approve", "version": "v0.6.0-rc.10", "user": "alice"}'
minor_release
run_cycle
expect_calls "deploy-script" 0
expect_status_field heldVersion v0.6.0
[ ! -f "$APPROVED_FILE" ] || fail "the approval of an rc older than the cut minor survived"

offer_case "an approved pre-release whose image never publishes does not hold a patch"
rm "$STUB/image_published"
run_cycle
request "001-approve.json" '{"request": "approve", "version": "v0.6.0-rc.10", "user": "alice"}'
run_cycle
expect_state waiting_for_image
[ "$APPROVED_VERSION" = "v0.6.0-rc.10" ] || fail "the approval of an rc was dropped while its image was built"
echo "v0.5.232" > "$STUB/latest_release"
run_cycle
expect_calls "deploy-script" 0
[ "$APPROVED_VERSION" = "v0.6.0-rc.10" ] || fail "the approval of an rc was dropped before its wait ran out"
FAKE_NOW=$(( FAKE_NOW + 7200 ))
run_cycle
[ -z "$APPROVED_VERSION" ] || fail "the approval of an rc with no image outlived the wait"
[ ! -f "$APPROVED_FILE" ] || fail "approved file outlived the expired rc approval"
expect_history_line '"version": "v0.6.0-rc.10", "action": "approve", "result": "expired"'
expect_calls "deploy-script" 0
touch "$STUB/image_published"
echo "0.5.232" > "$STUB/target_version"
run_cycle
expect_calls "deploy-script deploy" 1
[ "$DEPLOYED_VERSION" = "0.5.232" ] || fail "expected the patch 0.5.232 deployed after the rc approval expired, saw $DEPLOYED_VERSION"
expect_status_field prereleaseVersion v0.6.0-rc.10

offer_case "a disk-low hold does not expire the approval of a pre-release"
rm "$STUB/image_published"
run_cycle
request "001-approve.json" '{"request": "approve", "version": "v0.6.0-rc.10", "user": "alice"}'
run_cycle
FAKE_NOW=$(( FAKE_NOW + 7200 ))
echo $(( 4 * 1024 * 1024 )) > "$STUB/free_kib"
run_cycle
[ "$APPROVED_VERSION" = "v0.6.0-rc.10" ] || fail "a disk-low hold expired the approval of an rc"
expect_state disk_low

offer_case "a failed list keeps the offer; an empty list withdraws it"
run_cycle
expect_status_field prereleaseVersion v0.6.0-rc.10
touch "$STUB/releases_fail"
run_cycle
expect_status_field prereleaseVersion v0.6.0-rc.10
rm "$STUB/releases_fail"
echo '[]' > "$STUB/releases_json"
run_cycle
expect_status_field prereleaseVersion None
[ ! -f "$PRERELEASE_NOTES_FILE" ] || fail "prerelease-notes.json outlived a withdrawn rc"

offer_case "failed pre-release notes are not fetched again every poll"
touch "$STUB/compare_fail"
run_cycle
run_cycle
expect_calls "compare/" 1
FAKE_NOW=$(( FAKE_NOW + 1801 ))
rm "$STUB/compare_fail"
run_cycle
expect_calls "compare/" 2

start_case "on the prereleases channel a running rc does not gate the next rc"
DEPLOYED_VERSION="0.6.0-rc.9"
echo "prereleases" > "$CHICKADEE_STATE_DIR/channel"
printf '%s' "$PRERELEASES_JSON" > "$STUB/releases_json"
echo "0.6.0-rc.10" > "$STUB/target_version"
run_cycle
expect_calls "deploy-script deploy" 1
[ "$(bump_kind v0.6.0-rc.10 0.6.0-rc.9)" = "patch" ] || fail "on prereleases the next rc counts as more than a patch"

# ---------------------------------------------------------------------------
if [ "$FAILURES" -gt 0 ]; then
  printf '%s deployer test failure(s)\n' "$FAILURES"
  exit 1
fi
echo "deployer tests: all cases passed"
