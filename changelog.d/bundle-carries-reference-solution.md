### Fixed

- **Copying a course now carries the reference solutions.** The solution is
  stored as a `validation`-kind submission, not in the test-setup zip, and
  neither copy path moved it: `cloneAssignment` created the clone on a new
  setup id with `validationSubmissionID: nil`, and the course-bundle export
  collected `student` submissions only. A copied term therefore arrived with
  starter notebooks and test suites but no answer keys, and its assignments
  could never be re-validated — the thing to validate against had not
  travelled. Both paths now carry the solution, and each copied assignment is
  linked to its own copy. A clone stays unvalidated, because carrying a
  solution is not evidence that it passes against the suite.

- **Course bundles include the reference solutions.** This changes what an
  exported `.chickadee` file contains: it now holds the instructor's answer
  keys as well as student work. Bundles exported by earlier builds import
  unchanged — a submission with no recorded kind is read as student work.
