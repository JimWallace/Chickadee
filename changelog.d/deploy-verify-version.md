### Fixed

- **A deploy is recorded as a success only when the server runs the release's version.** The auto-deploy daemon recorded success once `/health` answered, with whatever version answered: on 2026-10-05 three "successful" deploys of v0.5.464 ran 0.5.463. It now rolls back and counts a failure when the reported version differs from the release.

### Added

- **A `deployerUnhealthy` health alert.** It pages when the auto-deploy daemon reports `stuck`, `error` or `certificate_invalid`, or when it has not written its status for 30 minutes. Until now those states showed only in the admin MCP.

### Changed

- **The `runnerVersionSkew` alert is now a warning that pages,** not an advisory: a runner left behind can lack a sandbox fix, which the minimum-runner-version gate does not cover.
