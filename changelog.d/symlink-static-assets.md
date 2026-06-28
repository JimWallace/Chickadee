### Changed

- **Docker deploys symlink static assets instead of copying them on every boot.**
  The container entrypoint previously `rm -rf`'d and re-copied `Public/`,
  `Resources/`, and `docs/` (~586 MB, most of it the vendored Pyodide) from the
  image into the data volume on every start — the single biggest contributor to
  the visible service gap on redeploy. It now symlinks those read-only asset
  trees at the image copies, so the link refresh is effectively free and a
  redeploy still picks up fresh templates/assets instantly. Because each symlink
  resolves inside its own container, two image versions can share the data volume
  safely — a prerequisite for the planned zero-downtime blue-green deploys. The
  stale real copies are reclaimed automatically on first boot of the new image.
