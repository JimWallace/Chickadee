### Changed

- **A test asserts that every migration index exists.** The migrations hold 45 raw `CREATE INDEX` statements and one SQLKit builder call, each behind a guard that cannot fail loudly, and no test read the catalog back. `MigrationIndexCoverageTests` derives the expected `idx_*` set from the migration sources, asserts the derivation is complete, and compares it to `sqlite_master` or `pg_indexes` after migration (#1809).
