### Added

- **The example nginx vhost serves the vendored editor assets statically.**
  `deploy/nginx.conf` gains static locations for `/vendor/`,
  `/jupyterlite/build/`, `/jupyterlite/extensions/` and each kernel's
  `kernel_packages/` — mirroring `EditorAssetFastPathMiddleware`'s allowlist,
  isolation headers and immutable/no-cache split exactly, with a `try_files`
  fallback to the app so a missing or version-skewed root degrades to the
  proxied behaviour. Verified with a real Chromium kernel boot through the
  shipped vhost (`crossOriginIsolated` true, per-student file paths still
  401, 131 of 160 boot requests served without transiting the app). The
  blue-green container topology deliberately keeps the app-served path; the
  deploy doc records why and what host-side serving there would take.
