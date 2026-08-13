### Fixed

- **The nginx body cap no longer sits below the app's own upload limits.**
  Both sample vhosts capped request bodies at 50 MB while the app declares 300
  MB for test-setup zip upload, so a large test setup was rejected by nginx with
  a bare 413 before the app saw it — and the app-side limit read as though it
  were in force. Raised to 512 MB, including in the commented HTTPS block that
  operators uncomment in production, which carried the same cap. Course-bundle
  import's 2 GB backstop is deliberately not matched, and both sides now say so.
- **The systemd unit runs the server in production mode.** It invoked
  `chickadee-server serve` with no `--env`, so a bare-metal deploy took Vapor's
  `development` default and ran with Leaf's template cache disabled, re-reading
  and re-parsing every template on every page render. The Docker entrypoint
  already passed `--env production`; the unit file now does too.
- **Corrected the nginx compression comment.** It claimed Chickadee serves
  pre-compressed `.br`/`.gz` variants for the largest assets. It does not —
  there is no `gzip_static`, no build step producing them, and the only `.gz`
  files shipped are conda kernel tarballs. The comment now describes what
  actually happens, including that a cold multi-MB wasm fetch is gzipped on the
  fly each time.
