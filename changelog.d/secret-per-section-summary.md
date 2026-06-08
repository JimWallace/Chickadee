### Changed

- **Secret-test counts are now shown per section on the submission page.**
  Instead of one aggregate "Secret tests" block at the bottom, each test-suite
  section shows its own hidden-test pass/fail summary, so a student can see
  *which question's* secret tests are failing without revealing the tests
  themselves. Release tests were already itemized in their section; secret
  tests now follow the same sectioning. Assignments with no sections keep the
  single summary under the one table.
