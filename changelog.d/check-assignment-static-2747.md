### Added

- **Three more authoring checks in `check_assignment` (#2747).**
  `achievements.neverAwarded` reports an achievement that can never be
  awarded: a test or section reference that a later suite edit removed, a
  class goal of a shape the sweep does not evaluate, or a coverage goal that
  asks for more items than its scope has. `points.noGradedTest` reports a suite
  where every test is worth 0 points. `files.missing` reports a data file that
  the starter notebook names but students do not receive, including a
  grader-only file.
