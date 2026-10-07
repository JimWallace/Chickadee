### Added

- **Disk space alert.** A new health rule, "Disk nearly full" (`diskSpaceLow`), fires when less than 15% of the data disk is free. It reads no database, so it still answers when a full disk has stopped Postgres. `get_storage_usage` and `/admin/storage` show the free space too.
- **The deployer holds a deploy on a nearly full disk.** Before it pulls a release image, the deploy daemon checks for 10 GiB free. If there is less, it removes unused images and old snapshots, and if that is not enough, it holds the deploy in state `disk_low`. The `deployerUnhealthy` rule pages on that state.

### Fixed

- **Health alerts can be turned on.** `docker-compose.yml` did not pass `ALERT_ENABLED` or `ALERT_WEBHOOK_URL` to the server, so a Compose or blue-green deploy ran with alerts off. The disk-full outage on 2026-10-07 sent no alert for that reason. Both now pass through, and alerts are on by default. Set the webhook on `/admin/alerts`.
