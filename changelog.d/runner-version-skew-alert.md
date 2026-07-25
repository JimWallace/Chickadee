### Added

- **Runner version-skew health alert.** The server now raises a `warning`-level
  health alert — surfaced on `/admin/alerts`, the `get_health_alerts` admin MCP
  tool, and any configured webhook — when a runner still active in the fleet
  advertises a build older than the server's own version. This is the silent,
  intermittent failure mode where a stale runner grades against an out-of-date
  test runtime (e.g. `could not find function "chickadee_..."`). A server-uptime
  grace (`ALERT_RUNNER_VERSION_SKEW_GRACE_SECONDS`, default 900s) suppresses the
  expected transient skew during a blue/green deploy's runner-refresh window, so
  only a persistently-behind runner pages; non-semver runner versions (mock or
  third-party runners) are ignored.
