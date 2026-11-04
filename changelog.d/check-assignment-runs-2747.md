### Added

- **`check_assignment` reads the validation runs (#2747).** Six more authoring
  checks: the reference solution fails a per-student validation variant; a
  placeholder that no input declares; a per-student expression that fails for a
  validation seed; a graded test that passes on the unmodified starter; a
  solution that uses more than half of a test's time limit; and a leaderboard
  activity whose solution run reports no `metric`. The tool reads the stored
  solution, variant and starter runs through the student-data boundary and
  evaluates the expressions for the variant seeds. It still starts no run. A
  part that cannot be read is reported in `warnings` instead of failing the call.
