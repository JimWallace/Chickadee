### Added

- **The deploy daemon upgrades PostgreSQL before a release that needs it.** A
  release declares its PostgreSQL major in `deploy/db-target-major` (now `18`).
  When it is higher than the running one, the release waits for approval in
  every mode, and the approval runs `scripts/db-major-upgrade.sh` and then the
  blue-green deploy. A failed upgrade rolls back, deploys nothing and waits for
  a new approval; an interrupted one is rolled back with `--recover` when the
  daemon starts. The admin Deployment page warns on the held and Coming next
  cards, `get_deploy_status` reports the running and declared majors and the
  upgrade state, and a failed upgrade fires the `deployerUnhealthy` alert
  (#3149).
