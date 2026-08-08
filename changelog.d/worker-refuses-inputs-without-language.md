### Fixed

- **The runner now refuses a job that carries per-student inputs but names no
  assignment language, instead of rendering them as Python.** The values arrive
  already rendered as source literals in the assignment's language (`repr` /
  `deparse`), so writing them into `_ck_inputs.py` for an R assignment raised no
  error at the boundary — it produced a file whose *contents* were wrong, and
  every personalized test then failed somewhere inside the student's own code,
  with a traceback that read as their mistake and persisted as their grade. The
  old default was justified by "nil means an older server", a premise the
  declare-at-creation work falsified: personalization is resolved per-language
  on the server, so an assignment with inputs has a language by construction,
  and a plain `.sh` suite has neither. The refusal reports `buildStatus: failed`
  with a message naming the cause and the fix, and classifies as terminal so it
  is not retried.
