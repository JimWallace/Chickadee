### Fixed

- **Round-robin match rows now arrive over HTTP.** The result decoder rebuilt a runner's report from its `collection` and `diagnostics` only and dropped `matches`, so the rows a round robin or a tests-versus-implementations job opened at claim never completed and the standings stayed empty. The wrapped report is now decoded whole; a legacy bare collection is still accepted.

### Added

- **Deployment-wide minimum runner version (#1249).** `RunnerVersionGate.deploymentMinimumRunnerVersion` (`0.5.0`) applies to every claim beside the per-assignment `minimumRunnerVersion`. It refuses only a parseable version below the floor and admits a version it cannot parse. Raising it in a PR is the retirement path for wire shims; see `docs/runner-capability-profiles.md`.
