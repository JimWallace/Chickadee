### Added

- **MCP `get_solution` / `update_solution` tools.** The MCP authoring surface
  can now read and replace an assignment's reference *solution* notebook (the
  instructor's answer key), not just the starter notebook. `get_solution`
  returns the solution resolved from the assignment's validation submission;
  `update_solution` stores a new solution as a `kind=validation` submission and
  re-runs validation against the current suite (watch it with
  `validate_assignment`). Both are instructor-content-only — they resolve the
  validation/solution submission and never expose or touch a student submission.
