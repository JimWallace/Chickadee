### Changed

- **Achievements are now a composable design space.** The closed
  `AchievementKind` taxonomy is replaced by an instructor-authored combination
  of a *scope* (this student / the class together / a class record), a list of
  typed *conditions* over a submission's graded signals (grade, attempts, run
  time, grade jump, a test passing) combined with all/any, and the scope's
  reward. The eight built-in awards are migrated to this shape, the three
  per-kind evaluation sites collapse into one condition evaluator, and existing
  manifests authored against the old kinds decode transparently (re-saving
  migrates them forward).
- **Achievements editor moved to an inline accordion with autosave.** Editing
  an achievement now expands an inline row (the suite editor's pattern) instead
  of a top-left modal, and every Save/Remove persists immediately — the
  separate "Save Achievements" button is gone.
