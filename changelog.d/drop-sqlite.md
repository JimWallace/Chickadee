### Removed

- **SQLite support.** PostgreSQL is now the server's only database. The server
  needs `DATABASE_HOST`, `DATABASE_PORT`, `DATABASE_NAME`, `DATABASE_USER` and
  `DATABASE_PASSWORD`, and refuses to start without them. `DATABASE_BACKEND` and
  `SQLITE_PATH` are no longer read. Nothing moves an existing SQLite database
  into Postgres. Production already ran on Postgres, so it needs no change.
- **The SQLite-only workarounds.** The write-locked transaction, the
  "database is locked" retry, the in-process job-claim queue and the SQLite
  branches of about a dozen queries and migrations are gone. Postgres takes the
  same paths it took before.

### Changed

- **Tests run on Postgres.** `swift test` needs a local Postgres. It defaults to
  `localhost:5432`, database `chickadee_test`, user and password `postgres`, and
  each `TEST_DATABASE_*` variable overrides one part. CI runs one API test lane
  instead of two. The browser harnesses give each server boot its own database.
- **The compose `db` service is required.** `docker-compose.yml` now starts
  Postgres and points the server at it by default.
