### Fixed

- **A forced "Retest all" is no longer undone by an in-flight job.** Result
  ingest now accepts a runner's report only for the claim that runner still
  holds: the row must be assigned to it, and the report echoes a claim token
  that names the current claim. A report from a claim that a forced retest or
  the stuck-submission reaper re-queued is refused with HTTP 410, and the
  runner drops it instead of retrying or reporting a failure. Before, such a
  report completed the re-queued row with the old suite's grade, so the
  retest never ran, or it wrote a second result beside the retest's own.
