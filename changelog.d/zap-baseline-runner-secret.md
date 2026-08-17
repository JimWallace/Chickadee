### Fixed

- **The weekly ZAP baseline scan runs again.** Making `RUNNER_SHARED_SECRET` a
  required Compose variable (so the runner container, which no longer mounts the
  data volume, could still learn it) left the ZAP workflow's CI `.env` short one
  value, and `docker compose up` refused to interpolate. The scan had not
  started since the change; the workflow now generates an ephemeral secret.
