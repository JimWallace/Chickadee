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
