#!/bin/bash
# server-deploy.sh — Pull the latest Chickadee image and restart services.
#
# Run this on the production server whenever you want to apply an update:
#   scripts/server-deploy.sh
#
# To deploy a specific image (e.g., for rollback):
#   CHICKADEE_IMAGE=ghcr.io/jimwallace/chickadee:sha-abc1234 scripts/server-deploy.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE="docker compose -f $REPO_ROOT/docker-compose.yml"
HEALTH_URL="http://localhost:8080/health"
BACKUP_DIR="$REPO_ROOT/backups"

# ----------------------------------------------------------------
# Optional image override (e.g. for rollback to a specific sha tag)
# ----------------------------------------------------------------
if [[ -n "${CHICKADEE_IMAGE:-}" ]]; then
  echo "==> Overriding image to: $CHICKADEE_IMAGE"
  export CHICKADEE_IMAGE
  # Rewrite compose to use the override — simplest approach is a temp override file
  OVERRIDE_FILE="$(mktemp /tmp/chickadee-override-XXXXXX.yml)"
  cat > "$OVERRIDE_FILE" <<EOF
services:
  server:
    image: $CHICKADEE_IMAGE
  runner:
    image: $CHICKADEE_IMAGE
EOF
  COMPOSE="$COMPOSE -f $OVERRIDE_FILE"
  trap 'rm -f "$OVERRIDE_FILE"' EXIT
fi

# ----------------------------------------------------------------
# 1. Back up the database
# ----------------------------------------------------------------
mkdir -p "$BACKUP_DIR"
BACKUP_FILE="$BACKUP_DIR/chickadee-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
echo "==> Backing up data volume to $BACKUP_FILE ..."
docker run --rm \
  -v chickadee_chickadee-data:/data \
  -v "$BACKUP_DIR":/backup \
  ubuntu \
  tar czf "/backup/$(basename "$BACKUP_FILE")" -C /data .
echo "    Backup complete."

# Prune backups older than 14 days
find "$BACKUP_DIR" -name "chickadee-backup-*.tar.gz" -mtime +14 -delete

# ----------------------------------------------------------------
# 2. Pull the new image
# ----------------------------------------------------------------
echo "==> Pulling latest images..."
$COMPOSE pull

# ----------------------------------------------------------------
# 3. Restart services (Compose handles stop → start in dependency order)
# ----------------------------------------------------------------
echo "==> Restarting services..."
$COMPOSE up -d

# ----------------------------------------------------------------
# 4. Wait for the health check to pass
# ----------------------------------------------------------------
echo "==> Waiting for server to become healthy..."
ATTEMPTS=0
MAX_ATTEMPTS=20
until curl -sf "$HEALTH_URL" > /dev/null 2>&1; do
  ATTEMPTS=$((ATTEMPTS + 1))
  if [[ $ATTEMPTS -ge $MAX_ATTEMPTS ]]; then
    echo "ERROR: Server did not become healthy after $MAX_ATTEMPTS attempts."
    echo "       Check logs with: docker compose logs server"
    exit 1
  fi
  sleep 3
done

echo ""
echo "==> Health check passed:"
curl -sf "$HEALTH_URL" | python3 -m json.tool 2>/dev/null || curl -sf "$HEALTH_URL"
echo ""
echo "==> Deploy complete."
