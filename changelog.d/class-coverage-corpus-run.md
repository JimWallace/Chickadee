### Added

- **Class coverage percent, measured by a synthetic corpus run.** A
  contribution assignment can now carry a class goal on `classCoverage` — "the
  class collectively reaches 80% coverage" — the number the per-item union
  could not produce. Every contributor's slot cells are assembled into one
  notebook owned by no student, enqueued as a `classAggregate` submission and
  graded once; the run's own grade fraction is the coverage. The goal is graded
  on the smaller of coverage and breadth, so one student covering everything
  alone does not meet it.

  The run is opt-in behind the goal that reads it, debounced to one in flight
  per assignment, and claimed after every submission a human is waiting on. The
  sweep reads the newest completed run only, so a queued re-run never blanks a
  progress bar that freezes into a grade push.

  This closes slice 8 of `docs/collaborative-class-assignments.md` and slice 7
  of the class-activities plan (#1508).
