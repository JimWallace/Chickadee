### Added

- **Per-student pattern families — grading path (issue #461, slice A).** A
  `.boundaryEquality` pattern-family case may now resolve per-student values at
  grading time: its expected value (`PatternCase.expectedVarRef`) and `$name`
  arg references can point at global/section `=` expression inputs. The server
  resolves them per submission seed (reusing `PersonalizationEvaluator`) into a
  new `Job.personalizedInputs`; the worker materializes them as `_ck_inputs.py`
  in the grading workspace, and generated scripts load them by path and fail
  closed when a value is missing. This is the foundation (native worker path) —
  the browser runner and editor UI follow in later slices. Design:
  `docs/personalization-pattern-families.md`.
