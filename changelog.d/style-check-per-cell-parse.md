### Fixed

- **Style checks no longer fail just because one cell isn't valid Python.**
  The structural / style-check template parsed the entire notebook source in a
  single `ast.parse`, so a single non-Python code cell (e.g. a Markdown cell
  accidentally saved as a code cell, or a half-written cell) made the whole
  check `error` out — even when the function under test was perfectly correct.
  A new `student_ast()` runtime helper parses each notebook cell independently
  (splitting on the extractor's `# --- cell N ---` markers) and merges the
  parseable cells, so an unparseable cell is skipped instead of blinding the
  check on every other cell — mirroring the per-cell resilience the executable
  module already had. When the target function can't be found and a cell was
  skipped, the failure message now points the student at the broken cell.
