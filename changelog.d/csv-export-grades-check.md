### Bug fixes

- **Grades CSV now exports the highest grade across all result sources.**
  Previously the export picked the worker-preferred result per submission and
  used its raw `earnedPoints`, so a browser run at 100 % could be displaced by
  a later worker re-grade at a lower percentage (because the worker backstop
  runs secret tests the browser runner does not).  The export now loads every
  result for every submission (browser and worker alike), takes the highest
  `gradePercentValue`, and converts it to points via the manifest total so the
  CSV column is on a stable scale.  Students who already saw 100 % in Chickadee
  will continue to receive 100 % in the exported CSV regardless of subsequent
  worker re-grades.

### Testing

- **Grade override CSV coverage.** Added a test verifying that a per-student
  grade override exports correctly to the grades CSV even when the student has
  no submission — confirming the override-without-submission path writes the
  correct points rather than leaving the cell blank.
- **Best-grade-wins coverage.** Added a test with one submission that has both
  a browser result (100 %) and a worker result (90 %), asserting the CSV exports
  10.0 points (not 9.0) and that the worker result does not displace the higher
  browser grade.
