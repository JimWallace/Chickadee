### Fixed

- **In-browser notebook editor now recovers from a dead kernel instead of
  giving up.** When the JupyterLite/Pyodide kernel registers `dead`/`unknown`
  at boot — a transient cold-boot race (WASM/IndexedDB/service-worker) that hit
  a small fraction of sessions during a deadline rush — the editor watchdog
  reloads the iframe once before falling back to the upload panel. The reload
  re-boots the kernel while preserving the student's saved work (JupyterLite
  workspace restore + the existing reseed-preservation logic). A kernel failure
  that persists after the reload still surfaces the fallback UI and is reported
  with the same `watchdog_timeout` / `kernel-unhealthy` classification, now
  annotated (`persisted after auto-reload`) so the admin browser-diagnostics
  breakdown can tell a persistent failure from a recoverable first-try one.
