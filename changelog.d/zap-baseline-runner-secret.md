### Fixed

- **The weekly ZAP baseline scan runs again.** Making `RUNNER_SHARED_SECRET` a
  required Compose variable (so the runner container, which no longer mounts the
  data volume, could still learn it) left the ZAP workflow's CI `.env` short one
  value, and `docker compose up` refused to interpolate. The scan had not
  started since the change.
- **The CI Compose fixture is derived from `docker-compose.yml`, not hand-kept.**
  `scripts/ci-compose-env.sh` writes the scan's `.env` from the required
  `${VAR:?}` interpolations it finds, and the `format-lint` job runs it with
  `--check` so a newly required variable fails on the PR that introduces it.
  Previously the only signal was the weekly scan going red, which is how this
  one stayed broken for two weeks. An unrecognised requirement is a loud failure
  rather than an auto-generated value, so nothing silently boots misconfigured.
