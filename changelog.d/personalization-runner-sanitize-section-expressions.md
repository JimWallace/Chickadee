### Changed

- **Per-student pattern families: section expressions are now stripped from the
  runner-facing manifest.** `TestProperties.runnerSanitized()` already dropped
  `globalExpressions` (a server-side authoring concern — only the resolved
  values reach grading via `Job.personalizedInputs` / the browser seed
  endpoint), but it kept each section's identical `PersonalizationExpression`
  rows. Section expressions are now stripped too, so reference-solution source
  (e.g. `= solution.countAdults(...)`) never travels in the worker job payload.
  No grading-behaviour change — the runner reads neither field; per-student
  values continue to arrive resolved.

### Fixed

- **Stale personalization docs/comments.** `docs/inputs.md` and two
  `TestProperties` doc-comments still stated that pattern-family `$name`
  references "can NOT target an expression row" and that test-script
  personalization "remains a future slice" — both lifted by the per-student
  pattern-family work. Updated to point at
  `docs/personalization-pattern-families.md`. Added a runtime regression test
  that executes a generated per-student case against a real `_ck_inputs.py`
  (passes when correct, fails closed when the seed is absent), complementing the
  existing syntax-only check.
