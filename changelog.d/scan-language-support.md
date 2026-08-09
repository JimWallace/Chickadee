### Fixed

- **The solution-notebook scan says which language it cannot read.** It matches
  Python `def` statements and nothing else, so an R, Lua, Octave or Racket
  solution produced no functions and the instructor was told "No functions
  found." — the same message an empty solution gets. `notebookFunctionScanSupport`
  is now an exhaustive switch a seventh language must answer, the scan endpoint
  returns the reason alongside the functions, and both authoring pages show it.
  The scaffold asks the same question instead of no-opping by accident.
