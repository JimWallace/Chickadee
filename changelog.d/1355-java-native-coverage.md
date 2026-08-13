### Added

- **`JavaNativeGradingTests`** — Java is upload-only, so the native worker is its
  only grading path, and it was the one language with no test on that path. The
  suite drives the real chain (`scriptInvocation` → `NativeScriptExecutor` →
  `executeSuites` → `interpretScriptOutput`) for a generated `.sh` case, the
  exit-code contract through the sentinel check, and a hand-written `.java`
  suite entry, which is a documented instructor path that nothing pinned.
- **Classification coverage for `.m`, `.rkt` and `.java`**, and for the
  node-before-java shebang ordering — which the classifier's own comment calls
  load-bearing ("javascript" contains "java") and which no test held down.
