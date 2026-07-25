### Added

- **Notebook checks render in R for every kind but `ast_structure`.**
  `variable_exists`, `function_exists`, `numeric_array_close`, `figure_count`
  and `cell_contains` join the data-frame family, so an R assignment can be
  graded the way a Python one is. Where R's honest answer differs from a
  transliteration: `variable_exists` and `numeric_array_close` read the student
  environment directly, because R has no import/exec split for
  `student_main_state()` to work around; `function_exists` derives arity from
  `formals()`, excluding `...` and reading it as "accepts more", so `f(x, ...)`
  satisfies an arity of 3; `numeric_array_close` mirrors numpy's `allclose`
  including `equal_nan`, and settles non-finite positions without the tolerance
  so `Inf` cannot match `-Inf`; and `figure_count` hooks `plot.new`, which fires
  once per high-level plot and never for a low-level addition like `lines()`,
  rather than counting device files (which cannot tell zero plots from one).
  Type names reuse the pattern-family `return_type_check` mapping, so a check
  written `"DataFrame"` means `is.data.frame` in R. `ast_structure` stays
  refused at save time: `list_comprehension` has no R analogue, so its predicate
  vocabulary has to become language-scoped first.

- **R notebook extraction marks cell boundaries.** Flattening a notebook to one
  `.R` file used to discard the cell structure that a source-level check needs,
  so the extraction now writes an inert `# ---- chickadee:cell N ----` comment
  ahead of each code cell and the grading runtime's new
  `chickadee_student_cells()` splits on it — base R, no JSON dependency. The
  marker is an ordinary comment, so the flattened submission still runs; a
  hand-written `.R` upload has no markers and is read as a single cell. Python's
  extraction is unchanged (it already labels cells).
