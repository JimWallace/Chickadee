### Changed

- **Small hygiene (#1129).** The one `Issue.record`-to-skip anti-pattern in
  the test corpus is now a silent guard (missing zip/unzip is
  platform-expected, not a failure), and `CHICKADEE_DEPLOY_STATE_DIR` — the
  last env var read outside `AppConfig` after the v0.4.169 centralization —
  now flows through `appConfig.diagnostics.deployStateDirectory` and appears
  in the redacted startup summary.
