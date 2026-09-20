### Fixed

- **The hung-make timeout test now runs in CI.** `WorkerDaemonTests` returned
  early when `/usr/bin/make` was absent, and the swift-ci image never carried
  it, so the runner's make-step timeout had no CI execution. The image now
  installs `make`, the worker-tests fallback probes for it, and the guard is a
  visible `.requiresMake` trait.

### Changed

- **The browser probe workflows use a shallow checkout.** The seven callers of
  `browser-probe-setup` fetched full history for a git mtime restore that the
  scaffold no longer runs.
