### Changed

- **Callers now name the module that owns the code**, completing the
  `chickadee-ui.js` decomposition. The three delegating re-exports left behind
  by the moves are gone, and fifteen call sites across six files point at
  `ChickadeeSparkline`, `ChickadeeAccordion` and `ChickadeeSurfaceSwap`
  directly.

  Splitting this from the moves was deliberate: a commit that relocates code
  should not also change who calls it, or a move can hide a behaviour change.
  With the moves landed and tested, the indirection has no remaining job.

  `chickadee-ui.js` ends at 363 lines from 701, holding only what it was
  supposed to hold — escaping, the CSRF token, a status line, a fetch wrapper,
  an error extractor, a confirmation dialog, the workbench notice and the UW
  date check. Its header now names the three sibling modules and states the
  rule that keeps it from growing back: a new cross-file concern gets a file
  and a name of its own.
