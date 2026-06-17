### Added

- **Browser-error detail capture.** The in-browser editor now records uncaught
  JavaScript errors and unhandled promise rejections on the notebook page
  (`window.onerror` / `unhandledrejection`) as a new `editor_error` client
  diagnostic, and the kernel-unhealthy watchdog path now attaches the concrete
  failure evidence (e.g. `kernel status: dead`, `Kernel Unknown badge`).
  `client_diagnostics` gains `message`, `stack`, and `source` columns, and the
  per-(user, setup, kind) rate limit now also keys on the error source so
  distinct origins aren't collapsed. Capture is restricted to the editor-load
  path — never student-code execution — so no student-authored content is
  stored. Groundwork for the admin diagnostic tooling described in
  `docs/admin-mcp.md`.
