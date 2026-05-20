#!/bin/bash
# restore-from-share.sh — Pull the latest Chickadee snapshot from the shared
# mount and restore it into THIS deployment.
#
# Intended for a non-production (dev/staging) box that should track production
# data, run unattended from cron. It does NOT take its own snapshots — it only
# consumes snapshots produced by the production host and rsync'd to the share.
#
# Safe to run unattended:
#   - skips cleanly if the share isn't mounted (exit 0)
#   - only restores a *complete* snapshot (manifest.json is written last)
#   - skips if the newest snapshot was already restored (no nightly DB churn)
#
# Pairs with scripts/snapshot.sh (producer) and scripts/restore.sh (engine).
# Requires the docker-compose stack (incl. the db service) to be running and
# DATABASE_BACKEND=postgres.

set -euo pipefail

# Where the production host rsync's its snapshots. Defaults to the UWaterloo AHS
# home share; override for other deployments.
SHARE_MOUNT="${CHICKADEE_SNAPSHOT_SHARE_MOUNT:-/mnt/ahsfile-home}"
SHARE_DIR="${CHICKADEE_SNAPSHOT_SHARE_DIR:-$SHARE_MOUNT/chickadee-backups}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCAL_BACKUPS="$REPO_ROOT/backups"
MARKER="$LOCAL_BACKUPS/.last-restored"

# Anonymise student PII after each restore? Recommended for any non-prod box
# that holds real student data (FIPPA/PIPEDA). Set CHICKADEE_RESTORE_SCRUB_PII=1
# to enable. Leave 0 if you need real identities to reproduce issues.
# Admin/instructor rows and submission file contents are NOT scrubbed — see
# deploy/README.md.
SCRUB_PII="${CHICKADEE_RESTORE_SCRUB_PII:-0}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S'): $*"; }

# 1. Require the share to be mounted.
if ! mountpoint -q "$SHARE_MOUNT"; then
  log "SKIP — $SHARE_MOUNT not mounted"
  exit 0
fi
if [[ ! -d "$SHARE_DIR" ]]; then
  log "SKIP — $SHARE_DIR not present on the share"
  exit 0
fi

# 2. Mirror the share's snapshots down to local disk. Restoring from local disk
#    keeps the critical DB drop/reload window independent of an NFS stall.
mkdir -p "$LOCAL_BACKUPS"
log "Pulling snapshots from $SHARE_DIR ..."
rsync -a --delete --exclude='.last-restored' "$SHARE_DIR/" "$LOCAL_BACKUPS/"

# 3. Find the newest *complete* snapshot. Names are snapshot-YYYYMMDD-HHMMSS-*,
#    so a lexical sort is chronological; keep the last one that has all parts.
NEWEST=""
for d in $(ls -d "$LOCAL_BACKUPS"/snapshot-*/ 2>/dev/null | sort); do
  if [[ -f "$d/manifest.json" && -f "$d/postgres.dump" && -f "$d/data.tar.gz" ]]; then
    NEWEST="${d%/}"
  fi
done
if [[ -z "$NEWEST" ]]; then
  log "SKIP — no complete snapshot found under $LOCAL_BACKUPS"
  exit 0
fi

# 4. Skip if we already restored this snapshot.
if [[ -f "$MARKER" && "$(cat "$MARKER")" == "$NEWEST" ]]; then
  log "SKIP — already current: $(basename "$NEWEST")"
  exit 0
fi

# 5. Restore.
log "Restoring $(basename "$NEWEST") ..."
RESTORE_FLAGS=(--yes --regenerate-secrets)
[[ "$SCRUB_PII" == "1" ]] && RESTORE_FLAGS+=(--scrub-pii)

if "$REPO_ROOT/scripts/restore.sh" "$NEWEST" "${RESTORE_FLAGS[@]}"; then
  echo "$NEWEST" > "$MARKER"
  log "Restore complete: $(basename "$NEWEST")"
else
  rc=$?
  log "ERROR — restore.sh exited $rc"
  exit "$rc"
fi
