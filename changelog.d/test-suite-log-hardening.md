### Changed

- **CI test logs are no longer drowned in migration spam.** The API test suite
  builds ~1,100 throwaway `Application`s, each running 50+ FluentKit migrations
  that logged two info lines apiece — >120k lines that buried real test failures
  (pinning down the last regression's 22 failures meant downloading 24 MB of
  logs). The per-test migration burst is now quieted to `warning`
  (`configureTestDatabase`; override with `TEST_LOG_LEVEL=info`), while the test
  body keeps its normal level so warning/error-inspecting tests are unaffected.
  Also documented the `AssignmentSeedStore.ensureSeed` no-enclosing-transaction
  invariant that keeps its insert-then-refetch race recovery safe on Postgres.

### Fixed

- **De-flaked `runnerLoadPointsSumConcurrentRunners`.** It placed two runner
  snapshots 10 s apart and assumed they shared a 5-minute load bucket, but the
  buckets are epoch-aligned (`floor(epochSeconds / 300)`), so ~3 % of wall-clock
  runs split them into separate buckets and the test failed
  (`points.count 3 != 2`). The snapshots are now anchored to the bucket
  containing `now`, making the grouping deterministic regardless of clock phase.
