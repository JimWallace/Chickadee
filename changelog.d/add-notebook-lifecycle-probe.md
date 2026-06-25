### Added

- **Headless notebook-lifecycle probe.** A new editor-smoke check
  (`Tools/editor-smoke-test/notebook-lifecycle-check.mjs` + the
  `notebook-lifecycle-probe` workflow) drives the real student notebook editor
  through an edit → `docmanager:save` → reload (asserting the edit persisted to
  the Drive) and then a reset → reload (asserting it reverted to the starter),
  on both Chromium and WebKit. It covers the in-editor save / reset / reseed
  lifecycle the required editor-smoke gate doesn't (that one proves boot + a
  Submit grade only) — added to confirm the JupyterLite 0.8 / Pyodide 314
  upgrade keeps those working-copy flows healthy. Diagnostic, not a required gate.
