### Added

- **`variable_equality` pattern families support a per-student `expectedVarRef`.**
  "This student's `sd_systolic` equals this student's value" is the simplest
  personalization there is, but it was rejected outright — so an author who wanted a
  per-student answer for a variable exercise had to reshape it into a function first,
  purely to satisfy the grader. The R renderer already had the plumbing; the Python
  one never emitted the personalization preamble and baked the expected in as a
  literal. Both now bind the value from `_ck_inputs`, and the validator's single
  per-student gate is split in two: `kindSupportsPerStudentArgRefs` (unchanged — a
  bound `$name` must reach a called function) and `kindSupportsPerStudentExpected`
  (now including `variable_equality`). Arg refs stay rejected for
  `variable_equality`, whose `args[0]` is the variable *name* and is baked in as a
  literal — a ref there would be silently ignored rather than personalizing anything.
  Families with no per-student refs render byte-identically, so existing `spec_hash`
  / `TestSetupCache` keys do not churn.
