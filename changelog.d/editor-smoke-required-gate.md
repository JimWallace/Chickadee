### Changed

- **The editor-smoke CI workflow is now a requireable merge gate.** Previously it
  was advisory and path-filtered at the trigger, so it couldn't be marked required
  (a path-filtered check is *skipped* on unrelated PRs, and a required-but-skipped
  check blocks those merges). It now runs on every PR: a fail-safe `changes` job
  decides whether the editor / grading / cross-origin-isolation surface was touched,
  the expensive Chromium + WebKit `smoke` matrix runs only when it was, and an
  always-running **`editor-smoke-gate`** job reports a single status — green when the
  smoke passed or was skipped, red only when it actually failed (or when change
  detection itself failed, i.e. fail-closed). Enforcing it is now one repo setting:
  add `editor-smoke-gate` to `main`'s required status checks (see
  `docs/notebook-editor-smoke-test.md`). The change-detection set also gained
  `grading-worker.js` and `CrossOriginIsolationHeaders.swift`.
