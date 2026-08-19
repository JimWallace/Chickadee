### Added

- **The class-wide union of covered items is now accumulated at result time.**
  A collaborative assignment's class goal asks which items the class collectively
  covered — "9 of the 15 seeded bugs" — and the per-test outcomes that answer it
  already existed in `result_collections`. `APIClassItemCoverage` materialises the
  union: one row per (assignment, item), attributed to the submission that covered
  it first, written on both the worker and browser result paths. Accumulating at
  ingest rather than in the class-goal sweep keeps that sweep blob-free (#1160) —
  unioning per-outcome data on a five-minute timer would mean decoding every
  submission's collection for the whole term. First-finder-wins is enforced by a
  unique index rather than by convention, so the union is monotone and idempotent
  under re-tests, replayed reports and concurrent submissions; coverage is
  deliberately not gated on the submission's overall grade; and it is roster-scoped
  so a staff test submission cannot inflate a number that carries bonus points.
