### Added

- **First-class R support for personalization.** An assignment's language
  (`AssignmentLanguage`, `.python | .r`) is resolved from the manifest and every
  language-specific path dispatches through it, so per-student personalization
  works fully in R as well as Python — transparently to the instructor. `=`
  expressions are evaluated per-language on the server (`python3` or `Rscript`),
  preserving the property that expression source and the reference solution
  never reach the runner; resolved values reach grading as `_ck_inputs.R` and
  `{{name}}` notebook placeholders receive R literals. The R grading runtime
  gains `chickadee_seed()` and `chickadee_inputs()`, composed from one Core
  source so the grader and the server driver cannot drift on the seed. Python
  output is byte-for-byte unchanged. See `docs/r-support.md`.
- **`chickadee_student_file()` in the R runtime.** Locating the student's
  submission is now centralized, alongside `chickadee_load_student()` and
  `chickadee_require_fn()`, instead of being hand-rolled in every assignment's
  helper.

### Fixed

- **`_ck_inputs.R` could be graded as the student's submission.** The reserved
  workspace filenames are enforced inside the R runtime (interpolated from
  `AssignmentLanguage`, so the skip list can't drift), rather than depending on
  each instructor helper to remember them.
- **The student-module hint named a Python file on R jobs.** A notebook is
  extracted to its assignment's source language, so `analysis.ipynb` on an R
  assignment becomes `analysis.R`; `legacyPreferredStudentModuleFilename` was
  still writing `analysis.py` into `.chickadee_student_module`, leaving a hint
  that pointed at a path which was never written.
