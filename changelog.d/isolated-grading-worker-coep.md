### Fixed

- **Browser grading of R never ran in the browser on Chromium or Firefox.** The
  student notebook page is cross-origin isolated on those engines, and a worker
  spawned by an isolated page must itself be served `Cross-Origin-Embedder-Policy:
  require-corp` or the browser refuses the worker script outright. The header is
  stamped from a per-path allowlist that `/r-grading-worker.js` was never added
  to, so every R submission was blocked at worker start and quietly failed over
  to the native worker — correct marks, none of the speed the feature exists for.
  Safari was unaffected (it runs the page non-isolated). Both per-language
  grading workers are now allowlisted, and a test reads the spawn sites out of
  the page scripts and fails if the list drifts from them in either direction.
