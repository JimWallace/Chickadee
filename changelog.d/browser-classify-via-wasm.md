### Changed

- **Browser runner dispatches scripts via the shared RunnerCore classifier.**
  `browser-runner.js` now calls `classifyScriptInterpreter` through the wasm
  bridge (`runnerClassifyScript`) instead of its own JS copy, so it picks the
  same interpreter as the native worker. The duplicated JS classification
  (`classifyScript` / shebang / content-sniff) and the now-redundant JS
  dispatch-contract test are deleted — the single Swift implementation is pinned
  by `ScriptDispatchContractTests`. Verified in a real browser via the Preview MCP.
