### Fixed

- **A personalization expression now reads the student's dataset slice, not the
  instructor's pool.** `PersonalizationEvaluator` spawned in the shared support
  directory, which holds the full source pool, so an `=` expression over a
  per-student dataset — the mechanism an `expectedVarRef` answer key uses —
  computed the pool's answer and delivered it to every student as their own
  expected value. Structural notebook checks did not notice; any value-based
  check was wrong for the whole class, and identical for all of them. The
  evaluation now runs against a private overlay in which each declared dataset
  carries that student's bytes, resolved from the same source and seed the
  delivered file comes from. Assignments declaring no datasets are unaffected.
