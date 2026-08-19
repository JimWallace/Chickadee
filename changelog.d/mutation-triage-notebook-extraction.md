### Added

- **The notebook extractor's three top-level predicates are now tested.**
  `isSafeTopLevelStatement`, `rhsContainsFunctionCall` and the whitespace trims
  decide whether a notebook line is kept at module level or quarantined, and
  the 2026-08-19 sweep reported seven surviving candidates across them — in
  RunnerCore, whose covering tests all run in the sweep, so the suite really
  did exercise this code and really could not tell the difference.
  `NotebookExtractionPredicateTests` pins the cases that separate them: a plain
  one-delimiter string literal (a module-level docstring the survivors
  quarantine, which drops it from the introspectable source and so from
  `inspect.getsource` and any `astStructure` check), an indented declaration
  that only matches once leading whitespace is trimmed, an identifier ending in
  a digit, underscore or close paren before a call (a false negative there
  leaves a function call running at import time, which is what the quarantine
  exists to prevent), and whitespace-only cells of every whitespace kind.
- **A second entry in the equivalent-mutant ledger.** The bare-string-literal
  guard tests four prefixes, and its first two are redundant: a line starting
  with a triple quote necessarily starts with a single one, so the chain
  reduces to the two single-delimiter tests. The mutant that ANDs the two
  triple-quote tests together is therefore unkillable — nothing starts with
  both — and is recorded with that argument rather than chased.
