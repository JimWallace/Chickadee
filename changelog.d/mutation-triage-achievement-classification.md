### Added

- **The `Achievement` classification predicates are now tested in both
  directions.** `isClassGoal`, `isPerSubmissionBadge`,
  `isAuthorableIndividualBadge`, `usesDynamicSignal` and
  `isSweepEvaluableClassGoal` decide which grading path an achievement takes,
  and every existing test built one achievement satisfying *all* operands and
  asserted the predicate held — so flipping an `&&` to `||` changed nothing
  anyone checked. The 2026-08-19 sweep reported sixteen survivors across them,
  every candidate confirmed alive before a line was written.
  `AchievementClassificationTests` adds the cases that satisfy exactly one
  operand, drives the dynamic-signal test off `AchievementSignal.allCases` so a
  sixth signal must be classified rather than silently defaulting to static,
  and pins the partition that `isPerSubmissionBadge` and
  `isAuthorableIndividualBadge` must never both claim the same badge. Also
  covers the `.equals` arm of a condition's comparator, which had no test at
  all.
