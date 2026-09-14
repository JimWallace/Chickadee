### Added

- **Advisory passing threshold.** An assignment can set a best-grade percentage
  (Student Options on the edit page, or `passingThresholdPercent` on the
  `update_assignment` MCP tool) at or above which the instructor submissions
  page labels a student as passing and counts them in a Passing card. It is a
  label only and never changes a grade.
- **Download all submissions.** The instructor submissions page offers one
  zip of every student's latest submission for the assignment, one directory
  per student plus an `index.csv`, for offline marking or a
  similarity-detection run.
- **Diff against starter.** Course staff can open a unified diff of any
  student submission against the assignment's starter, from the submission
  history page or the results view: notebooks cell by cell with instructor
  test cells left out of both sides, single files against the starter file of
  the same name.
- **Whole-program input/output tests.** A new `program_io` pattern kind runs
  the submission as a program with a case's standard input and grades what it
  printed, exactly, containing the expected text, or matching a regular
  expression (`ioComparison`), in all seven languages and in the browser for
  the kernel languages. Prompts are part of the output as on a terminal, and a
  program that exits after its answer is still graded. Pick it from the Add
  Test menu under "Test a whole program" or pass `kind: "program_io"` to
  `create_pattern_family`. See `docs/program-io.md`.
- **Per-test failure detail.** Every suite entry, pattern family (family-wide
  or per case) and notebook check can set how much of a failing run the
  student sees: `full`, `actualOnly` (their own output and error, never the
  expected value or a diff) or `verdictOnly`. Applied at results-display time,
  so staff always see everything and a change re-reads every past result.
  Available in the web editors and on the `author_script`, `update_suite`,
  `create_pattern_family`, `update_pattern_family` and `author_notebook_check`
  MCP tools; `get_suite` reports it. See `docs/failure-detail.md`.

### Fixed

- **Family saves from the web editor no longer wipe values set through MCP.**
  The family editor rebuilt the family's defaults and cases from its own
  fields, so a family-wide or per-case time limit set by an agent vanished on
  the instructor's next save. Those fields are now carried forward.
