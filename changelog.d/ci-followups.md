### Changed

- **CI pipeline follow-ups (docs/ci-flakiness.md).** The five browser
  probe/smoke workflows and visual-regression now share one
  `browser-probe-setup` composite action (mtime normalisation, build-cache
  restore, server build, Node + Playwright install) with the Playwright
  engine download cached — ending the 7× copy-paste and the per-run engine
  re-download. `swift-tests.yml` gained a `swift-tests-gate` aggregator job
  (mark it — not the individual jobs — required in branch protection).
  JupyterLite and CodeQL runs now skip their heavy steps on PRs that touch
  nothing relevant (fail-safe change detection; the jobs still report
  success, so they remain safe as required checks) and cancel superseded PR
  runs. Six long-running jobs that inherited the 6-hour default gained
  explicit `timeout-minutes`. A weekly `flake-telemetry` workflow tallies
  the tolerated-flake warnings from the probes into a tracking issue so the
  webkit ambient rate stays measured.

### Fixed

- **Bounded subprocess pipe reads in `PersonalizationEvaluator` and
  `MimeTypeDetector`.** Both read their child's pipes only after
  `waitUntilExit()`, which deadlocks once the child fills a 64 KiB pipe
  buffer (for personalization: a long expression output became a spurious
  timeout with a blocked server thread). Pipes are now drained before the
  wait — concurrently and deadline-bounded for the evaluator — with SIGKILL
  escalation if an expression's interpreter ignores SIGTERM. Evaluations
  also no longer sleep out the full 5 s timeout budget before returning
  (the timeout task is cancelled once the child exits).
