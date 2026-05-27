### Fixed

- **Structural-property NotebookChecks work again on both runners.** They read
  student source via AST, which broke because both runners wrap notebook cells in
  `exec(compile(...))` — so `inspect.getsource` saw no real `def`s. The shared
  RunnerCore extractor now also emits an *introspectable source* (real
  module-level defs, side-effects quarantined into `if __name__`) as a sidecar;
  a new `student_source()` runtime helper reads it, and the structural-check
  template uses it instead of `inspect.getsource`. Both the browser runner and
  the native worker write the sidecar. Fixes the HLTH-230 validation failure.
