#!/usr/bin/env bash
set -uo pipefail

# Behaviour tests for scripts/lib/snapshot-retention.sh.
#
# On 2026-10-07 the predeploy snapshots filled the production disk: one full
# copy per release, kept for 7 days, with 25 releases in one day. Each case
# builds a backups/ directory of empty snapshot directories, prunes it, and
# asserts which ones remain.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# shellcheck source=lib/snapshot-retention.sh
. "$REPO_ROOT/scripts/lib/snapshot-retention.sh"

FAILURES=0
CASE=""
DIR=""

fail() {
  printf 'FAIL [%s]: %s\n' "$CASE" "$1"
  FAILURES=$(( FAILURES + 1 ))
}

start_case() {
  CASE="$1"
  DIR="$WORK/backups"
  rm -rf "$DIR"
  mkdir -p "$DIR"
}

make_snapshot() {  # $1 = name, $2 = optional age in days
  mkdir -p "$DIR/$1"
  if [ -n "${2:-}" ]; then
    touch -d "$2 days ago" "$DIR/$1"
  fi
}

expect_kept() {
  [ -d "$DIR/$1" ] || fail "expected $1 to be kept"
}

expect_pruned() {
  [ ! -e "$DIR/$1" ] || fail "expected $1 to be pruned"
}

# ---------------------------------------------------------------------------
start_case "only the newest predeploy snapshots are kept"
for v in 520 521 522 523 524 525; do
  make_snapshot "snapshot-20261006-1${v}00-predeploy-0.5.$v"
done
out="$(prune_snapshots "$DIR" 3 7)"
expect_kept "snapshot-20261006-152500-predeploy-0.5.525"
expect_kept "snapshot-20261006-152400-predeploy-0.5.524"
expect_kept "snapshot-20261006-152300-predeploy-0.5.523"
expect_pruned "snapshot-20261006-152200-predeploy-0.5.522"
expect_pruned "snapshot-20261006-152100-predeploy-0.5.521"
expect_pruned "snapshot-20261006-152000-predeploy-0.5.520"
[ "$(printf '%s\n' "$out" | grep -c .)" = "3" ] || fail "expected three printed paths, saw: $out"

# ---------------------------------------------------------------------------
start_case "scheduled and manual snapshots are not counted"
make_snapshot "snapshot-20261001-030000-scheduled"
make_snapshot "snapshot-20261002-030000-scheduled"
make_snapshot "snapshot-20261002-120000-pre-appscan"
make_snapshot "snapshot-20261006-150000-predeploy-0.5.520"
make_snapshot "snapshot-20261006-160000-predeploy-0.5.521"
prune_snapshots "$DIR" 1 7 >/dev/null
expect_kept "snapshot-20261001-030000-scheduled"
expect_kept "snapshot-20261002-030000-scheduled"
expect_kept "snapshot-20261002-120000-pre-appscan"
expect_kept "snapshot-20261006-160000-predeploy-0.5.521"
expect_pruned "snapshot-20261006-150000-predeploy-0.5.520"

# ---------------------------------------------------------------------------
start_case "a snapshot of any label older than the retention days is pruned"
make_snapshot "snapshot-20260920-030000-scheduled" 10
make_snapshot "snapshot-20260920-120000-pre-appscan" 10
make_snapshot "snapshot-20261006-030000-scheduled" 1
prune_snapshots "$DIR" 3 7 >/dev/null
expect_pruned "snapshot-20260920-030000-scheduled"
expect_pruned "snapshot-20260920-120000-pre-appscan"
expect_kept "snapshot-20261006-030000-scheduled"

# ---------------------------------------------------------------------------
start_case "fewer predeploy snapshots than the limit are all kept"
make_snapshot "snapshot-20261006-150000-predeploy-0.5.520"
make_snapshot "snapshot-20261006-160000-predeploy-0.5.521"
out="$(prune_snapshots "$DIR" 3 7)"
expect_kept "snapshot-20261006-150000-predeploy-0.5.520"
expect_kept "snapshot-20261006-160000-predeploy-0.5.521"
[ -z "$out" ] || fail "expected nothing printed, saw: $out"

# ---------------------------------------------------------------------------
start_case "files and other directories in backups are not touched"
make_snapshot "snapshot-20261006-150000-predeploy-0.5.520"
make_snapshot "snapshot-20261006-160000-predeploy-0.5.521"
mkdir -p "$DIR/restore-staging"
touch "$DIR/snapshot-20261006-140000-predeploy-0.5.519.tar"
prune_snapshots "$DIR" 1 7 >/dev/null
[ -d "$DIR/restore-staging" ] || fail "a directory that is not a snapshot was removed"
[ -f "$DIR/snapshot-20261006-140000-predeploy-0.5.519.tar" ] || fail "a file was removed"
expect_pruned "snapshot-20261006-150000-predeploy-0.5.520"

# ---------------------------------------------------------------------------
start_case "a missing backups directory is not an error"
rm -rf "$DIR"
prune_snapshots "$DIR" 3 7 >/dev/null || fail "prune_snapshots failed on a missing directory"

# ---------------------------------------------------------------------------
if [ "$FAILURES" -gt 0 ]; then
  printf '%s snapshot retention test failure(s)\n' "$FAILURES"
  exit 1
fi
echo "snapshot retention tests: all cases passed"
