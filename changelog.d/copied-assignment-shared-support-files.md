### Fixed

- **A copied assignment gets its support files.** Course-bundle import and
  `clone_assignment` copied the test-setup zip but did not extract its support
  files into the shared directory. In every copied assignment, students could
  not open its data files in the editor, and a personalization expression that
  calls a support module failed with a `NameError`, so the tests that read
  those inputs failed. Both copy paths now extract the support files. A
  one-time migration, `BackfillSharedSupportFiles`, repairs the test setups
  that were copied before this fix, and it skips any setup that already has a
  shared directory.
