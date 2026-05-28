### Changed

- **Runner WASM migration — Stage 5 review.** Ran the Swift→Wasm PR Review
  Checklist over the migration (report: `docs/runner-wasm-review.md`): no
  blocking findings; documented concerns are design trade-offs/follow-ups
  (dynamic JS interop is forced by Embedded Swift, `wasm-opt` not yet run, the
  wasm artifact is vendored rather than rebuilt in CI, tests run via Node +
  browser rather than WasmKit). Fixed the bridge's `JSFunction`-deprecation
  warning by moving to the unified `JSObject`, so the release wasm build is
  warning-clean.
