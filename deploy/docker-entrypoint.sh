#!/bin/sh
# docker-entrypoint.sh — Chickadee server startup script
#
# On every container start this script:
#   1. Links Public/, Resources/, and docs/ from the image into the persistent
#      data volume, so each new image deployment picks up fresh templates and
#      JupyterLite assets without needing to re-mount the volume.
#   2. Starts chickadee-server with the data volume as its working directory.
#
# Environment variables:
#   DATA_DIR  — path to the persistent data volume (default: /data)

set -e

DATA_DIR="${DATA_DIR:-/data}"

echo "[entrypoint] Linking static assets into ${DATA_DIR} ..."
mkdir -p "${DATA_DIR}"

# Static assets (Public/, Resources/, docs/) are read-only at runtime and ship
# inside the image at /app.  We used to `rm -rf` + `cp -r` them into the data
# volume on every boot, but that re-copied ~586 MB (the vendored Pyodide alone
# is ~510 MB) across filesystems on each restart and dominated startup time —
# the single biggest contributor to the visible service gap on redeploy.
#
# Instead we symlink the data-volume paths at the image copies.  The server's
# working directory is ${DATA_DIR}, so it still finds Public/, Resources/, and
# docs/ there; the kernel resolves the symlinks to *this* image's /app, so a
# redeploy picks up fresh templates/assets instantly (and the link refresh is
# effectively free).  Because each symlink resolves inside its own container,
# two different image versions can share ${DATA_DIR} safely — a prerequisite
# for zero-downtime blue-green deploys.  docs/ feeds the MCP authoring-guide
# resources (MCPResourceProvider).
for asset in Public Resources docs; do
    link="${DATA_DIR}/${asset}"
    # Drop any leftover real copy from pre-symlink deploys (reclaims volume
    # space on first boot of this image), or a stale symlink, then point at
    # this image's copy.  `rm` on a symlink removes only the link itself,
    # never the /app target it points to.
    rm -rf "${link}"
    ln -s "/app/${asset}" "${link}"
done

echo "[entrypoint] Starting chickadee-server ..."
cd "${DATA_DIR}"
exec /app/chickadee-server serve \
    --env production \
    --hostname 0.0.0.0 \
    --port 8080 \
    "$@"
