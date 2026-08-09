### Fixed

- **Auto-computing a case's expected value now runs the assignment's own
  language.** The editor's evaluator is a Python kernel in a Web Worker, so on
  an R, Lua, Octave, C++ or Racket assignment it did not fail — it computed a
  *Python* answer for a value that would be compared against that language's
  result. Non-Python assignments now call
  `POST /instructor/:assignmentID/compute-expected`, which evaluates through
  `PersonalizationEvaluator` (the same per-language driver that resolves every
  per-student `=` expression). Python keeps its in-page kernel unchanged.
- **A non-Python reference solution is extracted at all.** The server wrote only
  `solution.py`, so an R, Lua, Octave, C++ or Racket personalization expression
  could never call the reference solution — the evaluator looked for a helper
  with that language's extension and the solution was never among them.
  `SolutionNotebookExtractor` now writes `solution.<ext>` in the assignment's
  language, reusing the RunnerCore extractors the worker already uses.

### Changed

- **`LanguageDescriptor.sourceFileExtension`** replaces two identical
  hand-written switches (the worker's submission staging and its notebook
  extractor) that a third was about to join. Distinct from
  `generatedScriptExtension`, which for C++ is the `.sh` wrapper.
- Automatic stdout capture is offered where a language expresses it in one
  expression (R, Octave) and reported unavailable where it does not, instead of
  being auto-filled with what Python printed.
