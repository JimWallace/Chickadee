### Fixed

- **The Docker compile stage builds again.** `Plugins/` was never copied into
  the build context, so `swift build` failed with `invalid custom path
  'Plugins/EmbedRunnerSupport'` — SPM validates every target path in the
  manifest, including targets it is not building, so no product could be built.
  `Tools/runner-support`, which the `EmbedRunnerSupport` build-tool plugin
  compiles into the runner binary, was excluded by `.dockerignore` for the same
  reason. Only `docker compose up --build` uses this stage, and only the weekly
  ZAP baseline run does that, so the break showed up as a ZAP failure a week
  after it landed.

### Added

- **`scripts/check-docker-build-context.sh`** (wired into `format-lint`). Every
  target path in `Package.swift`, and every package-relative directory a
  build-tool plugin reads, must be copied by the Docker compile stage and left
  in the context by `.dockerignore`. Both requirement sets are derived rather
  than listed, and each derivation fails when it yields nothing or yields a path
  that is not on disk.
