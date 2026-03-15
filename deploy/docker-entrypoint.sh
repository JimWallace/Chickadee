#!/bin/sh
# docker-entrypoint.sh — Chickadee server startup script
#
# On every container start this script:
#   1. Syncs Public/ and Resources/ from the image into the persistent data
#      volume, so each new image deployment picks up fresh templates and
#      JupyterLite assets without needing to re-mount the volume.
#   2. Starts chickadee-server with the data volume as its working directory.
#
# Environment variables:
#   DATA_DIR  — path to the persistent data volume (default: /data)

set -e

DATA_DIR="${DATA_DIR:-/data}"

echo "[entrypoint] Syncing static assets to ${DATA_DIR} ..."
mkdir -p "${DATA_DIR}"

# Replace Public/ and Resources/ on every start so deploys are always fresh.
rm -rf "${DATA_DIR}/Public" "${DATA_DIR}/Resources"
cp -r /app/Public    "${DATA_DIR}/Public"
cp -r /app/Resources "${DATA_DIR}/Resources"

echo "[entrypoint] Starting chickadee-server ..."
exec /app/chickadee-server serve \
    --env production \
    --hostname 0.0.0.0 \
    --port 8080 \
    --working-directory "${DATA_DIR}/" \
    "$@"
