# R trial — Lab 9 "Predict-It" (hypertension classifier)

A **trial balloon for Chickadee's R support**: an R port of HLTH 230's
browser-graded Python **Lab 9**, authored in the **TEST** course
("A Test Course") as a **worker-graded** assignment.

- Source assignment: HLTH 230 → *Lab 9* (`Ze1JGH`, browser/Pyodide/Python).
- Trial assignment: TEST → *Lab 9 (R) — Predict-It: Hypertension Classifier*
  (`YW6R6X`, worker/Rscript/R).

The two labs teach the same thing — describe a cohort, hunt the strongest
correlate of high blood pressure, then train and tune a logistic-regression
classifier — but this one is written in R and graded natively by the worker.

---

## Why this exercises "R support"

Chickadee already ships **worker-graded R** (issue #77 part 1, PR #102); this
trial is the first end-to-end assignment that uses it. The moving parts:

- **Dispatch.** A test script ending in `.R` / `.r` is classified as R and run
  with `Rscript` (`Sources/RunnerCore/ScriptClassification.swift`,
  `Sources/Worker/ScriptInvocation.swift`).
- **Runtime.** The runner injects `test_runtime.R` next to every job, giving
  the R contract helpers `passed()` / `failed()` / `errored()` (exit 0 / 1 / 2),
  mirroring the Python `test_runtime.py` (`Sources/Worker/TestRuntimeSources.swift`).
- **Notebook → code.** A submitted notebook whose kernelspec is `ir` / `r` /
  `webr` / `xr` is extracted to `<stem>.R` (code cells concatenated), the R
  sibling of the `.ipynb → .py` path (`Sources/Worker/NotebookExtractor.swift`).
- **Kernel survives the round-trip.** `normalizeNotebookForJupyterLite` maps an
  R kernelspec to the vendored `xr` (xeus-r) kernel and sets `language_info.name
  = "r"`, so the starter and solution notebooks stay R through save + validate
  (`Sources/APIServer/Helpers/NotebookContentHelpers.swift`).
- **Base R only.** The grading image installs `r-base` with no extra CRAN
  packages (`Dockerfile`), so everything here is base / `stats` / `utils` /
  `grDevices` — `glm()` does the logistic regression, no `tidyverse`.

**Grading is worker-authoritative for R.** There is no in-browser R grader
(Pyodide is Python-only); the in-browser xeus-r *editor* kernel is still a spike
(`docs/xeus-r-kernel-spike.md`), so this assignment is set to `gradingMode:
worker`. Students submit an R notebook (or `.R` file); the worker grades it.

### The one contract difference from Python

The Python/browser path auto-loads the submission as `student_module` and
injects `require_function`. **The R path does not** — `test_runtime.R` is only
`passed`/`failed`/`errored`. So `lab9_helpers.R` carries the plumbing each test
needs:

- `load_student()` finds the one non-test, non-helper `.R` file in the working
  directory (the extracted submission; `solution.R` during validation) and
  evaluates it **expression-by-expression in a fresh environment**, so a broken
  TODO cell fails in isolation without stopping the student's function
  *definitions* from loading, and their top-level calls/plots do not clobber the
  test's variables.
- `require_student_fn(env, name)` fetches a required function with a clear
  error if it is missing.

### The worker fix this trial surfaced

Authoring the trial exposed a real gap in the shipped R path: the worker's
submission router (`shouldNormalizePythonSubmission` in
`Sources/Worker/SubmissionStaging.swift`) treated **every** `.ipynb` submission
as Python, so an R-kernel notebook was normalized to `solution.py` and the
R-aware extractor (`extractNotebooksToCode`, which emits `.R`) was never
reached. Every test then errored with *"No R submission file was found to
grade."* — the `extractNotebooksToCode` R support existed but nothing routed a
notebook submission to it.

This PR makes the router R-aware: an R-kernel notebook (`ir`/`r`/`webr`/`xr`,
or `language_info.name == "r"`) in a setup with no Python (`.py` required files
or `.py` test scripts) now skips the Python normalizer and is extracted to
`solution.R`. Python and mixed assignments are unchanged. New helper
`submissionIsRNotebook`; regression coverage in
`Tests/WorkerTests/SubmissionRoutingRNotebookTests.swift`.

---

## Files

| File | Role |
|------|------|
| `starter.ipynb` | Starter notebook students open (R kernel `xr`), three TODO functions. |
| `solution.ipynb` | Reference solution (answer key used to validate the suite). |
| `lab9_helpers.R` | Support: `load_data` / `build_cohort` / `evaluate_model` / `FEATURES` + the autograder plumbing above. |
| `nhanes_bp.csv` | Support: the dataset (see below). |
| `publictest_summarize.R` | Public test — `summarize(cohort)` returns `n`, `mean_age`, `hypertension_rate`. |
| `publictest_features_valid.R` | Public test — `select_features()` returns a valid, de-duplicated feature vector. |
| `releasetest_strongest_predictor.R` | Release test — `strongest_predictor(cohort)` names the feature most correlated with `high_bp`. |
| `secrettest_model_accuracy.R` | Secret test — the tuned model clears **0.70** accuracy on the full data. |

The four tests are worth 1 point each (public / public / release / secret),
matching the Python original.

### Dataset

`nhanes_bp.csv` is a deterministic **stride-3 subsample** (every third row) of
HLTH 230 Lab 9's `nhanes_bp.csv` — 1952 rows (1604 after dropping rows with
missing values), 66 KB. Subsampling keeps the file small and grading fast while
preserving the pedagogy, verified before upload:

- `high_bp` base rate ≈ 0.54 (a balanced problem, so accuracy is meaningful).
- Correlation with `high_bp`: **age** (0.49) dominates, then waist (0.28), bmi
  (0.19); `sleep_hours` (0.02) and `smoker` (0.01) are noise.
- Logistic-regression accuracy: `sleep_hours` alone ≈ 0.55 (the starter's
  deliberately-wrong default), `age + waist + bmi` ≈ 0.74 — a safe margin over
  the 0.70 gate.

Columns: `age, female, bmi, waist, activity_min, smoker, sleep_hours,
cholesterol, high_bp`.

---

## Python ↔ R mapping

| Lab 9 (Python, browser) | Lab 9 (R, worker) |
|---|---|
| `student_module.summarize(ref)` (auto-loaded) | `summarize <- require_student_fn(load_student(), "summarize")` |
| `cohort["age"].mean()` | `mean(cohort$age)` |
| `cohort.groupby("female")["high_bp"].mean()` | `tapply(cohort$high_bp, cohort$female, mean)` |
| `cohort[FEATURES].corrwith(cohort["high_bp"])` | `vapply(FEATURES, function(f) cor(cohort[[f]], cohort$high_bp), numeric(1))` |
| `.abs().idxmax()` | `names(which.max(abs(cors)))` |
| hand-rolled numpy logistic regression | base-R `glm(..., family = binomial())` |
| `return {"n": ..., "mean_age": ...}` (dict) | `list(n = ..., mean_age = ...)` (named list) |

Same deterministic 75/25 split in `evaluate_model` (every 4th row held out for
testing) so the score is reproducible for everyone.

---

## How it was built (and how to reproduce)

Authored entirely through the Chickadee MCP server against the live TEST course:

1. `create_assignment(courseCode: "TEST", title: ..., notebook: starter.ipynb)`
   — creates a closed, browser-mode, empty-suite assignment.
2. `set_grading_mode(YW6R6X, "worker")` — R must be worker-graded.
3. `author_script` × 6 — the two support files (`tier: support`) and the four
   `.R` tests (public / public / release / secret), uploaded one at a time.
4. `update_solution(YW6R6X, solution.ipynb)` — stores the answer key and queues
   validation.
5. `validate_assignment` / `get_validation_result` — confirm all four tiers pass
   against the solution on a worker with `r-base`.

Regenerate the notebooks and the dataset subsample from the checked-in sources
with the scripts noted in the repo history for this folder; the `.R` sources
here are the exact bytes uploaded as support/test files.

**Verification.** The four tests were run against the reference solution with
real `Rscript` — all four pass, including the secret gate (`glm` on
`age + waist + bmi` → **0.743 ≥ 0.70**); the unfinished starter grades to
graceful `fail`s with no crashes. End-to-end server validation through the MCP
depends on the router fix above being live on the worker; until it deploys,
`validate_assignment` reports the tests erroring with *"No R submission file was
found to grade."*

---

## Known limitations (it is a trial)

- **No in-browser R editing yet.** The xeus-r editor kernel is a validated spike
  but not production-wired (`docs/xeus-r-kernel-spike.md`), so students cannot
  run the R notebook in the browser the way the Python lab runs in Pyodide. They
  edit locally (or in the JupyterLite editor once xeus-r is wired) and submit;
  the worker grades. Grading is unaffected.
- **Whole-file parse.** `load_student()` is resilient to a *runtime* error in one
  top-level statement, but a *syntax* error anywhere makes the submission
  unparseable (R has no per-cell isolation on this path, unlike the Python
  extractor). A clean submission is unaffected.
- **Per-student personalization is not wired here.** Both the Python original and
  this trial fix the cohort seed (`build_cohort(20240617)`); the per-student seed
  machinery is out of scope for the balloon.
