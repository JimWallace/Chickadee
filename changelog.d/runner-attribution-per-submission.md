### Added

- **Every job now records the runner version that ran it, and validation
  results report it.** `submission_diagnostics` already stored *which* runner
  took a submission (`runner_id`), but the runner's version was only ever live
  heartbeat state on the runner dashboard — so the version for a past job could
  only be found by joining to what that runner is running *now*. During a
  rolling upgrade that join gives the wrong answer, which is precisely when the
  question gets asked: a suite that depends on a newer runner build fails on a
  lagging runner and passes on a current one, and without the recorded version
  the failure reads as a content bug rather than version skew. A new nullable
  `runner_version` column is stamped from the claim payload, so it is also the
  only record for a job that never reported a result (timed out, or the runner
  died). `get_validation_result` now returns `runnerID` and `runnerVersion`
  alongside the outcomes — the version taken from the result document itself, so
  it is the build that actually produced those outcomes.
