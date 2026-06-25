### Fixed

- **In-browser notebook editor no longer freezes on Safari/WebKit.** The
  JupyterLite Pyodide kernel uses `coincident` (a synchronous `SharedArrayBuffer`
  + `Atomics.wait` handshake) whenever the editor iframe is cross-origin isolated,
  and that handshake deadlocks on WebKit — the kernel boots to idle, then wedges
  on the first cell with no console error (reproduced on Safari 18.2 / Intel).
  WebKit requests (Safari, and every iOS browser — all WKWebView) now get the
  editor served **non-isolated**, so the kernel picks the async `comlink`
  transport, with the JupyterLite service worker re-enabled to carry synchronous
  stdin/Drive. Chrome, Edge and Firefox are unchanged and keep the faster
  `SharedArrayBuffer` path. Gated by a single User-Agent classifier
  (`EditorBrowserEngine`) on both the server (isolation headers + service-worker
  config) and the client (`notebook.js` keeps the now-required service worker).
- **Notebook editor no longer throws a `TypeError` applying the locked-UI style.**
  `applyLockedNotebookUI` appended a `<style>` to the iframe's `document.head`
  without guarding against a null `head` (which happens when the document exists
  but `<head>` hasn't parsed yet), throwing "Cannot read properties of null
  (reading 'appendChild')". It now falls back to `documentElement` and skips
  cleanly if neither is ready.
