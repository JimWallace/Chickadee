### Added

- **Full authenticated end-to-end browser test of the real student notebook
  page.** A new `notebook-page-check.mjs` (run under the Chromium + WebKit
  editor-smoke matrix) seeds a browser-graded assignment over the HTTP API
  (register instructor → create course → auto-enroll → upload a browser test
  setup → register + log in a student), then drives the actual
  `/testsetups/:id/notebook` page — the cross-origin-isolated parent that embeds
  the JupyterLite editor iframe *and* spawns the grading / freeze-failover Web
  Workers. It asserts the page is cross-origin isolated, the app workers spawn
  (the #986 regression, now guarded on the *real* page, not just
  `/jupyterlite/repl`), the editor loads the student notebook from the Drive,
  and a real Submit runs in-browser grading and renders a passing result. This
  closes the exact coverage gap that let the grading-worker COEP block ship:
  the standalone editor smoke never drove the real page or a real submission.
  `run-smoke.sh` is now parameterized by `SMOKE_CHECK`.
