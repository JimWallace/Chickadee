### Added

- **Headless editor save round-trip probe.** A new editor-smoke check
  (`Tools/editor-smoke-test/notebook-lifecycle-check.mjs` + the
  `notebook-lifecycle-probe` workflow, chromium + webkit) drives the real
  student notebook editor through an edit → `Ctrl+S` save → reload and asserts
  the edit persisted to the IndexedDB Drive (the keep-local reseed path) — the
  in-editor working-copy surface the required editor-smoke gate doesn't cover
  (it proves boot + a Submit grade only). Added to confirm the JupyterLite 0.8 /
  Pyodide 314 upgrade keeps the ContentsManager save/persist/reseed flow healthy.
  Diagnostic, not a required gate. (Student self-reset coverage is a follow-up —
  it needs a full published-assignment seed, not the bare test setup this uses.)
