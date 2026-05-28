### Changed

- **Script-interpreter classification hoisted into `RunnerCore`.** The
  drift-prone "which interpreter runs this script?" decision (recognised
  extension → shebang → Python content-sniff) now lives in
  `RunnerCore.classifyScriptInterpreter` (embedded-safe, shared). The native
  worker's `scriptInvocation` delegates to it and maps the result to a
  subprocess command; behaviour is unchanged (dispatch contract + classify tests
  pass). The browser runner adopts it via wasm in a follow-up, retiring the JS copy.
