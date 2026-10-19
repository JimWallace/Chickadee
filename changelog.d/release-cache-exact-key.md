### Changed

- **The release build cache now matches exactly.** The `build-release` job no longer restores an older `.build` by prefix and builds over it. That incremental build could link stale object files after a type changed kind, and the release binaries go to production. Each change to `Sources` now gets a cold release build of about 13 minutes. The `restore-git-mtimes` action and the full-history checkout in that job are removed, because nothing reads the source times now. (#2712)
