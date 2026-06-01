### Added

- **Per-student grade override with BrightSpace sync.** Instructors can set a
  whole-number percent override on the grouped per-student submissions page
  (`/:courseCode/students/:urlToken/submissions`), keyed on
  (test setup, user). The override takes precedence over the runner-assigned
  best grade both in the page and in the BrightSpace grade sweep, where it is
  converted to points against the suite's total possible points. Setting or
  clearing an override re-flags the student's results as sync-pending so
  BrightSpace re-pushes.
