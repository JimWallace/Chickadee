### Added

- **Per-student pattern families now support `approximate_equality` (issue #461).**
  A float-tolerance family case may reference per-student inputs via `$name` arg
  refs and `expectedVarRef` (e.g. `args: ["$patients"]`,
  `expectedVarRef: "avg_expected"`), resolved per student at grading time — the
  same `_ck_inputs` preamble `boundary_equality` already emitted. The supported
  set is now boundary + approximate (gated by one allowlist in the validator);
  non-personalized cases render byte-for-byte unchanged, so existing families'
  `spec_hash` is stable.
