### Added

- **Tests for the admin gate and the runner-detail diagnostics tool.** New suites check that a course instructor who is not a deployment admin is refused every admin page and form, the role, alert-webhook and test-alert refusals, and that `get_runner_detail` on the admin diagnostics MCP refuses a blank runner id, a call without `diagnostics:read` and a non-admin, resolves a runner known only by snapshots, and never returns per-job rows or a student identifier. No product code changed.
