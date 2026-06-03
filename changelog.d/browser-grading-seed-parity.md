### Fixed

- **Browser grading now injects the per-student personalization seed.** The
  in-browser Pyodide runner previously never set `CHICKADEE_ASSIGNMENT_SEED`,
  so a test reading the seed graded differently in the browser than on the
  native worker (which sets it in the test subprocess). The browser runner now
  fetches the seed from a new session-authenticated endpoint
  (`GET /api/v1/browser-runner/testsetups/:id/seed`) that resolves it with the
  same `AssignmentSeedStore.ensureSeed` the worker and notebook substitution
  use, and injects it into Pyodide's `os.environ` before tests run — so
  personalized assignments grade identically in both modes.
