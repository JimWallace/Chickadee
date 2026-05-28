### Changed

- **`TestOutcome` and `TestTier` hoisted into `RunnerCore`.** The canonical
  grading-result types now live in the wasm-safe leaf (re-exported by `Core` via
  `@_exported import`, so call sites are unchanged). Their `Codable`
  conformances are gated `#if !hasFeature(Embedded)` — only native targets
  serialize them. Prepares the shared `executeSuites` orchestration. No
  behaviour change (Codable round-trips + core tests pass; native + embedded
  builds green).
