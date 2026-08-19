### Added

- **Design note: collaborative class assignments.** `docs/collaborative-class-assignments.md`
  works through what it would take to support assignments where students contribute
  individual artifacts (typically test cases) that accumulate into a class-wide result —
  a coverage target, or a set of seeded bugs to find. Records which parts already exist
  (grading a contributed test against seeded-buggy variants needs no code changes; the
  `.classWide` achievement already carries the bonus, the deadline freeze and the LEARN
  re-push) and the one part that does not: every class goal today counts students whose
  own best grade cleared a threshold, and none aggregates over the union of what the class
  collectively covered. Also sizes the per-student contribution cap the feature implies,
  recommending participation breadth over per-item attribution ranking. Nothing is locked;
  the note exists to be argued with before anything is built.
