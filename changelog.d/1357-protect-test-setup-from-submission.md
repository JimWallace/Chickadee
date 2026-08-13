### Security

- **A student's upload can no longer replace the tests it is graded by.** The
  runner executes the suite's scripts out of the same directory the submission
  is merged into, and the merge wrote every student file by its own name over
  whatever was already there — so a zip containing `publictest_bmi_01.py`
  overwrote the instructor's generated test and was graded against itself.
  Generated filenames are deterministic and public-tier names are visible to
  students, and the submit form accepts `.zip`, so this was reachable from the
  ordinary student path. Both normalization paths now refuse a file whose
  workspace path belongs to the test setup (the suite's scripts, the runtime
  helpers, the per-student inputs file and the student-module hints) and warn
  the student by name rather than dropping it silently. `requiredFiles` are
  deliberately not protected — those name what the student must supply.
