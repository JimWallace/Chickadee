### Added

- **Author per-student pattern families via MCP (issue #461).** The
  `update_pattern_family` tool now accepts a per-case `expectedVarRef` — the name
  of a global/section `=` expression whose value, resolved for each student's
  seed at grading time, becomes the expected return (instead of the literal
  `expected`). With the existing `$name` `argVarRefs`, this completes the JSON
  authoring path for personalized `boundary_equality` families. Slice C of the
  design ("auto-derive expected from the solution") is folded in: an instructor
  writes the case's expected as a `= solution.<fn>(...)` expression and points
  `expectedVarRef` at it. See `docs/personalization-pattern-families.md`.
