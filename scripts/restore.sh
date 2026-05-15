#!/bin/bash
# restore.sh — Roll a Chickadee deployment back to a snapshot taken by
# scripts/snapshot.sh.
#
# Usage:
#   scripts/restore.sh <snapshot-dir> [flags]
#
# Flags:
#   --yes                  Skip the interactive "type RESTORE" confirmation.
#                          Also required to proceed across a chickadee-version
#                          mismatch between the snapshot and the current code.
#   --regenerate-secrets   Delete /data/.worker-secret after restore so the
#                          server regenerates a fresh runner HMAC secret on
#                          next boot. Use this when copying a prod snapshot
#                          to staging (otherwise staging and prod share a
#                          secret).
#   --scrub-pii            Anonymise user identity columns after restore.
#                          Replaces username/email/display_name/preferred_name/
#                          user_id/student_id/external_subject/brightspace_user_id
#                          on rows with role='student' with deterministic
#                          per-id placeholders. Admin/instructor rows are
#                          preserved. Submission file contents are NOT
#                          scrubbed — see deploy/README.md for the gap list.
#
# Stops server+runner during the restore. The db service keeps running.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE="docker compose -f $REPO_ROOT/docker-compose.yml"
HEALTH_URL="http://localhost:8080/health"

# ----------------------------------------------------------------
# Parse args
# ----------------------------------------------------------------
SNAPSHOT_DIR=""
ASSUME_YES=0
REGEN_SECRETS=0
SCRUB_PII=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)                 ASSUME_YES=1;    shift ;;
    --regenerate-secrets)  REGEN_SECRETS=1; shift ;;
    --scrub-pii)           SCRUB_PII=1;     shift ;;
    -h|--help)
      sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    --*)
      echo "ERROR: unknown flag: $1" >&2
      exit 2
      ;;
    *)
      if [[ -z "$SNAPSHOT_DIR" ]]; then
        SNAPSHOT_DIR="$1"
      else
        echo "ERROR: unexpected argument: $1" >&2
        exit 2
      fi
      shift
      ;;
  esac
done

if [[ -z "$SNAPSHOT_DIR" ]]; then
  echo "Usage: $0 <snapshot-dir> [--yes] [--regenerate-secrets] [--scrub-pii]" >&2
  exit 2
fi

# Normalise to an absolute path so the docker run mounts work even if the
# user gave a relative path.
if [[ "$SNAPSHOT_DIR" != /* ]]; then
  SNAPSHOT_DIR="$REPO_ROOT/$SNAPSHOT_DIR"
fi
SNAPSHOT_DIR="$(cd "$SNAPSHOT_DIR" 2>/dev/null && pwd || echo "$SNAPSHOT_DIR")"

if [[ ! -d "$SNAPSHOT_DIR" ]]; then
  echo "ERROR: not a directory: $SNAPSHOT_DIR" >&2
  exit 1
fi

# ----------------------------------------------------------------
# Validate snapshot
# ----------------------------------------------------------------
MANIFEST="$SNAPSHOT_DIR/manifest.json"
DUMP="$SNAPSHOT_DIR/postgres.dump"
TARBALL="$SNAPSHOT_DIR/data.tar.gz"

for f in "$MANIFEST" "$DUMP" "$TARBALL"; do
  if [[ ! -f "$f" ]]; then
    echo "ERROR: snapshot is incomplete (missing $f)." >&2
    echo "       Refusing to restore from a partial snapshot." >&2
    exit 1
  fi
done

# Pull fields from manifest with python (always present on prod hosts)
MANIFEST_VERSION="$(python3 -c "import json; print(json.load(open('$MANIFEST')).get('chickadee_version',''))")"
MANIFEST_LABEL="$(python3 -c "import json; print(json.load(open('$MANIFEST')).get('label',''))")"
MANIFEST_TS="$(python3 -c "import json; print(json.load(open('$MANIFEST')).get('timestamp',''))")"
MANIFEST_DB_BYTES="$(python3 -c "import json; print(json.load(open('$MANIFEST')).get('db_size_bytes',0))")"
MANIFEST_DATA_BYTES="$(python3 -c "import json; print(json.load(open('$MANIFEST')).get('data_size_bytes',0))")"

CURRENT_VERSION="$(cat "$REPO_ROOT/VERSION" 2>/dev/null | tr -d '[:space:]')"

# ----------------------------------------------------------------
# Load .env so DATABASE_* vars are visible
# ----------------------------------------------------------------
if [[ -f "$REPO_ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$REPO_ROOT/.env"
  set +a
fi

DATABASE_BACKEND="${DATABASE_BACKEND:-sqlite}"
if [[ "$DATABASE_BACKEND" != "postgres" ]]; then
  echo "ERROR: restore.sh only supports DATABASE_BACKEND=postgres (got: $DATABASE_BACKEND)." >&2
  exit 1
fi
: "${DATABASE_USER:?DATABASE_USER must be set in .env}"
: "${DATABASE_NAME:?DATABASE_NAME must be set in .env}"

# Resolve volume name (same logic as snapshot.sh)
DATA_VOLUME="$($COMPOSE config --format json 2>/dev/null \
  | python3 -c 'import json,sys; cfg=json.load(sys.stdin); print(cfg["volumes"]["chickadee-data"]["name"])' 2>/dev/null \
  || true)"
if [[ -z "$DATA_VOLUME" ]]; then
  DATA_VOLUME="chickadee_chickadee-data"
fi

# ----------------------------------------------------------------
# Confirmation prompt
# ----------------------------------------------------------------
HUMAN_DB="$(python3 -c "print(f'{$MANIFEST_DB_BYTES/1024/1024:.1f} MB')")"
HUMAN_DATA="$(python3 -c "print(f'{$MANIFEST_DATA_BYTES/1024/1024:.1f} MB')")"

cat <<EOF

================================================================
  Chickadee restore
================================================================
  Snapshot dir:      $SNAPSHOT_DIR
  Taken at:          $MANIFEST_TS
  Label:             $MANIFEST_LABEL
  Snapshot version:  $MANIFEST_VERSION
  Current version:   $CURRENT_VERSION
  postgres.dump:     $HUMAN_DB
  data.tar.gz:       $HUMAN_DATA
  Database:          $DATABASE_NAME (on docker service 'db')
  Data volume:       $DATA_VOLUME
  Regenerate secret: $([[ $REGEN_SECRETS == 1 ]] && echo YES || echo no)
  Scrub PII:         $([[ $SCRUB_PII == 1 ]] && echo YES || echo no)

This will:
  1. Stop the server and runner containers.
  2. Drop and reload every object in the '$DATABASE_NAME' database.
  3. Wipe testsetups/, submissions/, results/, .worker-secret, and
     .local-runner-autostart inside the data volume, then untar the
     snapshot contents back in.
  4. Restart the server and runner containers.

EOF

if [[ "$MANIFEST_VERSION" != "$CURRENT_VERSION" ]]; then
  cat <<EOF
WARNING: snapshot was taken at chickadee $MANIFEST_VERSION but the current
         code is $CURRENT_VERSION. Fluent migrations will run on startup
         after restore. If any migration between those versions is
         destructive (drops columns/tables), this is NOT safe to roll
         forward through.
EOF
  if [[ $ASSUME_YES -ne 1 ]]; then
    echo "         Pass --yes to proceed across a version mismatch." >&2
    exit 1
  fi
fi

if [[ $ASSUME_YES -ne 1 ]]; then
  read -r -p "Type RESTORE to proceed: " CONFIRM
  if [[ "$CONFIRM" != "RESTORE" ]]; then
    echo "Aborted." >&2
    exit 1
  fi
fi

# ----------------------------------------------------------------
# 1. Stop server + runner (leave db running)
# ----------------------------------------------------------------
echo "==> Stopping server and runner ..."
$COMPOSE stop server runner

# ----------------------------------------------------------------
# 2. pg_restore --clean
# ----------------------------------------------------------------
echo "==> Restoring Postgres from $DUMP ..."
# Use --no-owner so role differences between hosts don't trip the restore.
# --clean --if-exists drops every object before reloading.
# pg_restore can emit non-fatal warnings while doing this; tolerate exit 1
# only when stderr is warnings (we don't enforce that here — just log).
$COMPOSE exec -T db pg_restore --clean --if-exists --no-owner \
  -U "$DATABASE_USER" -d "$DATABASE_NAME" < "$DUMP" || {
    rc=$?
    if [[ $rc -gt 1 ]]; then
      echo "ERROR: pg_restore failed with exit $rc" >&2
      exit $rc
    fi
    echo "    pg_restore exited with warnings (exit 1) — continuing."
  }

# ----------------------------------------------------------------
# 3. Wipe artifact dirs and untar the snapshot back in
# ----------------------------------------------------------------
echo "==> Replacing artifact dirs in $DATA_VOLUME ..."
docker run --rm \
  -v "$DATA_VOLUME":/data \
  -v "$SNAPSHOT_DIR":/snap:ro \
  ubuntu:22.04 \
  sh -c 'set -e; rm -rf /data/testsetups /data/submissions /data/results /data/.worker-secret /data/.local-runner-autostart; tar xzf /snap/data.tar.gz -C /data'

# ----------------------------------------------------------------
# 4. Optional: regenerate worker secret
# ----------------------------------------------------------------
if [[ $REGEN_SECRETS -eq 1 ]]; then
  echo "==> Removing .worker-secret (server will regenerate on next boot) ..."
  docker run --rm -v "$DATA_VOLUME":/data ubuntu:22.04 \
    sh -c 'rm -f /data/.worker-secret'
  echo "    NOTE: any running runner containers will need to be restarted"
  echo "          after the server boots and writes the new secret."
fi

# ----------------------------------------------------------------
# 5. Optional: scrub PII on student rows
# ----------------------------------------------------------------
if [[ $SCRUB_PII -eq 1 ]]; then
  echo "==> Scrubbing PII on student rows ..."
  echo "    (admin/instructor rows preserved; submission contents NOT scrubbed.)"
  $COMPOSE exec -T db psql -U "$DATABASE_USER" -d "$DATABASE_NAME" -v ON_ERROR_STOP=1 <<'SQL'
-- Scrub identity columns on student rows only.
-- Uses substring(md5(id::text), 1, 12) for deterministic placeholders so the
-- same prod row always yields the same staging value (useful for debugging).
BEGIN;
UPDATE users SET
    username            = 'student-' || substring(md5(id::text), 1, 12),
    email               = 'student-' || substring(md5(id::text), 1, 12) || '@example.invalid',
    display_name        = 'Student ' || substring(md5(id::text), 1, 8),
    preferred_name      = NULL,
    user_id             = 'scrubbed-' || substring(md5(id::text), 1, 12),
    student_id          = NULL,
    external_subject    = NULL,
    brightspace_user_id = NULL
WHERE role = 'student';
COMMIT;
SQL
  echo "    Scrub complete."
fi

# ----------------------------------------------------------------
# 6. Restart server + runner
# ----------------------------------------------------------------
echo "==> Restarting server and runner ..."
$COMPOSE up -d server runner

# ----------------------------------------------------------------
# 7. Wait for health
# ----------------------------------------------------------------
echo "==> Waiting for server to become healthy ..."
ATTEMPTS=0
MAX_ATTEMPTS=20
until curl -sf "$HEALTH_URL" > /dev/null 2>&1; do
  ATTEMPTS=$((ATTEMPTS + 1))
  if [[ $ATTEMPTS -ge $MAX_ATTEMPTS ]]; then
    echo "ERROR: Server did not become healthy after $MAX_ATTEMPTS attempts." >&2
    echo "       Check logs with: docker compose logs server" >&2
    exit 1
  fi
  sleep 3
done

echo ""
echo "==> Restore complete."
