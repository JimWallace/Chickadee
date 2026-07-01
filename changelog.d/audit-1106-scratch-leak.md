### Fixed

- **Worker no longer leaks the per-job test-setup scratch copy on prepare
  failures (#1106).** The scratch directory returned by `TestSetupCache.acquire`
  was only cleaned up by a `defer` registered after the whole prepare phase
  returned, so any throw in submission download / staging / normalization (a
  routine event for invalid uploads) / `make` / helper writes leaked a fully
  prepared `chickadee_ts_*` directory in /tmp per failed job — a disk-fill
  vector. The prepare phase now removes the scratch copy itself before
  rethrowing; pinned by a daemon-level regression test.
