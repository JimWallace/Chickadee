### Changed

- **Introduced `RunnerCore`, a shared substrate-free module for runner logic.**
  Its first occupant is the notebook→Python extractor: the native worker now
  extracts notebooks through this single, dependency-free (stdlib-only,
  wasm-ready) module instead of its own copy of the logic. Output
  is byte-identical to before. The core additionally computes an *introspectable
  source* view (real module-level `def`s, side-effects quarantined into
  `if __name__`) alongside the resilient `exec(compile())` executable module —
  the foundation for fixing source/AST-based NotebookChecks and for sharing one
  extractor with the browser runner (eliminating the worker/browser drift behind
  the recent validation failures).
