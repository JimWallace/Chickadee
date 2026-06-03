### Fixed

- **Style checks no longer fail just because one cell isn't valid Python.**
  The structural / style-check template parsed the entire notebook source in a
  single `ast.parse`, so one non-Python code cell (e.g. a Markdown cell saved as
  a code cell, or a half-written cell) made the whole check `error` out — even
  when the function under test was perfectly correct. `student_source()` is now
  best-effort *parseable*: it drops only the cell(s) that don't parse on their
  own (returning the raw source verbatim when nothing needs dropping), so every
  existing saved style check that does `ast.parse(student_source())` becomes
  resilient site-wide on the next regrade — no per-assignment changes. A new
  `student_ast()` helper exposes the same per-cell parse for new checks and
  records which cells were skipped, and `student_source_raw()` keeps the
  unfiltered text available. When the target function can't be found and a cell
  was skipped, the failure message now points the student at the broken cell.
  This mirrors the per-cell resilience the executable module and
  `NotebookCheckRenderer` already had.
