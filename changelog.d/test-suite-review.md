### Fixed

- **The sandbox tests now run in CI.** `WorkerTests` guarded its seven
  `SandboxedScriptRunner` tests behind a check that returned early whenever
  `GITHUB_ACTIONS` was set on Linux, so the sandbox boundary had no CI
  execution at all and reported as passed. The guard is now a
  `.requiresSandbox` trait that probes the exact `unshare` request the runner
  makes; the worker-tests lane runs `--privileged`, so the tests execute
  there and a skip would fail the lane.
- **The zip subprocess tests now run on the core-tests lane.** The lane ran on
  the plain toolchain image, which has no `zip` or `unzip`, so the three
  `ZipSubprocessTests` returned early there on every run. The lane now uses
  the swift-ci image with the same apt fallback the other lanes carry.

### Changed

- **Runtime skips are visible traits everywhere.** About seventy
  `guard ... else { return }` sites in the R, Octave and zip execution suites
  are now `.requiresRscript`, `.requiresOctave` and `.requiresZipTools`
  traits, so `scripts/check-no-skipped-tests.sh` can see them. The shared
  traits live in one `HostConditionTraits.swift` per test target, and
  `IssueRecorded`, `testURL` and a cached `cachedToolIsAvailable` probe moved
  into `ChickadeeTestSupport` for all three targets.
- **The nightly coverage floor is 80 %,** up from 60 %, a few points under the
  measured 87 %.
- **CI build jobs no longer run `git restore-mtime`.** The build-artifact
  cache matches exactly or not at all, so the mtime restore and the
  full-history checkout it needed did nothing and cost about two minutes per
  run in `swift-tests.yml`, `repeat-test.yml` and the browser probe scaffold.
  `docker-build.yml` keeps it, since its release cache still restores by
  prefix.
