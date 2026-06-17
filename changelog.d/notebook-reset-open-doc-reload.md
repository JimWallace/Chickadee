### Fixed

- **Instructor "Reset notebook" appeared to do nothing on the student's
  next visit.** The reset overwrote the working copy on the server and the
  mtime-based cache-bust signal correctly told the browser to force-reseed
  IndexedDB — but JupyterLite's workspace restore had usually already
  re-opened the *previous* (stale) document, and `docmanager:open` on an
  already-open path only focuses it without re-reading the freshly-seeded
  contents. The reset therefore only became visible on a *second* page
  load. `syncNotebookFromServerSnapshot` now reverts the open document's
  context after reseeding when the server copy is newer (a reset), so the
  starter shows immediately. Gated on the server-newer + had-local-copy
  case via a new pure `reseedPlan` helper so a normal revisit never
  discards a student's unsaved in-editor edits. Regression-pinned in
  `Tests/BrowserRunnerJSTests/sync-force-reseed.test.mjs`.
