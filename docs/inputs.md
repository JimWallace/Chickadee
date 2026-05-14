# Inputs — Global and Section variables

Slice 1 + Slice 2 of [issue #461](https://github.com/JimWallace/Chickadee/issues/461)
generalises Chickadee's "+ Add Input" concept so named values flow into
every place a test or notebook could need them, and adds per-student
values via Python expressions.

Two scopes:

- **Section variables** — declared on a test-suite section.  Available to
  every pattern family and every raw test script in that section, plus
  any `{{name}}` placeholders in the starter notebook.  UI lives in the
  section header's "+ Add Input" button (unchanged from earlier
  versions).
- **Global Inputs** — declared at the top of the edit page (new in
  Slice 1).  Same shape; visible everywhere on the assignment.  Slice 2
  added per-student *expressions* (rows starting with `=`).

**Slice 4** added the same `=` expression syntax to the section
`+ Add Input` panel, so per-student values can live in section scope
too (notebook substitution only — same constraint as global
expressions).  The same auto-import / save-time eval / `seed` binding
rules apply.

**Slice 5** lets personalization expressions import instructor code:

- Every `.py` file uploaded as a support file becomes a Python module
  importable by stem (`helpers.py` → `helpers.foo(...)`).
- The instructor's `solution.ipynb` is auto-extracted to a synthetic
  `solution.py` after every test-setup save.  Expressions can call
  `solution.caesar_encode(...)` without the instructor duplicating
  helpers.  An uploaded `solution.py` support file wins on collision.
- Non-`.py` data files (CSVs, text) are reachable too — the
  evaluator's cwd is the support-files directory, so
  `open("quotes.txt").read().splitlines()[seed % N]` just works.

## Two row kinds on the Global Inputs panel

**Literal value** — the Value cell holds bare-typed JSON
(`42`, `"hello"`, `[1, 2, 3]`, `{"k": 1}`, `True`, etc.).  The same
value is used for every student.  Inlined at save time everywhere
section variables are inlined (pattern-family case args, raw test
scripts, notebook `{{name}}` substitution).

**Per-student expression** — the Value cell starts with `=`, e.g.
`= seed % 26` or `= quotes[seed % len(quotes)]`.  Slice 2 (notebooks
only): the server evaluates the expression at student first-open
with `seed` (an integer) and every static input in scope; the result
substitutes into starter-notebook `{{name}}` placeholders.

  - Test scripts continue using the v0.4.156 env-var contract
    (`CHICKADEE_ASSIGNMENT_SEED`) for any per-student logic — Slice 2
    is notebook-only.
  - Pattern-family `$name` references can NOT target an expression row
    (case args need a save-time literal).
  - Save-time eval: the server runs every expression once against the
    instructor's own seed when you save the panel.  Broken expressions
    (`= 1/0`, `= unknown_var`, ...) return a 400 with the failure
    message before any student sees them.

## How values flow

Inputs are **inlined at save time**.  When the instructor saves a value
change, Chickadee:

1. Rewrites every pattern-family-generated test script with the new
   `name = <literal>` lines prepended.  The renderer's existing
   `combinedVariableDecls` step now also includes global variables.
2. Walks every raw Python test script in the test setup zip and
   re-prepends the same block (delimited by a `# === Chickadee inputs:
   …` banner so re-saves don't accumulate).
3. Substitutes `{{name}}` markers in the starter notebook at student
   first-open with `repr(value)` literals.  Each rewritten cell is
   tagged `metadata.chickadee_personalized = "<name>"` so subsequent
   resets only touch fenced cells — student edits to other cells
   survive.

The runner never sees the variable names — only the literal values
already baked into the scripts and the resolved values in the notebook.
Existing runners grade Slice 1 assignments identically to today.

## What instructors can write

In a pattern-family case's `args` JSON, reference a variable with
`$name`:

```json
{ "key": "01", "args": ["$quotes"], "expected": "first" }
```

In a raw Python test script, just use the name — it's prepended for you
by the save-time inliner:

```python
# Don't write this — the inputs banner is added automatically.
# quotes = ["foo", "bar"]
assert solution.first(quotes) == "foo"
```

In the starter notebook, write `{{name}}` wherever you want the literal.
**Write the marker without surrounding quotes** — substitution drops a
Python literal (including quotes for strings, brackets for lists, etc.)
so it's drop-in usable in any context that takes a value:

```python
# === Personalized: do not edit this cell ===
welcome_message = {{welcome}}   # → welcome_message = "Hello world"
shift           = {{shift}}     # → shift = 26
quotes          = {{quotes}}    # → quotes = ["foo", "bar"]
```

This means a single placeholder works for strings, numbers, lists, and
dicts uniformly — no need to think about types or add quotes per case.

## Reserved names

The name `seed` is reserved for Slice 2's personalization feature
(per-(student, assignment) random seed).  Saving a global input named
`seed` returns a 400 error.

## Save-time validation

The `PUT /instructor/:assignmentID/global-variables` endpoint validates:

- Each name is a valid Python identifier (`[A-Za-z_][A-Za-z0-9_]*`).
- No `seed` (reserved).
- No duplicates within the global list.
- No duplicates against any section's variables (sections and globals
  share a Python namespace at inline time).
- Every `{{name}}` marker in the starter notebook matches a declared
  variable (global OR section).  Unknown markers fail the save with a
  specific 400 listing them.

The editor surfaces these errors next to the panel.

## Limitations

- **Shell test scripts (`.sh`) don't get prepending.**  Variable
  injection is a Python-language concern; if you need a value in a
  shell test, read it via env vars (Phase 1 seed contract for runtime
  values).
- **Notebook checks (`+ Add Check`) don't support `$varname` yet** —
  expected values must be literals.  This is a follow-up to Slice 1.
- **Editing a raw script via the per-script edit endpoint** re-prepends
  with the *current* manifest's variables at write time.  If you've
  changed variables since opening the editor, save the whole
  assignment to refresh.
- **Working copies are not retroactively re-substituted** when a global
  changes.  Students already in-progress keep their old substituted
  literals until their notebook is reset (per-student via the existing
  v0.4.153 reset action) or until they open the assignment after a
  manifest hash change triggers the v0.4.154 mtime sync.

## Worked example — Slice 1 (literals only)

```text
Global Inputs:
  quotes  = ["hello", "world", "fizz", "buzz"]
  greeting = "Welcome"

Section "Question 1" inputs:
  expected_first = "hello"

Pattern family case args:
  ["$quotes"]      → quotes = ["hello", "world", …] inlined into test

Raw test script (instructor writes):
  assert first(quotes) == expected_first

Starter notebook cell (instructor writes):
  intro = {{greeting}}, programmer.
  → intro = "Welcome", programmer.   (after first-open substitution)
```

## Worked example — Slice 2 (per-student via Caesar cipher)

```text
Global Inputs:
  quotes    = ["the quick brown fox", "lorem ipsum", "fly me to the moon"]
  shift     = = seed % 26
  plaintext = = quotes[seed % len(quotes)]

Starter notebook cell (instructor writes):
  ciphertext = caesar_encode({{plaintext}}, {{shift}})
  # The student decrypts it back to {{plaintext}} as their answer.

Phase 1 test script (unchanged, instructor authors):
  import os
  seed = int(os.environ["CHICKADEE_ASSIGNMENT_SEED"], 16)
  expected = ["the quick brown fox", "lorem ipsum",
              "fly me to the moon"][seed % 3]
  # ... compare student's decrypted_text == expected
```

Each student sees a different `plaintext` substituted into their
notebook.  The test script re-derives the expected plaintext from the
same seed via Phase 1's env-var contract.  Slice 2 doesn't substitute
into test scripts — test-script substitution remains a future slice.
