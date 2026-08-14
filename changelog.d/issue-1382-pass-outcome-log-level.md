### Changed

- **Per-test result log records for passing outcomes moved to debug level.**
  Result ingest emitted one info-level `test_result_summary` record per test
  outcome through the synchronous console handler — ~43 formatted records for
  a green 40-test suite, per result. Failures, errors and timeouts (what the
  documented triage flow greps for) stay at info; passes now log at debug,
  and their counts remain in `assignment_result_summary`.
