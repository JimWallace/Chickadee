### Changed

- **One index test, not two.** `CreateSweepAndPollIndexesTests.everyListedIndexExists` checked indexes that `MigrationIndexCoverageTests` already checks, and on Postgres it read every schema, so another suite's index could satisfy it. It is deleted. The test of the list's shape stays, in a file named after it. (#2284)
