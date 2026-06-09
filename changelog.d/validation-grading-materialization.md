### Fixed

- **Reference-solution personalization no longer times out the runner.** A
  validation submission's `{{name}}` placeholders and `=` expressions are now
  resolved **once at enqueue** and cached — the substituted answer-key notebook
  to a `<submission>.grading` sidecar, the expression values onto the submission
  row — so the worker poll and artifact-download routes stay pure I/O. Previously
  (v0.4.388, #869) the download handler ran a `python3` subprocess inline, which
  the runner's 5 s download timeout tripped (`NSURLErrorTimedOut` / `-1001`),
  surfacing as a spurious "Build failed" on any personalized assignment graded
  via the worker (including browser-graded assignments validated through the
  worker backstop). The answer-key notebook, `_ck_inputs.py`, and
  `CHICKADEE_ASSIGNMENT_SEED` now all derive from one seed.
