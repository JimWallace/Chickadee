### Changed

- **`api-tests-postgres` recycles pre-migrated schemas instead of running 60
  migrations per test.** The lane built a fresh schema and ran the full
  migration list for every one of the suite's ~1,100 test applications;
  measured locally, that is 450.6 ms of a 451.5 ms application, or ~98 % of
  what a Postgres test application costs. A process-wide pool now migrates a
  small number of schemas on demand and hands one to each test, emptying it
  on return with a DELETE sweep in a single `DO` block — 1.7 ms against
  ~460 ms to migrate. Per-test cost stops depending on the migration count,
  the same property the SQLite lane's migrated template already had. A
  returned schema is fingerprinted, and one that comes back structurally
  changed is dropped and rebuilt rather than recycled, so a suite that
  rewrites the migration log cannot poison the pool. No production code
  changed.
