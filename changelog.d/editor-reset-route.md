### Added

- **Self-service "reset the notebook editor" page (`/reset-editor`).** When the
  in-browser editor wedges and the Python kernel spins forever — usually stale
  persisted browser state (a corrupted IndexedDB-backed JupyterLite Drive, a
  stale service worker, or cached assets) that a plain reload can't shift — a
  stuck student (or a TA) can hit `/reset-editor` for a one-click fix. The
  confirmation POST returns `Clear-Site-Data: "cache", "storage"`, the
  server-side equivalent of "Clear site data" scoped to Chickadee: it drops
  cache storage, IndexedDB, and service-worker registrations so the next load
  boots the kernel from a clean slate. It deliberately omits `"cookies"`, so the
  student stays logged in. Two-step and CSRF-protected so a cross-origin page
  can't silently wipe in-progress work; the `next` return path is sanitized to a
  same-origin path. The notebook fallback panel links to it (pre-filled with the
  current assignment) when the editor fails to load.
