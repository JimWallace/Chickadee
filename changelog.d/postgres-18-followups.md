### Added

- **Health alert for a changed database collation version.** The new
  `collationVersionMismatch` rule fires when the database's collation library
  (glibc or ICU) no longer matches the version its indexes were built with,
  which a new image under the floating `postgres:18` tag can cause. Text
  indexes can then miss rows or admit duplicates; the alert names the fix
  (`REINDEX DATABASE`, then `REFRESH COLLATION VERSION`).
- **Guard against VIRTUAL generated columns.** PostgreSQL 18 makes a generated
  column VIRTUAL unless the migration says STORED; `GeneratedColumnStorageTests`
  fails on one that is not listed with a reason.

### Changed

- **Claude Code web sessions test on the PostgreSQL major production runs.** The
  session hook installs the major named in `deploy/db-target-major` (18) when
  the sandbox lacks it, and rebuilds a test data directory left by another
  major. Sessions had been running the suite on PostgreSQL 16.
- **The least-privilege MCP role script hashes its password with SCRAM-SHA-256
  explicitly**, whatever the server's default.
