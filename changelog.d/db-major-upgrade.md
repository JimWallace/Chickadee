### Added

- **`scripts/db-major-upgrade.sh` moves the Compose `db` to a new PostgreSQL major version.** It dumps the roles and the database, restores them into a new volume on the new version, compares a full inventory of the two (row counts, migrations, roles, grants, RLS policies, columns, indexes, sequences, database settings), and rolls back to the untouched old volume on any failure. `--check` runs the preflight only, `--recover` repairs an interrupted run, and `--pin-current` pins the running version. The live image and volume are recorded in `docker-compose.db.yml`, which every deploy script now includes. A new workflow runs the script end to end, 16 to 18, against real images (#3148).

### Changed

- **PostgreSQL 18 is the default.** Fresh installs get `postgres:18` (with `PGDATA` kept at `/var/lib/postgresql/data`), and CI tests against 18. An existing host keeps its version until `scripts/db-major-upgrade.sh` moves it; see "PostgreSQL major upgrade" in `deploy/README.md`.
- **`scripts/restore.sh` restarts the runner with `--no-deps`,** so a restore can no longer recreate `db` as a side effect.
