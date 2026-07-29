### Changed

- **Test jobs run on the `swift-ci` image; per-job apt-get installs drop to
  a no-op guard.** `api-tests`, `api-tests-postgres`, `worker-tests`, and
  the nightly coverage run now use the derived CI image with `file`,
  `python3`, `zip`, `unzip`, and `curl` baked in — removing 20–40 s of
  apt-get (and its mirror-flake retry loops) from every run of each job.
  The install steps remain as stale-image fallbacks: if the image ever lags
  a toolchain bump, the job degrades to the old apt-get path instead of
  failing.
