### Fixed

- **Adding a hand-written test script in another language no longer migrates the
  assignment.** Authoring one `helper_test.R` into an assignment declared as
  Python re-rendered every generated test in R, deleted the `.py` ones, and
  rewrote the manifest's language — a migration nobody asked for, triggered by
  adding a helper, and asymmetric (a `.py` helper could never flip an R
  assignment). It also went around the guard that refuses a language change once
  generated tests exist. The declaration is now what decides, and changing it is
  the language dropdown's job.
- **A runner can no longer claim a job it can only partly grade.** The claim gate
  required just the assignment's declared language, so a `.R` script inside a
  Python assignment could be claimed by a runner with no R and die at
  "Rscript: not found" in front of a student — the exact failure the gate exists
  to prevent. It now requires every language the suite actually uses. A suite of
  plain shell scripts still runs anywhere, as it always has.

### Changed

- **Written down: a declared language is not exclusive.** Shell is the substrate
  every assignment sits on, and a suite may legitimately mix languages — the
  runner classifies each script on its own and stages every language's test
  runtime, so an `.R` helper in a Python assignment has always run under Rscript.
  The declaration governs what Chickadee *generates*; the script's own extension
  governs how it *runs*. `CLAUDE.md` and `docs/language-declaration.md` now say
  so, along with why "None" is not a shell language case.
