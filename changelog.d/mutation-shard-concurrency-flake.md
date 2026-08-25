### Fixed

- **The daemon-fanout concurrency test no longer races a 100 ms overlap
  window, which cost the weekly mutation sweep a shard.** Shard 1 of the
  2026-08-25 sweep produced no mutants because Muter's unmutated baseline
  failed on `workerDaemonRunsJobsConcurrentlyWhenMaxConcurrentJobsAllows`:
  the test held each mock script execution open for a fixed 100 ms and
  asserted two would coincide, but the pipeline stages ahead of the runner
  (submission download, workspace prep) jitter by more than that with the
  whole test tree in one process on a 2-core runner, so all five executions
  serialized with no regression present — the shard's own logs show the five
  job pipelines overlapping and only the execution windows missing each
  other. The recording runner now holds each invocation open until a second
  one is simultaneously active, making overlap an event the daemon must
  produce rather than a scheduling coincidence; a genuinely serialized
  daemon trips a 15 s watchdog instead, drains its jobs, and still fails the
  `maxConcurrent` assertion.
