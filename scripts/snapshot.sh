#!/bin/bash
# snapshot.sh — Take a Postgres + on-disk-artifact snapshot of a running
# Chickadee deployment.
#
# Usage:
#   scripts/snapshot.sh                       # label defaults to "manual"
#   scripts/snapshot.sh --label pre-appscan   # any short identifier
#
# Produces:
#   backups/snapshot-<YYYYMMDD-HHMMSS>[-<label>]/
#     ├── postgres.dump   (pg_dump -Fc custom format)
#     ├── data.tar.gz     (testsetups/, submissions/, results/, .worker-secret,
#     │                    .local-runner-autostart from the chickadee-data volume)
#     └── manifest.json   (written last; its presence means snapshot is complete)
#
# Pairs with scripts/restore.sh for rollback.
#
# Requires the docker-compose stack to be running and DATABASE_BACKEND=postgres.
# SQLite deployments are already covered by scripts/server-deploy.sh's volume tar.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE="docker compose -f $REPO_ROOT/docker-compose.yml"
BACKUP_DIR="$REPO_ROOT/backups"
RETENTION_DAYS=7

# ----------------------------------------------------------------
# Parse args
# ----------------------------------------------------------------
LABEL="manual"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --label)
      LABEL="${2:?--label requires a value}"
      shift 2
      ;;
    -h|--help)
      sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# Label sanity check — keep filenames boring
if [[ ! "$LABEL" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ERROR: --label must match [A-Za-z0-9._-]+ (got: $LABEL)" >&2
  exit 2
fi

# ----------------------------------------------------------------
# Read DATABASE_* from the live server container.
# This is authoritative — it covers every place compose looks
# (.env, docker-compose.override.yml, exported shell env, etc.).
# Fall back to .env only if the server isn't running yet.
# ----------------------------------------------------------------
DB_VARS_FROM_CONTAINER=0
while IFS='=' read -r k v; do
  case "$k" in
    DATABASE_*) export "$k=$v"; DB_VARS_FROM_CONTAINER=1 ;;
  esac
done < <($COMPOSE exec -T server env 2>/dev/null || true)

if [[ $DB_VARS_FROM_CONTAINER -eq 0 && -f "$REPO_ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$REPO_ROOT/.env"
  set +a
fi

DATABASE_BACKEND="${DATABASE_BACKEND:-sqlite}"
if [[ "$DATABASE_BACKEND" != "postgres" ]]; then
  cat >&2 <<EOF
ERROR: snapshot.sh only supports DATABASE_BACKEND=postgres.
       Current value: "$DATABASE_BACKEND".

       SQLite deployments are already covered by scripts/server-deploy.sh,
       which tars the chickadee-data volume (including chickadee.sqlite)
       before every deploy.
EOF
  exit 1
fi

: "${DATABASE_USER:?DATABASE_USER must be set (in server container env or .env)}"
: "${DATABASE_NAME:?DATABASE_NAME must be set (in server container env or .env)}"

# ----------------------------------------------------------------
# Verify db service is healthy
# ----------------------------------------------------------------
if ! $COMPOSE ps db >/dev/null 2>&1; then
  echo "ERROR: docker-compose 'db' service not found. Is the stack running?" >&2
  exit 1
fi
if ! $COMPOSE exec -T db pg_isready -U "$DATABASE_USER" -d "$DATABASE_NAME" >/dev/null 2>&1; then
  echo "ERROR: db service is not accepting connections (pg_isready failed)." >&2
  exit 1
fi

# ----------------------------------------------------------------
# Resolve the data volume name (docker-compose prefixes it with the project name)
# ----------------------------------------------------------------
DATA_VOLUME="$($COMPOSE config --format json 2>/dev/null \
  | python3 -c 'import json,sys; cfg=json.load(sys.stdin); print(cfg["volumes"]["chickadee-data"]["name"])' 2>/dev/null \
  || true)"
if [[ -z "$DATA_VOLUME" ]]; then
  # Fall back to the conventional name produced by the existing deploy script
  DATA_VOLUME="chickadee_chickadee-data"
fi
if ! docker volume inspect "$DATA_VOLUME" >/dev/null 2>&1; then
  echo "ERROR: docker volume '$DATA_VOLUME' not found." >&2
  exit 1
fi

# ----------------------------------------------------------------
# Create the snapshot directory
# ----------------------------------------------------------------
TS="$(date +%Y%m%d-%H%M%S)"
DIR="$BACKUP_DIR/snapshot-$TS-$LABEL"
mkdir -p "$DIR"
echo "==> Snapshot directory: $DIR"

# Clean up the directory if any step below fails (no half-snapshots in backups/)
trap 'if [[ -z "${SNAPSHOT_COMPLETE:-}" ]]; then echo "!! snapshot failed; cleaning $DIR" >&2; rm -rf "$DIR"; fi' EXIT

# ----------------------------------------------------------------
# 1. pg_dump
# ----------------------------------------------------------------
echo "==> Dumping Postgres database '$DATABASE_NAME' ..."
$COMPOSE exec -T db pg_dump -Fc -U "$DATABASE_USER" "$DATABASE_NAME" > "$DIR/postgres.dump"
DB_BYTES="$(wc -c < "$DIR/postgres.dump" | tr -d ' ')"
echo "    Wrote $DB_BYTES bytes."

# ----------------------------------------------------------------
# 2. tar of artifact dirs from the data volume
# ----------------------------------------------------------------
echo "==> Archiving data volume artifacts ..."
docker run --rm \
  -v "$DATA_VOLUME":/data:ro \
  -v "$DIR":/snap \
  ubuntu:22.04 \
  sh -c 'set -e; paths=""; for p in testsetups submissions results .worker-secret .local-runner-autostart; do [ -e "/data/$p" ] && paths="$paths $p"; done; if [ -z "$paths" ]; then echo "WARN: no artifact paths found in /data" >&2; tar czf /snap/data.tar.gz -T /dev/null; else cd /data && tar czf /snap/data.tar.gz $paths; fi'
DATA_BYTES="$(wc -c < "$DIR/data.tar.gz" | tr -d ' ')"
echo "    Wrote $DATA_BYTES bytes."

# ----------------------------------------------------------------
# 3. manifest.json (written last — its presence signals completion)
# ----------------------------------------------------------------
VERSION_STR="$(cat "$REPO_ROOT/VERSION" 2>/dev/null | tr -d '[:space:]')"
HOST_STR="$(hostname)"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$DIR/manifest.json" <<EOF
{
  "timestamp": "$NOW_ISO",
  "chickadee_version": "$VERSION_STR",
  "label": "$LABEL",
  "db_size_bytes": $DB_BYTES,
  "data_size_bytes": $DATA_BYTES,
  "source_host": "$HOST_STR",
  "data_volume": "$DATA_VOLUME",
  "database_name": "$DATABASE_NAME"
}
EOF

SNAPSHOT_COMPLETE=1
echo "==> Snapshot complete: $DIR"

# ----------------------------------------------------------------
# 4. Prune old snapshots
# ----------------------------------------------------------------
if [[ -d "$BACKUP_DIR" ]]; then
  PRUNED="$(find "$BACKUP_DIR" -maxdepth 1 -type d -name "snapshot-*" -mtime "+$RETENTION_DAYS" -print -exec rm -rf {} + 2>/dev/null || true)"
  if [[ -n "$PRUNED" ]]; then
    echo "==> Pruned snapshots older than $RETENTION_DAYS days:"
    echo "$PRUNED" | sed 's/^/    /'
  fi
fi

echo "==> Done."
