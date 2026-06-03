### Added

- **Per-student pattern families — browser grading (issue #461, slice B).**
  Browser-graded (Pyodide) submissions now resolve per-student pattern-family
  values too: the browser-runner seed endpoint returns the assignment's `=`
  expression values (`personalizedInputs`) alongside the seed, and the browser
  runner writes them to `_ck_inputs.py` in the grading workspace — mirroring the
  native worker. A shared `PersonalizationSubstitution.gradingInputs` helper
  backs both grading paths so they resolve identically.
