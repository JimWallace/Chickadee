### Changed

- **Achievements unification (A3): class-record awards are manifest-driven.**
  `awardClassBadgesFor100Percent` and the Pathfinder award iterate the assignment
  manifest's authored `classRecord` achievements by `recordDimension`
  (firstToSolve / fastest / shortest / new firstToSubmit), falling back to the
  built-in registry. Behavior-identical until a manifest authors class records.
  The new `firstToSubmit` dimension distinguishes Pathfinder (first to submit)
  from Trailblazer (first to solve).
