### Fixed

- **Editor bundle updates now reach students on the next page load instead of
  waiting on browser cache heuristics.** The vendored JupyterLite/Pyodide bundle
  assets with stable filenames (the patched kernel wheel, `all.json`,
  `jupyter-lite.json`, the Pyodide runtime, fonts) were served with an ETag but
  no `Cache-Control`, so browsers cached them *heuristically* and could reuse a
  stale copy for hours without revalidating — which is why the `exec_hang` wheel
  fix (#1029) took hours to reach already-loaded students and needed a hard
  refresh. These now carry explicit `Cache-Control: no-cache` (revalidate to a
  cheap bodyless 304 when unchanged), so a deploy propagates deterministically.
  Content-hashed chunks (the bulk of the bundle) keep immutable caching, so this
  adds a revalidation round-trip only for the handful of stable-name assets — all
  on the session-lookup-free fast path. `EditorAssetFastPathMiddleware` stamps the
  `build/`/`extensions/`/`pyodide/` trees it serves; the new
  `BundleAssetCacheMiddleware` covers the slow-path `jupyter-lite.json` and the
  lab/notebooks/repl entry HTML.
