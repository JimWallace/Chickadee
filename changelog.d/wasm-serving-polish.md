### Changed

- **Browser wasm runner: optimized, immutably cached, size-guarded.** The build
  now runs `wasm-opt -Oz` and content-hashes the artifact
  (`RunnerWasm.<hash>.wasm`), cutting the on-the-wire size to ~394 KB brotli
  (from ~636 KB gzip). A new `RunnerWasmCacheMiddleware` serves the hashed wasm
  `Cache-Control: public, max-age=31536000, immutable` with
  `Content-Type: application/wasm` (so it downloads once and streaming
  compilation works), and the loader `no-cache` so it always resolves to the
  current hash. A CI size-budget check (`scripts/check-runner-wasm-size.sh`,
  with a checked-in baseline) fails the build if the runner balloons past the
  ceiling — guarding against Embedded-Swift generic-specialization explosion.
  Details: `docs/runner-wasm-serving.md`.
