### Changed

- **The CI build step retries itself once on the Family 7 crash.** `scripts/ci-build-retry.sh` runs `swift build --build-tests` and runs it once more only when the first attempt exited 139 with `_dispatch_event_loop_drain` in its output, the upstream SwiftPM 6.4 planning crash (`docs/ci-flakiness.md`, Family 7). Any other failure still fails on the first attempt. A `::warning` keeps the rate visible, and the helper's self-test runs in `format-lint`. Closes #1698.
