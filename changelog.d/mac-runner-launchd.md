### Changed

- **The Mac runner runbook schedules updates with launchd, not cron.** On
  macOS, installing a crontab waits for a permission dialog that an
  unattended session never answers. `docs/mac-runner.md` now gives a launchd
  agent and says to run `deploy/chickadee-runner-update.sh` from a clone,
  because a copy of the script on its own cannot load its helper.
