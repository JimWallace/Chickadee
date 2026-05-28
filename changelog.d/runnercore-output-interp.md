### Changed

- **Output interpretation + runtime-model types hoisted into `RunnerCore`.**
  `interpretScriptOutput` (exit code + stdout/stderr → status + display strings)
  and the `TestStatus` / `ScriptOutput` types now live in the wasm-safe
  `RunnerCore` leaf; `Core` re-exports them (`@_exported import RunnerCore`) so
  existing call sites are unchanged. The JSON result-footer is parsed by a
  dependency-free `JSONLite` (Foundation's `JSONDecoder` is unavailable in
  Embedded Swift). Behaviour is identical (output-contract corpus passes); this
  is the single source of truth the browser runner adopts next.
