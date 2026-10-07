#!/usr/bin/env bash
# snapshot-retention.sh — decide which snapshots in backups/ to delete.
# Sourced by snapshot.sh and its tests; not executable on its own.
#
# Every snapshot is a full copy: a pg_dump of the database and a tar of every
# test setup, submission and result. The old rule deleted snapshots by age
# only (older than 7 days). That was right for one nightly snapshot, which
# gives 7 copies. But the deployer takes a "predeploy" snapshot before every
# release, and auto-release can ship 25 releases in one day. On 2026-10-07 the
# copies filled the disk, Postgres stopped, and login and both MCP surfaces
# failed with it.
#
# So there are two rules:
#   1. Any snapshot older than RETENTION_DAYS is deleted (as before).
#   2. Only the newest KEEP_PREDEPLOY predeploy snapshots are kept. Scheduled
#      and manual snapshots are not counted, so an operator's labelled
#      snapshot (pre-appscan, for example) is never deleted to make room.
#
# A snapshot directory is named snapshot-<YYYYMMDD-HHMMSS>-<label>, so a sort
# by name is a sort by time.

# prune_snapshots DIR KEEP_PREDEPLOY RETENTION_DAYS
# Deletes what the two rules allow, and prints each deleted path.
prune_snapshots() {
  local dir="$1" keep="$2" days="$3" surplus path
  [ -d "$dir" ] || return 0

  find "$dir" -maxdepth 1 -type d -name 'snapshot-*' -mtime "+$days" -print \
    -exec rm -rf {} + 2>/dev/null || true

  surplus="$(find "$dir" -maxdepth 1 -type d -name 'snapshot-*-predeploy-*' -print \
    | sort -r | tail -n "+$(( keep + 1 ))")"
  [ -n "$surplus" ] || return 0
  while IFS= read -r path; do
    rm -rf -- "$path"
    printf '%s\n' "$path"
  done <<< "$surplus"
}
