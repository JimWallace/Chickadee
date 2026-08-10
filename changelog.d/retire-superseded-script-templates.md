### Removed

- **Eight of the nine Python script templates.** Each duplicated a
  pattern-family kind that already renders in all six languages, in a strictly
  better form — a family is server-rendered, spec-hashed, re-renders when a case
  changes, and is pinned by execution tests, where a template is a one-shot text
  dump the instructor then owns forever. Offering both taught authors to reach
  for the fallback. `exists` → the automatic existence guard; `correctness` and
  `corner_cases` → `boundaryEquality`; `exception` → `exceptionExpected`;
  `type_check` → `returnTypeCheck`; `performance` → `performanceThreshold`;
  `variable_equality` → `variableEquality`; `structural_check` → the
  `astStructure` notebook check.

  `differential` stays: nothing supersedes it yet, since no pattern kind
  compares a submission against a reference implementation.

- **Per-function scaffold scripts on the create page.** The auto-scaffold wrote
  one `publictest_exists_<fn>.py` per detected function, from the template that
  is now gone — seeding a Python script to do a job every pattern family does
  automatically and in every language. Section scaffolding, which was always
  language-neutral and always useful, is unaffected.
