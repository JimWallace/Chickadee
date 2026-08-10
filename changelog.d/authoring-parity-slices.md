### Fixed

- **A scaffolded notebook now carries the assignment's own kernel.** "Create
  assignment notebook" wrote a Python kernelspec whatever the language, from
  four call sites that had no language to pass — so selecting R and clicking the
  button produced a Python notebook. The assignment still resolved R (a recorded
  manifest language outranks the kernelspec), leaving generated `.R` tests beside
  an editor booting `xpython`; on a draft with no recorded language the
  kernelspec is the only signal there is, so the wrong answer was also a sticky
  one. The kernel now comes from `EditorSupport.notebookKernel`, the starter
  cell's comment from `lineCommentPrefix`, and an upload-only language is
  refused rather than scaffolded.

- **Suite sections are scaffolded in every language.** The auto-scaffold bailed
  whenever no functions were found, and the scanner returns nothing for a
  language it cannot read — so five languages got no section scaffolding as
  collateral from a limitation that applies only to function extraction. A `## `
  header is markdown, not code: `unsupportedReason` now scopes to `functions`,
  and the scan reports `sectionNames` either way.

- **The three shell test templates no longer name Python.** They are offered on
  every language and their bodies said `FILE="solution.py"` and
  `python3 -c "import solution; …"` — so a non-Python author got three
  templates, all wrong, which is worse than none. The filename now comes from
  `sourceFileExtension` and the invocation from `interpreterProbe`, with a
  compile-then-run form for a language whose grading builds before it runs
  (chosen by `capabilityRequiresExecutableOutput`, not by naming C++).

### Added

- **Solution scanning for R, Lua and Octave.** The scanner read Python `def`
  statements and nothing else, so an author in another language was offered a
  "Scan Solution for Functions" button that could only ever report an empty
  solution. Each language now has its own definition parser — `f <- function(x)`
  and the `=` spelling for R; `function f`, `local function f` and
  `f = function` for Lua; and Octave's `function [y, z] = f(x)`, whose name is
  not the first identifier on the line — selected behind the existing exhaustive
  `notebookFunctionScanSupport`. The traversal (cells, `## ` headers, dedup,
  shadowing) stays one implementation.

  Partial fidelity by design: none of the three has parameter annotations, so no
  types are claimed. That is the same state an un-annotated Python function
  already produces, and the editor already handles it. C++ and Racket stay
  unsupported for a structural reason — upload-only, so there is no solution
  notebook to scan.
