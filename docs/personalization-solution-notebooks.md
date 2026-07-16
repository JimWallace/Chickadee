# Per-student answers in notebooks (and their reference solutions)

This page captures a rule that is easy to rediscover the hard way: **how a
per-student answer can be expressed in a notebook, and how the reference
solution produces the matching per-student value so validation passes.**

It complements:

- [personalization-phase1.md](personalization-phase1.md) — the per-(student,
  assignment) seed contract (`CHICKADEE_ASSIGNMENT_SEED`).
- [inputs.md](inputs.md) — global/section inputs, literal `variables` vs
  per-student `expressions`, `{{name}}` starter-notebook substitution.
- [personalization-pattern-families.md](personalization-pattern-families.md) —
  per-student pattern families via `$name` / `expectedVarRef` and `_ck_inputs.py`.

## The one rule that bites: the notebook-extractor import quarantine

When a notebook is graded, the runner extracts each code cell into a Python
module and **imports** it (`RunnerCore.extractPython` →
`sanitizeCellForModule`). A top-level statement runs at import **only** if it is
"safe":

- a `def` / `class` / `import` / `from … import` / decorator, **or**
- an assignment whose right-hand side contains **no function call**
  (`x = 5`, `x = "abc"`, `x = a + b`, `x = data[0]` all qualify).

Anything else — a bare call, control flow, or an assignment whose RHS calls a
function — is **quarantined** into an `if __name__ == "__main__":` block so it
does not run at import (this keeps side effects and one broken cell from taking
down the rest of the module). At grading time the module is imported, so
`__name__` is the module name, **not** `"__main__"`, and the quarantined code
never runs.

**Scope of the quarantine (updated):** the quarantine governs what a plain
*import* of the student module sees — which is what pattern families,
`require_function`, `function_exists`, and the personalization `solution.py`
import use. The **runtime-state notebook checks** (`variable_exists`,
`data_frame_shape`/`columns`/`equality`, `series_equality`,
`numeric_array_close`, `figure_count`) instead read
`test_runtime.student_main_state()`, which executes the notebook once with
`run_name="__main__"` — quarantined statements included, per-cell resilience
preserved — so `df = pd.read_csv(...)` and plotting calls ARE visible to those
checks. The rules below still apply to function-based grading and to
`solution.py` imports.

Concretely, this does **not** define `seed` for the grader:

```python
import os
seed = int(os.environ["CHICKADEE_ASSIGNMENT_SEED"], 16)   # RHS has int(...) → quarantined
fortuneShift = 1 + seed % 25                                # NameError at import → whole cell dropped
```

while this **does** (no call on the RHS):

```python
fortuneShift = 7        # literal → runs at import → readable by the grader
```

and so does a function (its body runs at *call* time, not import):

```python
import os
def fortune_shift():
    return 1 + int(os.environ["CHICKADEE_ASSIGNMENT_SEED"], 16) % 25
```

## Choosing the answer shape for a student

| Answer kind | How the student writes it | Graded by |
|---|---|---|
| Fixed value | `answer = "..."` (a literal) | `variable_equality` pattern family, or a notebook check |
| **Per-student** value | the student **discovers** it and writes it as a **literal** (`shift = 7`), since a computed module-level value would be quarantined | hand-written secret script (reads `CHICKADEE_ASSIGNMENT_SEED` or `_ck_inputs.py`), or a pattern family |
| Function | `def f(...): ...` | any function-calling pattern family |

A per-student **variable** answer is fine for students: they brute-force / read
off the value and type the literal in. The grader re-derives the expected value
from the seed (a test script may read `CHICKADEE_ASSIGNMENT_SEED`; pattern
families and `_ck_inputs.py` carry resolved per-student values).

## The catch: the reference solution must also produce the per-student value

The reference solution is graded exactly like a submission (same extractor, same
quarantine), but unlike a student it must be **seed-agnostic** — one notebook
that validates for whatever seed the validation run uses. So it cannot hard-code
a literal, and (per the rule above) it cannot compute a per-student value into a
plain module-level variable either.

Two supported ways to give the solution a per-student value:

### 1. `{{name}}` placeholder in the solution (preferred for variable answers)

The **solution notebook is personalized just like the starter** — its
`{{name}}` placeholders are substituted with the validation run's seed values
(`WorkerArtifactRoutes.downloadSubmission` substitutes validation-submission
notebooks at worker download, using the same `AssignmentSeedStore.ensureSeed`
the worker uses for `_ck_inputs.py`, so the answer key and the grader agree).
Declare the value as a global-inputs **expression** and reference it:

```text
Global inputs (update_global_inputs):
  expressions:
    fortuneShift     = 1 + seed % 25
    fortuneBlockSize = 2 + seed % 5

Solution notebook cell:
  fortuneShift = {{fortuneShift}}          # → e.g. `fortuneShift = 7` at validation
  fortuneBlockSize = {{fortuneBlockSize}}
```

After substitution the cell holds literals, which survive import. The **stored**
solution keeps the `{{...}}` template, so `get_solution` and re-validation by any
user still work. (The starter notebook only needs the placeholders the *student*
should see — it does not reference the answer expressions.)

### 2. A function that reads the seed at call time

If the student's answer is a function anyway, the solution's function can read
`CHICKADEE_ASSIGNMENT_SEED` itself:

```python
import os
def decode_fortune(ciphertext: str) -> str:
    seed = int(os.environ.get("CHICKADEE_ASSIGNMENT_SEED", "0"), 16)
    return decomposite(ciphertext, 1 + seed % 25, 2 + seed % 5)
```

This is why a per-student exercise historically used a function: it was the only
shape whose seed-dependent value survived import. With option 1, a per-student
**variable** answer is now equally supported.

## Authoring checklist (MCP or web)

1. Decide the answer shape (table above). For a per-student value, the student
   writes a literal; don't ask them to compute it at module level.
2. `update_global_inputs`: add the per-student `expressions` the answer derives
   from the seed.
3. Grader: a hand-written secret script (reads `CHICKADEE_ASSIGNMENT_SEED` or
   loads `_ck_inputs.py`) or a pattern family. `_ck_inputs.py` carries every
   evaluated expression as a Python literal — load it with
   `importlib.util.spec_from_file_location("_ck_inputs", "_ck_inputs.py")`.
4. Solution: use `{{name}}` placeholders (option 1) or a seed-reading function
   (option 2). Never a computed module-level variable.
5. `validate_assignment` and confirm `passed`. Use `preview_personalization`
   to see exactly what a seed resolves each `{{name}}` to.
