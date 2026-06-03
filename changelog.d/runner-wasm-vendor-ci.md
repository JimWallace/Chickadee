### Added

- **CI auto-vendors the browser wasm runner.** The shared `RunnerCore` grading
  core is compiled to WebAssembly and checked in under `Public/runner-wasm/`;
  previously a `RunnerCore` change reached the native worker but the in-browser
  grader kept running the stale vendored artifact until someone rebuilt it by
  hand (the gap behind the #801 notebook-extraction fix). A new
  `runner-wasm-vendor` workflow rebuilds and re-vendors the artifact on `main`
  whenever the wasm build inputs change — gated by a source hash
  (`scripts/runnercore-source-hash.sh` vs `Public/runner-wasm/source.sha`) so it
  only runs when needed, with the Embedded-Swift wasm SDK pinned in
  `wasm/wasm-sdk.pin`. The vendored artifact can no longer silently drift from
  `RunnerCore` source.
