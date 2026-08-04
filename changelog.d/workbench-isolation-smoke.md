### Added

- **The workbench's cross-origin-isolation chain is now checked in a real
  browser.** `Tools/editor-smoke-test/workbench-check.mjs` seeds an assignment
  through the real HTTP API, opens the workbench as its instructor, and asserts
  the shell, the left pane, and the *nested* notebook iframe are each isolated
  (inverted for WebKit, which runs the comlink path deliberately), that the
  nested frame really has `SharedArrayBuffer`, and that the solution pane stays
  unmounted until asked for. Runs in the editor-smoke matrix on both engines.

  Unit tests can only pin the response headers. Whether the isolation those
  headers are meant to produce actually survives two levels of framing is a
  browser question, and getting it wrong is silent — the kernel still boots,
  just on the slower service-worker transport, with no error reported anywhere.
  The check was verified by removing each half of the isolation rule in turn and
  confirming it fails with the matching diagnostic.

  The editor-smoke path filter now also covers the workbench route, template and
  scripts, so a change to any of them runs the smoke rather than skipping it.
