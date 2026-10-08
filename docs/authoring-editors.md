# Authoring editors

How the instructor editors write to the server, and how they learn the
assignment's language. CLAUDE.md keeps one line per rule and points here.

**Server-authoritative suite editor (v0.4.79+).** The instructor assignment
edit page is wired to `PUT /instructor/:assignmentID/suite` and
`PUT /instructor/:assignmentID/families` — drag-reorder, tier/points edits,
and family edits persist live with the server returning the reconciled state.
The legacy client-side `#suite-config-field` JSON blob and the
`/edit/save` suite-rebuild path are gone; the main Save button only handles
name, due date, notebook uploads, and the validation enqueue. Dependencies
accept `family:<id>` tokens which the server expands to concrete filenames
before persistence; cycle detection runs on the authored graph.

To set a dependency in the web editor, drag a row onto the middle of another
row in the same section. The dropped row then depends on that row and shows
nested under it. A drop on the top or bottom edge of a row only reorders. A
notebook check cannot take part in a dependency, and a row that already has a
dependency or children cannot take a new child (`dropZoneFor` in
`Public/suite-table.js`). The page states the basic rule in one note above the
suite table.

**The embedded editor writes back (`POST /testsetups/:id/notebook/save`).**
JupyterLite keeps the live document in the browser, so authoring edits used to
reach the server only via an upload on the new-assignment page or the MCP
`update_notebook` / `update_solution` tools. Course staff (TA+) now get a
"Save to assignment" button on the notebook page that POSTs the open notebook
back through the same server-side steps those tools use —
`AssignmentAuthoringService.writeAssignmentNotebook` for the starter, a fresh
`kind == .validation` submission for the solution — plus the author's working
copy so a reload shows the save, and the version snapshot every authoring write
gets. It is a **live-edit** endpoint: like `PUT /suite` and unlike the MCP
tools, it never changes visibility, so fixing a typo mid-lab does not close the
assignment out from under students. Re-validation still runs (debounced for the
starter, always for a solution, since the new solution *is* what validates).

**The authoring UI reads the assignment's language from ONE seed (v0.5.36).**
The browser editors had no notion of language at all: `pattern-family-editor.js`
contained the string "language" zero times, and `inputs-editor-core.js` had the
identical defect, so both parsed instructor input by Python's rules — `True` /
`False` / `None` plus a Python-repr rewrite — on every assignment. An R author
typing the boolean true stored the **string**, silently, in a value a generated
test then compares.

`AuthoringLanguageFacts` is now encoded into an `#assignment-language-seed`
script tag on both authoring pages, and `Public/authoring-language.js`
(`window.ChickadeeLanguage`) is the single reader. **Every value in the seed is
derived, never tabulated:** the scalar spellings come from
`JSONValue.literal(_:)` — the same call that renders the real generated test, so
the editor cannot show one spelling while the renderer emits another — kind
availability from `notebookCheckKindIsSupported` (the predicate the save-time
refusal uses, so the Add Test menu and the rejection cannot disagree), scan
support from `notebookFunctionScanSupport`, and evaluation support from
`PersonalizationEvaluator`.

The consequence worth knowing before touching this: **a seventh language needs
zero JavaScript edits.** The one exception is a new syntax-highlighting
grammar, when the bundle does not carry one yet. There is no per-language list in any authoring JS, and
the invariant is greppable (see the runbook's "The authoring UI: what you do NOT
have to do"). If a new *fact* is needed, add a field to `AuthoringLanguageFacts`
and derive it from whatever already owns the answer — do not answer it twice.
Both mistakes were made and undone here: the literals were nearly generated into
a JS table, and two capability flags shipped as hand-written bools before being
pointed at their real owners. `AuthoringLanguageFactsTests` asserts the
derivation.

**Auto-computing a case's expected value runs on the SERVER for every language
but Python** (`POST /instructor/:id/compute-expected`). The in-page evaluator is
a Python kernel; on another language it did not fail, it computed a *Python*
answer for a value compared against that language's result.
`PersonalizationEvaluator` already evaluates in every language behind an
exhaustive switch, so the fix was to route to it rather than grow a kernel per
language into the page. Python keeps the in-page path (faster, and its `None`-return and
non-round-trippable-type handling is behaviour existing assignments rely on).
Two stated limits: the drivers report values as their language's REPR (base R and
Lua have no JSON to serialize with), so a scalar round-trips into the Expected
cell and a composite may not — the client decides, using the same language-aware
reader hand-typed values go through; and automatic stdout capture is offered
where one expression expresses it (R's `capture.output`, Octave's `evalc`) and
reported unavailable where it does not.
