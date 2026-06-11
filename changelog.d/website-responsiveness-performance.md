### Changed

- **Website responsiveness pass.** Three hot-path fixes that make page loads
  feel snappier: (1) the student dashboard no longer spawns an `unzip`
  subprocess per assignment row on every view — notebook presence is now
  answered by `NotebookPresenceCache`, keyed by zip mtime + size so any suite
  edit still invalidates it; (2) version-fingerprinted static assets
  (`/styles.css?v=…`, page scripts, icons) are now served with
  `Cache-Control: immutable` via `StaticAssetCacheMiddleware`, eliminating the
  per-navigation revalidation round trips (each of which also paid a Fluent
  session lookup) — a release mints new URLs, so busting is unchanged;
  (3) response compression is enabled for compressible types (CSS/JS/JSON/SVG
  shrink ~4–8× on the wire). HTML is deliberately excluded from compression
  because pages embed the per-session CSRF token (BREACH); already-compressed
  formats (zip, wasm, images) are not recompressed.
