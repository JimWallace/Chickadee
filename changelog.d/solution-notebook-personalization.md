### Added

- **Reference-solution notebooks are now personalized like the starter.** A
  validation (solution) notebook's `{{name}}` placeholders are substituted at
  worker download using the same per-(student, assignment) seed the worker uses
  for `_ck_inputs.py`, so the answer key resolves the same per-student values the
  grader expects. This makes a per-student **variable** answer (e.g.
  `shift = {{shift}}`) a first-class, validatable pattern — previously only a
  seed-reading *function* could survive the notebook extractor's import-time
  quarantine. The stored solution keeps its `{{…}}` template, so `get_solution`
  and re-validation by any user still work. New doc:
  `docs/personalization-solution-notebooks.md`; the MCP `initialize`
  instructions and `update_solution` description now spell out the quarantine
  rule and the two supported ways a solution produces a per-student value.
