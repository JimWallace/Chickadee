### Changed

- **One copy of each shared test helper.** The host-condition traits, the async lock and the subprocess throttle now live once in `ChickadeeTestSupport`, not once per test target. Six manifests that many suites build a setup from are named in `TestManifests`. Three zip helpers that spawned Python, or skipped silently without `zip`, now use the shared zip fixture.
- **No test waits on a fixed pause to order events.** Three sleeps decided which code path a test took. Each now waits for the condition it needs, with a read-only waiter count on `TestSetupCache` for the one that needed it.
- **The native output contract runs in the core lane.** `OutputContractTests` moved from WorkerTests to CoreTests, beside the RunnerCore code it pins.
- **No `@unchecked Sendable` in tests either.** Three test helpers now hold their state in a `Mutex`, and `scripts/check-unchecked-sendable.sh` scans `Tests/` as well as `Sources/`.
