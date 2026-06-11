### Changed

- **Grades are now denormalized onto the `results` table.** New
  `earned_points` / `total_points` / `pass_count` / `total_tests` columns
  (backfilled from the result blob in one migration statement) replace the
  per-row JSON decode on the student dashboard, instructor roster, grades CSV
  export, submission history, and the achievement / BrightSpace sweeps. The
  CSV export also chunks its result lookups, so term-scale exports no longer
  exceed database bind-parameter limits.
- The worker claim scan is capped at 50 candidates per group (fresh student
  work still beats retests), the achievement sweep batch-loads test setups and
  runs every 5 minutes instead of every minute, instructor-dashboard counts
  use SQL aggregates, and the per-claim test-setup zip hash is memoized.
- Worker script waits no longer block Swift concurrency pool threads
  (termination handlers / a dedicated wait thread), per-stream script output
  capture is capped at 1 MB, and the artifact download timeout was raised from
  15 s (which deterministically failed large setup zips) to 10 minutes.
- Six drifted per-template relative-time formatters were replaced by one
  shared `Public/relative-time.js`.

### Fixed

- **Concurrent submissions can no longer share an attempt number.** Attempt
  numbers are now assigned inside a transaction (`MAX + 1`, with a per-student
  advisory lock on Postgres), fixing corruption of the prior-attempt delta and
  the First-Try-Perfect badge.
- Persisting a worker result and marking its submission complete now happen in
  one transaction, so a failure between the two no longer strands a graded
  submission in `assigned` until the reaper regrades it.
- A worker job-payload decode failure (server/worker version mismatch) is now
  logged as `job_decode_failed` instead of masquerading as a transport error.
- The runner's test-setup cache reconciles with disk at startup, so entries
  surviving a restart are evictable again instead of accumulating in /tmp
  forever.
