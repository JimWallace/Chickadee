### Fixed

- **The parselmouth-stub fix now reaches browsers that had already cached the
  old xeus chunks.** The v0.4.665 stub changed chunk bytes in place under
  content-hash filenames that `EditorAssetFastPathMiddleware` serves with
  `immutable, max-age=1y` — so every browser that loaded the editor between
  the xeus-r bundle shipping and the stub deploying holds the fetch-bearing
  bytes immutably and would keep replaying the CSP-violation pair for up to a
  year; no server header can reach an already-cached immutable entry.
  `scripts/patch-xeus-extension.py` therefore gained a cache-buster stage:
  the webpack chunk-URL template in the xeus loader files now mints
  `?v=ck1<hash>` queries, and the extension's `load` entry in the built
  `jupyter-lite.json` (served with ETag revalidation — the reliable top of
  the chain) gains `?ck1`, so returning clients re-fetch the remoteEntry and
  chunks once under new URLs while old URLs keep resolving to the same
  patched files (no 404 window). `verify-jupyterlite.sh` asserts the busted
  template, the busted `load`, and that `load` names an existing file.
