### Changed

- **Shared suite-execution loop (RunnerCore).** The grading loop that had
  repeatedly drifted between the native worker and the browser runner —
  dependency gating, "Skipped: prerequisite …" messages, missing-script
  handling, and `TestOutcome` shaping — now lives once in `RunnerCore` as the
  async `executeSuites`, driven through a narrow `ScriptExecutor` protocol
  (`scriptExists` + `run`). The native worker is the first conformance
  (`NativeScriptExecutor`, subprocess + sandbox) and maps the loop's events
  onto its structured log stream; the browser runner becomes the second
  conformance in a later stage. No behaviour change — byte-for-byte the same
  outcomes and log events. (Runner WASM migration, Stage 3 — worker half.)
