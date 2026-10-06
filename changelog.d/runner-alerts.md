### Added

- **Health alert: jobs no runner can grade (`unclaimableJobs`).** It fires when a job has waited 5 minutes and no runner that polled in the last 2 minutes may grade it, and names the reason, for example an assignment's `minimumRunnerVersion` above every online runner. It uses the claim walk's own decision (`claimCompatibility`, now shared by both), so the alert and the claim cannot disagree. With no runner online it stays quiet; the runner-offline rule covers that.

### Changed

- **The runner version skew alert waits 30 minutes, not 15.** Runners now update only after they drain, and a runner host's update job runs every 10 minutes, so a correct runner can be about 25 minutes behind the server. Its message now points at the runner's update job. `ALERT_RUNNER_VERSION_SKEW_GRACE_SECONDS` still overrides the default.
