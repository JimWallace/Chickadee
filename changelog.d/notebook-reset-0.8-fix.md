### Fixed

- **Notebook "reset" now takes effect on the JupyterLite 0.8 editor.** The 0.8
  Notebook build does not expose `window.jupyterapp`, so the client reseed that
  makes an instructor/self "Reset notebook" visible (`syncNotebookFromServerSnapshot`
  → `waitForJupyterApp` → `contents.save` + `docmanager:open`/`revert`) silently
  no-op'd, leaving the student's stale IndexedDB copy on screen. Added a
  jupyterapp-independent fallback: when the server working copy is newer than the
  baseline this browser last saw, evict the stale entry from JupyterLite's
  IndexedDB contents Drive (`"JupyterLite Storage"` → `files`) and reload with
  `reset=1` so the editor re-fetches the freshly-reset working copy from the
  server. Gated on the reset signal and safe by construction — a key-format
  mismatch makes the eviction a no-op (prior behaviour, never data loss), and it
  only ever touches the one working copy the server just changed.
