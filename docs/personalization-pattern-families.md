# Personalization — Pattern families with per-student values (design)

Status: **proposed** (design only; not yet implemented).
Tracking: next slice of [issue #461](https://github.com/JimWallace/Chickadee/issues/461).
Builds on: [personalization-phase1.md](personalization-phase1.md) (per-student
`CHICKADEE_ASSIGNMENT_SEED`) and [inputs.md](inputs.md) (global/section inputs,
`$name` references, `=` expressions).

## Problem

Per-student grading today must be written as a **hand-written Python test
script** that reads `CHICKADEE_ASSIGNMENT_SEED`, re-derives the per-student
inputs and the expected answer, and compares (the worked example in
[personalization-phase1.md](personalization-phase1.md)). That works, but it
diverges from how the rest of an assignment is authored:

- No per-case partial credit — one script is one all-or-nothing outcome.
- Not editable as family rows in the suite editor.
- The "answer key" lives in a bespoke support module rather than a declarative
  case table.

Pattern families are the declarative, per-case-scored, editor-integrated way to
grade — but they **cannot personalize**, and `docs/inputs.md` is explicit that
this is by design today: *"pattern-family `$name` references can NOT target an
expression row"* and *"test-script substitution remains a future slice."* This
doc designs that slice.

## Why families can't personalize today

Three load-bearing facts (confirmed in the current code):

1. **A generated family script bakes a literal `expected`.** The renderer emits
   `expected = <pythonLiteral>` at save time
   (`PatternFamilyRenderer.swift`, boundary/approx kinds) — there is no runtime
   call to a solution. `$name` args resolve at save time to bare identifiers
   satisfied by a prepended `name = <literal>` block
   (`TestScriptVariablePrepender`, `combinedVariableDecls`). Every student
   downloads byte-identical script source.
2. **The test setup is shared and content-cached.** `TestSetupCache` is keyed on
   `testSetupID` and the prepared directory is *copied into a fresh per-job
   scratch dir* before grading. Per-student values are therefore safe **only if
   applied to the per-job scratch copy or injected at runtime** — baking them
   into the cached prepared dir would break download ETags and the
   `manifest+zip` setup-version hash.
3. **`solution.py` is server-side only.** It is auto-extracted from
   `solution.ipynb` into `…/shared/<setupID>/solution.py`, reachable by the
   worker and by `PersonalizationEvaluator`, but **excluded from every
   student-downloadable zip** (`createRunnerSetupZip`). The worker fetches a
   setup zip (`job.testSetupURL`) that can legitimately differ from what a
   student downloads.

The one per-student input already present at grade time is the **seed**
(`Job.assignmentSeed`, injected as `CHICKADEE_ASSIGNMENT_SEED` in
`RunnerDaemon+JobProcessing.executeTestSuites`). The browser grader does **not**
receive the seed yet.

## Recommended design: shared script + server-resolved per-student values map

Keep the generated family script **identical for every student** (cache and
`spec_hash` stay student-independent) and resolve per-student values at runtime
from a small map the **server** computes per submission.

### 1. Authoring (manifest)

A case may mark args and/or the expected as per-student by referencing an
expression input (the `= …` rows from `inputs.md`), lifting the current
"`$name` can't target an expression row" restriction *for grade-time use*:

```json
{ "key": "01", "args": ["$patients"], "expected": "$adults_expected" }
```

where `patients` and `adults_expected` are per-student expressions, e.g.

```text
patients         = = dbgen.generate_patients(seed)
adults_expected  = = dbgen.ref_count_adults(patients)      # instructor reference, OR
adults_expected  = = solution.countAdults(patients)        # auto-derived (worker only; see below)
```

### 2. Renderer (save time)

Emit *references* into a per-student namespace, not literals. The script is
shared; `spec_hash` folds in the expression **source**, never the per-student
result:

```python
patients = _ck_inputs["patients"]
expected = _ck_inputs["adults_expected"]
result   = student_module.countAdults(patients)
if result != expected:
    failed(...)
```

### 3. Dispatch time (new step — reuse `PersonalizationEvaluator`)

When building the worker job (and when serving the browser grader), evaluate the
assignment's per-student expressions for *that submission's seed* into a
`{name: python-literal}` map. `PersonalizationEvaluator` already does exactly
this for notebooks (subprocess `python3`, env allowlist with **no** server
secrets, support-file + `solution.py` auto-import, `repr()` output). The only
change is running it at **grade/dispatch time**, not just notebook first-open.

### 4. Delivery

- **Worker:** add `personalizedInputs: [String: String]?` to `Job` (already a
  `Codable`, extensible struct), and have the worker write `_ck_inputs` into the
  per-job scratch workspace. The shared cache is untouched.
- **Browser:** a new authenticated per-student values response (the runner
  already fetches manifest + zip; add a values fetch), injected into Pyodide as
  `_ck_inputs`. **Only resolved values cross to the browser — never
  `solution.py`.**

This is, in effect, a generalization of the hand-written "answer key" pattern
(reference functions over per-student data, e.g. `dbgen`) into a declarative
family that *consumes* it — gaining per-case scoring and editable rows.

## The `expected` value splits by grading mode

`expected = solution(args)`. Because evaluation is **server-side**:

- **Worker-graded:** the expected expression may call `solution.countAdults(...)`;
  `solution.py` is available to the evaluator and **only the resulting value** is
  shipped to the worker. Auto-derivation works and nothing leaks. → *variety
  **and** secrecy.*
- **Browser-graded:** the grading runtime is the student's own machine, so any
  value shipped to it is readable. Auto-derivation from the solution is
  impossible (can't ship `solution.py`), and `expected` must come from an
  instructor reference expression that a determined student could read. →
  *variety + declarative authoring + per-case scoring, but **not** secrecy* —
  the same ceiling browser grading already has.

So the feature's strongest wins are for **worker-graded** assignments and for
**authoring ergonomics** everywhere.

## Security / anti-cheat

- Worker path preserves the Phase 1 trust boundary: seed and expected
  computation stay server-side; only a trusted worker sees resolved values.
- Browser path provides per-student **variety** (a copied peer notebook is
  graded against the copier's different data) but not secrecy of `expected`.
  Document this so instructors pick the grading mode that matches their stakes.
- `PersonalizationEvaluator`'s existing env allowlist must remain the boundary:
  instructor expressions never inherit `RUNNER_SHARED_SECRET`, DB, or OIDC env.

## Alternatives considered

- **Evaluate expressions inside the grading runtime** (ship expression sources,
  eval against the seed in python3 *and* Pyodide). Rejected: duplicates the
  evaluator in two runtimes (drift risk vs. the server engine), and cannot
  safely auto-derive `expected` on the browser (would require shipping
  `solution.py`).
- **Full per-student script-body substitution at dispatch** (rewrite each
  literal per student, ship whole scripts). Workable and cache-safe if applied
  to the per-job scratch copy, but ships larger per-job payloads and a mutable
  script instead of a stable script + a small values map. The values-map form is
  a strict simplification.

## Incremental scope

- **A — worker-only MVP.** Manifest support for per-student args/`expected`
  expressions on `.boundaryEquality`; renderer emits `_ck_inputs[...]` refs;
  dispatch-time `PersonalizationEvaluator` run → `Job.personalizedInputs`; worker
  injects `_ck_inputs`. Authored via MCP/JSON (no editor UI yet). Validate
  end-to-end against the solution.
- **B — browser.** Seed + per-student values endpoint + runner injection (rides
  on the in-flight browser-seed work).
- **C — auto-derive `expected` from `solution.py`** (worker; documented as
  unavailable on the browser).
- **D — editor UX.** Per-case "personalized" toggle, expression cells, `spec_hash`
  + preview integration, and extend the `preview_personalization` placeholder
  audit (now reading the right notebook after #811) to cover test scripts.

## Open questions

- Manifest shape for a per-student `expected`: reuse `$name` (→ expression row)
  vs. a dedicated per-case `expectedExpression` field.
- Whether to gate per-student families to worker-graded assignments by default
  (secrecy), with an explicit opt-in for browser grading (variety only).
- Cross-runtime determinism contract for any instructor-supplied generator used
  in expressions (the `dbgen` example uses a hand-rolled LCG precisely to be
  identical across CPython and Pyodide; auto-derivation from `solution.py`
  sidesteps this on the worker).
