### Fixed

- **Editor boots no longer fire a CSP violation from the xeus extension's
  parselmouth fetch.** The vendored `@jupyterlite/xeus-extension` fetched a
  conda→PyPI name mapping from `raw.githubusercontent.com` at module load — on
  every editor boot, for every kernel — which `connect-src 'self'` blocks by
  policy, logging a `csp_violation` + `unhandledrejection` diagnostics pair per
  boot since the xeus-r bundle shipped. The mapping only serves xeus's runtime
  pip-install path, which Chickadee never uses (the kernel env is fully baked
  from `environment-r.yml`), so `scripts/patch-xeus-extension.py` now stubs the
  fetch to a resolved empty mapping — the code's own identity-mapping fallback,
  minus the network attempt and the noise. Applied by `build-jupyterlite.sh`,
  asserted by `verify-jupyterlite.sh`.
