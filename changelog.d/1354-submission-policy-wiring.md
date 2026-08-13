### Fixed

- **The Python submission path now goes through `SubmissionPolicy` like every
  other language.** The policy file says it is "the shared implementation of the
  notebook guarantees, so both the Python normalizer and the generic extractor
  enforce one standard rather than two" — but Python used a private second
  implementation, so the exemption table governed six languages and Python
  answered to nothing. The two agreed only by coincidence.
- **A skipped guarantee is logged.** The policy documented that an exemption
  "appears in the runner's structured log"; nothing logged it, so an operator
  diagnosing a missing error could find no trace and conclude the check had run.
  Skipping now emits `submission_guarantee_skipped` with the guarantee, the
  language and the stated reason.
- **The Python compatibility copy refuses a non-Python source.** Any `text/*`
  upload classifies as a Python script, so a student who submitted
  `solution.lua` to a Python assignment had it copied to `solution.py` and was
  shown Python syntax errors against Lua source — under a warning claiming a
  copy had been made "from the single detected Python source file".
