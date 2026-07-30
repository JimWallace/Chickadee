### Removed

- **Browser fallback for pre-`extractR` wasm artifacts.** The re-vendored
  RunnerCore artifact carrying the `runnerExtractR` export is on `main`
  (follow-through from #1235), so the temporary verbatim-extraction branch in
  `browser-runner.js` is gone: `loadRunnerCore` now requires the export like
  the other two, and R notebook extraction in the browser always produces the
  worker-identical marker-bearing `.R`. `runner-core.js` is served `no-cache`,
  so no deployed client can retain a loader without the export past the next
  release.
