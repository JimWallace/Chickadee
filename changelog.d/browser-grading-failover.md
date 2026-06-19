### Fixed

- **Frozen in-browser grades now fall back to the worker backstop.** Browser
  grading runs Pyodide on the page's main thread, so a non-terminating (or
  blocking) student submission froze the tab: the in-browser per-test timeout
  couldn't fire on the blocked thread, grading never completed, and — because a
  browser submission row is only created when grading *finishes* — nothing was
  ever enqueued, so the v0.4.56 worker backstop had nothing to grade and the
  student was stuck on "Testing…" indefinitely. The freeze-watchdog worker (the
  one thread still alive while the main thread is frozen) now POSTs the stashed
  notebook to a new `POST /api/v1/submissions/browser-failover` endpoint after a
  grading stall, and the browser-runner does the same on a non-freeze hard
  failure. That enqueues a `pending` browser-mode submission the native backstop
  grades via `python3`, where a runaway loop is killed and reported as a clean
  `timeout` instead of a dead kernel. The failover is gated identically to a
  normal browser submission (enrollment + effective-open) and is idempotent per
  (student, assignment). A `submit_failover` diagnostic breadcrumb makes the
  fallback visible in the admin browser-diagnostics surface.
