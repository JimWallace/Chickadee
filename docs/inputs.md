# Inputs — Global and Section variables

Slice 1 of [issue #461](https://github.com/JimWallace/Chickadee/issues/461)
generalises Chickadee's "+ Add Input" concept so named values flow into
every place a test or notebook could need them.

Two scopes:

- **Section variables** — declared on a test-suite section.  Available to
  every pattern family and every raw test script in that section, plus
  any `{{name}}` placeholders in the starter notebook.  UI lives in the
  section header's "+ Add Input" button (unchanged from earlier
  versions).
- **Global Inputs** — declared at the top of the edit page (new in
  Slice 1).  Same shape; visible everywhere on the assignment.

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

## Worked example

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
  intro = "{{greeting}}, programmer."
  → "Welcome, programmer." after first-open substitution
```
