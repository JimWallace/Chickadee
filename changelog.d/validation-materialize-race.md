### Fixed

- **Validation grading no longer races the worker.** The substituted
  reference-solution notebook (and its cached personalization values) is now
  written *before* the validation submission is saved as `pending`, so a
  fast-polling worker can't claim and download the un-substituted `{{...}}`
  template in the window before materialization finishes. Previously a
  personalized assignment could intermittently fail its own answer-key checks
  ("variable not defined") even though the timeout regression was fixed.
