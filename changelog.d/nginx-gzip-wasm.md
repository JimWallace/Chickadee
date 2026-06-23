### Changed

- **The shipped nginx configs now gzip `application/wasm` (faster editor cold
  loads).** Vapor already compresses the editor's JS/JSON/CSS on the fly
  (`responseCompression = .enabledForCompressibleTypes`), but **not**
  `application/wasm`, and nginx's default `gzip_types` omits it too — so
  Pyodide's ~8.6 MB core `pyodide.asm.wasm` shipped **uncompressed** on every
  cold/incognito kernel boot. `deploy/nginx-docker.conf` and `deploy/nginx.conf`
  now enable `gzip` for proxied responses including `application/wasm`, which
  gzip takes from ~8.6 MB to ~2.7 MB. (An earlier attempt to serve the asset
  pre-gzipped from the Vapor fast path was dropped: Vapor's own response
  compressor double-gzipped it, and nginx is the correct, proxy-level place for
  this. Operators on an existing nginx can add `application/wasm` to their live
  `gzip_types` for the same win without redeploying.)
