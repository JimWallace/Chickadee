### Fixed

- **Grader-only files and browser grading can no longer be combined.**
  `author_script` already refused marking a file grader-only on a
  browser-graded assignment, but the combination was still reachable from the
  other side: switching a worker-graded assignment with grader-only files to
  browser grading succeeded, leaving every student's kernel boot to rebuild a
  filtered setup zip per download — and any tests referencing the withheld
  files broken. `set_grading_mode` and the zip upload now refuse the pair
  (matching the existing upload-only/browser refusal), section adoption keeps
  worker grading instead of failing the move, and the per-download filter
  remains as the backstop for setups created before the rule.
