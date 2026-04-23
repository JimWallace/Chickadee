# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project follows Semantic Versioning.

## [Unreleased]

## [0.4.97] - 2026-04-23

### Fixed

- **Typing into the new section's name input no longer gets wiped by the debounced `PUT /suite` response.**  When the instructor clicked "+ Section" and immediately started typing a name, the debounced PUT fired 300ms later with whatever had been typed so far; the server echoed that value, and the post-PUT re-render overwrote the input with the echoed value — losing every keystroke the user made during the network round-trip.  Characters that "appeared then disappeared" is exactly what this looked like.  The re-render now captures the focused input's live value before normalising local state, re-applies it afterwards, and (when the live value differs from the server echo) schedules another push so the latest typing actually reaches the server.  Same guard protects `suite-display-name` edits on script rows.
- **Pattern family Edit / Delete buttons on suite rows work again on the v0.4.96 section-aware editor.**  `pattern-family-editor.js` bound its click handler to `#suite-config-body`, the single-tbody element that v0.4.96 replaced with the multi-section `#suite-sections` mount.  The handler silently skipped attachment because the element was gone — clicking the pencil or trash icon on a family row did nothing.  Accept either id now.

## [0.4.96] - 2026-04-23

### Added

- **Sections for test suites.**  Instructors can group the tests in an assignment into named sections ("Question 1", "Question 2", …) on the assignment edit page; each section renders as its own `.section-block` + `.results-table`, drag-drop works across sections, and an "+ Section" button creates new ones.  Sections have exactly one property — a name — and are purely a display-grouping concern: the runner still walks `testSuites[]` in order and the dependency graph is unchanged.  Student submission page groups results the same way, showing an `<h3>` heading above each section's result table so students can tell at a glance which tests belong to which question.  Assignments with no sections render identically to the pre-v0.4.96 layout (single unlabelled table on both the editor and the student page).  Items not yet assigned to a section appear in a trailing "Ungrouped" block — hidden when empty.  Deleting a non-empty section prompts a `confirm()` dialog and silently re-homes the items to Ungrouped.  New Core types: `TestSuiteSection` (id + name), optional `sectionID` on `TestSuiteEntry`, optional `sections: [TestSuiteSection]` on `TestProperties`.  `applyPatternFamilies` now takes a `sections:` parameter, rewrites stale `sectionID` references to `nil`, and enforces that items sharing a `sectionID` form a contiguous block in the authored array.  Pattern families inherit their section from the authored-item position — move the family row and every generated case follows.  Legacy manifests with no `sections` key decode with `decodeIfPresent` defaults so older runners remain compatible.

## [0.4.95] - 2026-04-23

### Fixed

- **Pattern family test results now render in-line with their prerequisite** in both the suite editor and the submission-view outcome list.  `topologicallySorted` was a FIFO Kahn queue: when a family declared `dependsOn: [publictest_prereq.py]`, the family's generated entries were enqueued *after* every other no-dep script, so a trailing `publictest_tail.py` cut in line and the family rendered at the end of the suite even though the instructor had authored it directly after its prereq.  Swapped the FIFO queue for an authored-position priority queue: at each step we pop the ready node with the smallest original index, which keeps the family next to its prereq whenever topology doesn't force a different order.  Regression guard: `testApply_familyWithDependencyStaysInlineAfterPrereq`.
- **Instructor assignments list — tighter action row.**  Icon-button padding dropped from `.3rem .45rem` → `.25rem .35rem` and the inter-button gap from `.4rem` → `.2rem` across every action row (unpublished / open / closed).  Gives the Name and Actions columns breathing room without changing button hit-targets meaningfully.
- **Suite-table drag-adopt now moves the row in `items[]`, not just in the visual tree.**  Before: "adopting" a parent (middle-drop) only set `dragItem.dependsOn = [targetID]` — the dragged row stayed at its original index in the client's `items[]` array and `visualOrder()` grouped it under its parent for the tree view, but the manifest (which is serialized from `items[]` on `PUT /suite`) saw the row at the tail.  A newly-created test appended to the bottom of `items[]` therefore appeared under its parent in the editor but "jumped to the bottom" of both the manifest and the submission view.  Drag-adopt now splices the dragged row immediately after its new parent in `items[]` so the tree view and the manifest stay in sync.

### Added

- **Live feedback on every variable row** in the pattern family editor.  Name input shows ✓ green "referenced as `$name`" when the identifier is valid, or red with a reason when it's not a Python identifier or duplicates another row.  Value input shows ✓ green "parsed as dict/list/…" with a preview when `JSON.parse` succeeds, or amber "Treated as a bare string — check your quotes" when the JSON falls back.  Instructors no longer have to save to find out whether they typed the dict correctly.
- **Arg-cell `$name` references light up as variable bindings.**  Green italic when the ref resolves to a declared variable (with a tooltip "Bound to family variable $name"); red when the variable isn't in the table yet (tooltip explains the fix).  Resolves live on every keystroke on either the arg cell or the variable row so the instructor sees the wiring take hold as they type.
- **Pyodide auto-compute resolves `$name` refs.**  Before: typing `$patients` in an arg cell broke auto-compute (the cell was passed as the literal string `"$patients"` to the solution).  Now the resolver reads the Variables table DOM at compute time, substitutes the declared value in, and calls the solution with the real dict / list.  When the instructor *finishes* typing the variable's value, auto-compute re-fires on every case row with an unresolved ref, so the Expected cell fills in without a manual refresh.  Empty defaulted-param cells are also correctly skipped during auto-compute so Python's own default binds in the solution call.

## [0.4.94] - 2026-04-23

### Added

- **Family-scoped variables in pattern families.**  Each family gets a Variables table above the Cases table where the instructor declares shared named values (dicts, lists, scalars) that every generated test in the family sees as a module-level assignment.  Arg cells reference them by typing `$name` — the renderer emits the bare identifier instead of the literal.  Keeps the patient-database / lookup-table pattern ergonomic without duplicating JSON across every case.  The spec hash includes `variables`, so editing one triggers the v0.4.93 auto-retest loop just like editing a case would.  New Core types: `FamilyVariable` plus parallel `PatternCase.argVarRefs: [String?]`.  Validation: variable names must be valid Python identifiers, unique within a family, and must not collide with any `paramName`; every `$name` reference must resolve to a declared variable.
- **Optional (defaulted) parameters in family cases.**  The scanner now records a parallel `paramHasDefault: [Bool]` flag per function parameter; the family editor renders those columns with a `— Python default —` placeholder and accepts empty cells.  The renderer switches from positional to kwarg form the moment a cell is left empty, so `def check(dob: str, currentDate: str = "20260301")` can be called with just `dob` — Python's own default binds at test time.  Spec encoding adds `argsProvided: [Bool]` on `PatternCase` (parallel to `args`); empty array preserves the pre-v0.4.94 "every arg required" behaviour so existing manifests round-trip unchanged.

### Fixed

- **Scan-notebook endpoint now forwards every field the scanner produces.**  The `FunctionResult` DTO dropped `paramTypes`, `returnType`, `isShadowed`, and the new `paramHasDefault` field, so the family-editor client saw them all as `undefined`.  That meant `coerceByType` fell back to strict `JSON.parse` on every cell, silently turning a bare `20260422` in a `str` column into `int(20260422)` — and the subsequent save generated a Python literal that failed validation against the function's `str` signature.  The root cause of the instructor-reported DOB-check family bug.  Regression guard: `testScanNotebookForwardsParamTypesReturnTypeAndDefaults`.
- **Reloading an edited family no longer silently drops string-typed values.**  Same root cause as above: with `paramTypes` now flowing, `renderTypedCellValue` displays string args unquoted and the subsequent readback coerces them back as strings (not `null`).

### Changed

- **"Hint (override)" column and "Default hint" textarea removed from the pattern family editor modal.**  Per-case hint text was noisy and under-used; the UI is simpler without it.  The underlying `PatternCase.hint` / `PatternDefaults.hint` fields stay in the Core model so already-deployed manifests round-trip unchanged and the renderer still emits a `Hint: ...` line in generated tests when the fields are non-nil.
- **Instructor assignments list — Status column tightened** from `min-width: 7.5rem` to `5.5rem` so the Name and Actions columns can breathe on narrower viewports.

## [0.4.93] - 2026-04-23

### Added

- **Auto-retest every student submission when the assignment's test suite changes.**  When an instructor revises an assignment — fixes a bug in a test script, tightens a pattern family's expected value, adds a case — every prior submission against that setup is automatically re-queued for the worker to regrade against the revised manifest.  Trigger lives on the assignment Save button (`POST /instructor/:assignmentID/edit/save`) and is gated on a manifest-hash compare against the new `test_setups.last_retested_manifest_hash` column, so cosmetic-only saves (renaming the assignment, moving the due date, swapping the notebook) don't fire a 150-row re-grade for nothing.  Excludes `kind = validation` submissions (the instructor's solution notebook follows its own `scheduleValidationAfterSuiteEdit` path).  Browser-graded submissions are handled automatically by the existing v0.4.56 worker backstop — flipping `status = "pending"` is enough to get them re-graded server-side via native `python3`.
- **`POST /instructor/:assignmentID/retest` endpoint and toolbar button.**  Manual sibling of the auto-trigger: a new refresh-arrow icon beside each open/closed assignment's Edit/Delete buttons re-grades every submission on demand.  Uses `force: true` so it works even when the auto-retest has already queued the same submissions (e.g. the instructor wants to re-run after an infrastructure blip, not after a suite edit).  Confirmation dialog inline so a misclick doesn't burn 10 minutes of worker time.
- **`retested_by_user_id` on submissions.**  Nullable UUID stamped on every retest — manual and auto — so the admin submission view can show "retested by <instructor> at <time>".  Existing `retested_at` column now has a paired actor column.
- **Shared `retestAllSubmissionsForSetup` helper** in `AssignmentHelpers.swift`, plus `manifestHash()` utility, used by both the endpoint and the auto-save trigger so the two paths can't drift.

### Fixed

- **Per-submission retest now stamps the instructor who clicked.**  The existing `POST /instructor/:assignmentID/submissions/:submissionID/retest` handler updates `retested_by_user_id` alongside `retested_at` for audit parity with the new batch path.

## [0.4.92] - 2026-04-23

### Fixed

- **Pattern families no longer get pushed to the bottom of the suite on publish from the Create Assignment page.**  `saveNewAssignment` rebuilds the test setup manifest from the form's raw-script list (which has no `generatedBy` markers by design) and then re-runs `applyPatternFamilies` to regenerate the family entries.  The re-run was invoked without `authoredItems`, so `applyPatternFamilies` hit the legacy branch, found no generated entries to anchor families against, and appended every family at the end of the suite via the "defensive" fallback loop.  Every family published from `/instructor/new` therefore landed below all raw scripts — and every submission's family-generated test outcomes rendered at the bottom of the Submission view, because outcome order mirrors `testSuites` order.  The publish flow now reconstructs `authoredItems` from the draft's original manifest (via new helper `authoredSuiteItemsFromDraftManifest`) and passes them to `applyPatternFamilies`, preserving each family's draft position.  Regression guard: `testApply_createPublishPreservesFamilyPosition` + `testApply_editingExistingFamilyPreservesMiddlePosition`.
- **Pattern family modal no longer shows `null` in cells when reopening an existing family.**  `readCasesFromTableRaw` — the lossy re-reader used when `applyFunctionSelection(preserveCases: true)` rebuilds the cases table — used strict `JSON.parse` to parse cell text.  Bare strings (`underweight`) and Python-literal sentinels (`True`, `None`) aren't valid JSON, so the reader silently substituted `null` for them, and then `addCaseRow` rendered `null` back into the cells.  The first save after reopen would then either overwrite the instructor's original values with `null` or throw a "missing value" validation error on the string columns.  `readCasesFromTableRaw` now uses the same type-aware `coerceByType` coercion as the strict save path, so string-valued cells round-trip correctly.
- **Family-level `dependsOn` survives a modal save.**  `readFamilyFromEditor` was constructing a fresh `PatternFamily` object without the `dependsOn` field — the modal doesn't expose it, but the server-side spec carries family-level prerequisites that propagate to every generated case.  Every modal save therefore wiped the family's deps.  `readFamilyFromEditor` now carries forward the existing family's `dependsOn` in edit mode.

## [0.4.91] - 2026-04-22

### Added

- **Pattern family editor on the Create Assignment page.**  The instructor can now author pattern families from `/instructor/new` before the assignment is published — previously families were an edit-only feature.  Three-part change:
  1. **Suite-table JS extracted to `Public/suite-table.js`.**  Phase 1b of the authoring-page parity refactor.  The ~620-line IIFE that owned drag/drop reorder, dep-adopt, tier/points/display-name inline edits, and `PUT /suite` persistence now lives in a shared module with a `window.initSuiteTable(config)` factory.  `onFamiliesChange` and `addExistingScript` are returned as methods (still wired to the legacy `window.chickadee*` globals so the existing pattern-family and script-editor modules keep working unchanged).
  2. **Draft-aware backend routes** (`Sources/APIServer/Routes/Web/AssignmentRoutes+Draft.swift`).  Sibling endpoints to the `:assignmentID`-scoped routes, identified by a `draftID` query parameter that resolves directly to the draft `APITestSetup`:
       - `GET /instructor/new/draft/suite?draftID=<id>`
       - `PUT /instructor/new/draft/suite?draftID=<id>`
       - `PUT /instructor/new/draft/families?draftID=<id>`
       - `POST /instructor/new/draft/scripts?draftID=<id>`
       - `DELETE /instructor/new/draft/scripts/:filename?draftID=<id>`
     The shared helpers (`applyPatternFamilies`, `buildSuitePayload`, `listZipEntries`, …) already operate on `APITestSetup`, so the handlers are thin wrappers — same validation, same zip/manifest mutation.  They skip the `scheduleValidationAfterSuiteEdit` call the assignment-scoped handler makes because drafts don't have a validation pipeline yet (that kicks in on publish).
  3. **Create page wired to the shared family-editor module.**  New "New Family" button in the Test Suite toolbar; the family modal HTML is duplicated for now (Leaf partial `#extend("includes/…")` hit a cycle-detection false positive in v0.4.90 — revisit later); `Public/pattern-family-editor.js` is initialised with the draft URLs.  After a family save, the page reloads so the server-rendered suite table picks up the newly generated scripts.  Once the suite table itself migrates to `Public/suite-table.js` on this page (phase 3b), we can switch to an in-place sync.

### Fixed

- **Draft pattern families now survive the create→publish transition.**  `saveNewAssignment` was calling `makeWorkerManifestJSON(testSuites:…)` without forwarding the draft setup's `patternFamilies`, so on publish the manifest was rebuilt with an empty `patternFamilies` field and `applyPatternFamilies` was never re-run — generated scripts lost their family provenance (same class of bug as v0.4.77's saveEdit fix).  The finalize flow now (a) reads `patternFamilies` from the existing draft manifest, (b) passes them through to `makeWorkerManifestJSON`, and (c) re-runs `applyPatternFamilies` after save so the regenerated scripts land in the final zip.

### Changed

- **`safeScriptFilename(from:)` is now file-internal** (was `private`) so `AssignmentRoutes+Draft.swift` can reuse the same `:filename` sanitisation logic.  No behaviour change.

## [0.4.90] - 2026-04-22

### Changed

- **Pattern family editor JavaScript extracted to `Public/pattern-family-editor.js`.**  Phase 1 of the Create/Edit authoring-page parity refactor.  The ~950-line IIFE that drove the family modal (function-scan flow, type-aware coercion, Pyodide auto-compute, case table rendering, PUT /families persistence) was duplicated effort away from being shared — every family polish release had to land in `assignment-edit.leaf` and would have to land a second time when the Create Assignment page gained the feature.  The module now exposes a `window.initPatternFamilyEditor(config)` factory that both pages will call with their own `assignmentID` (edit mode) or `draftID` (future create mode) and URL resolvers.  Edit page behaves identically; no user-facing change.
  - Config shape: `{ assignmentID?, draftID?, csrfToken, initialFamilies, urls: { solutionNotebook, scanNotebook, putFamilies }, onFamiliesChange }`.  The `urls` functions let the host dispatch to assignment-scoped (`/instructor/:id/families`) or draft-scoped routes without the module needing to know which mode it's in.
  - `window.chickadeeSyncFamilies` stays as the suite-table sync hook but is now invoked through the `onFamiliesChange` callback, so future modules can swap it for a different sink.
  - Leaf template keeps the modal HTML inline.  An attempt to extract the markup into a `#extend("includes/pattern-family-editor")` partial hit a LeafKit cycle-detection false positive; deferred until the underlying LeafKit issue is understood.
  - Next phases (separate PRs): extract the suite-table IIFE (~590 LOC) similarly, add draft-aware backend routes, then light up pattern families on the Create Assignment page.

## [0.4.89] - 2026-04-22

### Fixed

- **Editing an existing family no longer swaps onto the wrong overload's columns.**  v0.4.88's `applyFunctionSelection` preferred the non-shadowed (runtime-live) match by name, which meant reopening a family that had been authored against an earlier arity (e.g. a `tax(stickerPrice)` family in a notebook that later redefines `tax(stickerPrice, exempt, extra)`) silently rewrote the case table to 3 columns, orphaning the saved 1-arg cases.  Edit mode now first tries to match a scanner entry whose paramName count equals the family's saved `paramNames.length`.  If none matches, it still falls back to the non-shadowed pick + name-only pick, preserving the v0.4.88 behaviour for new families.
- **Pyodide auto-compute no longer dies on a mid-notebook exception.**  `ensureSolutionLoaded` used to concatenate every code cell and `runPython` the result as one block, so the first failing statement killed the entire load — which meant a pedagogical notebook with `assert abs(tax(1.00, False, False) - 1.13) < 0.001` that runs *before* `tax` gets redefined to take 3 args would raise TypeError, reject the solution-load promise, and prevent `needsWarningLabel` (defined in a later cell) from ever landing in Pyodide's namespace.  Auto-compute for families targeting `needsWarningLabel` then silently failed to populate the Expected column.  Cells now run one-at-a-time with a per-cell catch that swallows usage-code failures — only the *final* function definitions matter for auto-compute, so dropping assertion failures is safe.

## [0.4.88] - 2026-04-22

### Added

- **Type-aware coercion in the pattern family editor.**  `NotebookFunctionScanner` now returns per-parameter type annotations (`paramTypes: [String?]`) and the return-type annotation (`returnType: String?`) alongside the existing `paramNames`/`hasTypeHints`/`hasDocstring` fields (both decoded with `decodeIfPresent` so pre-v0.4.88 clients roundtrip unchanged).  The family editor uses them for two things:
  - **Column headers show the type** — `bmi: float`, `exempt: bool`, `Expected: list[int]` — so the instructor sees what each cell expects without scrolling back to the solution notebook.
  - **Cell values coerce to the declared type.**  A new `coerceByType(raw, typeHint)` client-side helper normalises `Optional[T]` / `Union[T, None]` / `T | None` down to `T`, strips generic parameters (`list[int]` → `list`), and dispatches by kind: `bool` (accepts `True`/`true`/`"True"`/`1` and their falsy counterparts), `int` (strict integer spellings), `float` (decimal + scientific), `str` (handles quoted literals), `list`/`tuple`/`dict`/`set` (JSON parse).  Unknown / missing type hints fall back to the existing `parseTypedCellValue` — so hint-free notebooks continue to work exactly as before.  Expected values coerce via `returnType`.  The same helper is used by the Pyodide auto-compute path so args flow to `fn(*args)` in the right shape.
- **Python-style literal accepted in untyped cells.**  Even when no type annotation is available, typing `True` / `False` / `None` (Python's capitalised spellings, not JSON's lowercase) now parses as the corresponding boolean/null rather than falling through to a string.  Previously a `bool`-returning family test would fail with `expected 'True' got: True` because the expected value had been silently stored as the string `"True"` and rendered as `expected = "True"` in the generated script.

### Changed

- **Family editor disables shadowed function entries.**  When a function name is defined multiple times in the solution (common in pedagogical notebooks that extend a function across sections — e.g. Lab 3's `tax` with 1 arg then 3 args), only the LAST definition is callable at runtime.  The scanner now marks earlier occurrences with `isShadowed: true`.  The dropdown labels them `⚠ redefined later (will not be callable)` and sets `disabled` on the option so the instructor can't accidentally pick one.  `applyFunctionSelection` also prefers the non-shadowed match by name so edit-mode opens against the live definition.

## [0.4.87] - 2026-04-22

### Fixed

- **Inline display-name rename in the suite editor no longer loses focus or drops characters mid-typing.**  The v0.4.83 fix preserved caret position across the `renderTree()` rebuild, but the underlying race wasn't actually in `renderTree()` — it was that the `input` event listener fired a debounced `PUT /suite` on every keystroke.  If a 300 ms debounced PUT happened to land while the user was still typing, the server's echoed response overwrote `items[]` with the older value, `renderTree()` rebuilt the row with that stale value, and everything the user had typed *after* the PUT fired was silently lost.  The tier `<select>` and points `<input>` cells never had this bug because they use `change` events (commit on blur).  Display-name now follows the same pattern: `input` still updates the in-memory `items[]` entry so other actions (drag, tier change) send the current typed value, but the actual `PUT /suite` is deferred to `change` (blur / Enter), eliminating the typing/response race.

## [0.4.86] - 2026-04-22

### Added

- **"Structural Check" script template** for verifying properties of the student's source code via AST introspection.  Useful when the assignment rubric requires *how* the student wrote the code, not just *what it returns* — parameter count, type hints on parameters, return-type annotation, docstring, minimum assert-count inside a function body, minimum module-level assert-count.  Each check is a toggle in the generated script (set to `None` to skip, or a value to enable).  Module-level asserts are counted even when `NotebookExtractor` has quarantined them inside an `if __name__ == "__main__":` block (the walker descends into compound statement bodies).  Renders via `import ast; import inspect; tree = ast.parse(inspect.getsource(student_module))` — no extra student module evaluation, just static analysis.

### Fixed

- **Performance template no longer emits invalid Python** when the function under test takes parameters.  The placeholder call args used to render as `student_module.fn(None  # TODO: replace, None  # TODO: replace)`, which `ast.parse` rejects because the inline `#` comment swallows the rest of the line (including the closing `)` and second argument).  Placeholder args are now plain `None` values; the TODO guidance moved to a separate comment line above the call.  New `testAllPythonTemplateTypes_parseAsValidPython` regression test pipes every rendered template through `python3 -c 'ast.parse(...)'` so a future template can't regress the same way.

## [0.4.85] - 2026-04-22

### Fixed

- **CI hotfix**: `testAllTemplateInfos_pythonContainFunctionName` iterates every Python template returned by `allTemplateInfos()` and asserts each contains the supplied function name.  v0.4.84 added `.variableEquality` — a template that intentionally doesn't reference `functionName` (it targets a module-level variable, not a function call) — so the assertion began failing on both the `api-tests` and `api-tests-postgres` CI jobs.  The sibling `testAllPythonTemplateTypes_containFunctionName` was updated in v0.4.84 but this one was missed; now it filters the new kind out the same way.

## [0.4.84] - 2026-04-22

### Added

- **`.variableEquality` pattern-family kind** for assignments that ask students to define module-level variables (e.g. `beats = 5`) rather than functions.  The instructor picks "Variable equality (module-level variable)" from the family editor's kind dropdown; the Function dropdown is hidden; the cases table takes a single "variable" column (variable name) plus the Expected column — no per-parameter args and no function signature scan.  Each enabled case renders a generated test that looks up `getattr(student_module, variable_name, _MISSING)` with a sentinel default so "not defined at all" is distinguishable from "defined as None", and falls through to an equality check against the case's expected value.  The `NotebookExtractor` already preserves simple module-level assignments at import time (per v0.4.38), so `student_module.beats` is readable by the generated test.
  - New `PatternKind.variableEquality` Core enum case; decoded with `decodeIfPresent … ?? nil` so legacy manifests roundtrip unchanged.
  - `ManifestValidation.validatePatternFamilies` gains kind-specific rules for variable families: each case's `args` must be exactly `[.string(name)]` where `name` is a non-empty valid Python identifier.  Skips the otherwise-required `isValidPythonIdentifier(functionName)` check since variable families don't call a function.
  - Renderer `renderVariableEquality` in `PatternFamilyRenderer.swift` emits the `getattr` sentinel pattern, labelled rich-feedback messages, and the family hint — matching the shape of `renderBoundaryEquality` / `renderApproximateEquality`.
  - Editor UI in `assignment-edit.leaf` adds `updateKindVisibility()` to hide the function dropdown when the kind is variable-equality, and `applyKindDefaults()` to reset the case-table layout when the instructor switches kinds.  Family id auto-derives from the family name (since there's no function name to derive from).  Pyodide auto-compute of the Expected column is skipped for variable families — the instructor types the expected value directly.
- **"Variable Equality" single-script template** in the New Script modal for instructors who prefer a one-off test over a family.  Generates boilerplate around the same `getattr` + sentinel check.

### Fixed

- **Python script templates now start with a `#!/usr/bin/env python3` shebang.**  Extensionless filenames (e.g. a test script saved as "beats" without `.py`) were being dispatched through `/bin/sh` on the runner and failing cryptically — `variable_name: not found`, `Syntax error: "(" unexpected` — because shell can't read Python.  Per v0.4.73 a Python shebang routes the script through the Python runtime regardless of filename.  All eight Python templates (`exists`, `correctness`, `cornerCases`, `exception`, `typeCheck`, `performance`, `differential`, `variableEquality`) now emit the shebang as their first line; new `testAllPythonTemplateTypes_startWithPythonShebang` regression test guards against future templates forgetting it.  Also added `testAllPythonTemplateTypes_doNotImportChickadee` to catch any template that tries `from chickadee import …` (the `passed`/`failed`/`errored`/`require_function` builtins are injected by the test runtime, not importable).

## [0.4.83] - 2026-04-22

### Added

- **Pattern family editor auto-computes the Expected column from the solution notebook.**  When the instructor picks a function and types per-parameter input args, the family editor lazy-loads Pyodide (first use only, ~10 MB one-time download from `cdn.jsdelivr.net/pyodide/v0.27.0`), fetches the solution notebook via the existing `GET /instructor/:assignmentID/files/solution` endpoint, extracts its code cells (skipping markdown + IPython `%`/`!` magic lines), and calls `fn(*args)` in-browser to fill the Expected cell.  Auto-filled cells are visually muted (grey text) with a "Auto-computed from solution notebook" tooltip; once the instructor types directly into the Expected cell, `data-manual="1"` is set and subsequent auto-compute won't clobber the value.  Clearing a manually-set cell re-enables auto-compute for that row.  Exceptions from the solution (e.g. `raises TypeError`) leave the cell empty and surface the error message in the cell's `title` tooltip.  Debounced 400 ms; runs only in typed-column mode (not the fallback JSON-args field).

### Fixed

- **Inline rename in the suite editor no longer loses focus after a short delay.**  The live `PUT /instructor/:assignmentID/suite` flow debounced a suite-list re-render after every keystroke via `renderTree()` → `body.innerHTML = …`, which blew away the `<input>` the instructor was still typing into.  `renderTree()` now captures the active element's row (by `data-id`) and cell class + caret position before the `innerHTML` rebuild and restores focus after, so keystroke-triggered pushes no longer interrupt mid-typing.  Also benefits the tier `<select>` and points `<input>` cells (less visible there because they use `change` events, but the same re-render path now preserves their state).

### Changed

- **"New Script" modal drops the tier and points inputs** — matching the New Family modal, which doesn't ask for either at authoring time.  New scripts default to `tier = public`, `points = 1`; the instructor tunes both via the inline suite-row controls after creation.  Server-side defaults were already in place (`normalizeTier(body.tier, isTest:)` and `max(1, body.points ?? 1)`), so the client simply stops sending the fields when the DOM elements are absent.

## [0.4.82] - 2026-04-21

### Fixed

- **Assignment due dates now render in America/Toronto on every page**: the instructor dashboard, student dashboard, validate page, submission history, and admin course detail all constructed a `DateFormatter` without setting `timeZone`, so due dates were formatted in the server's local timezone (UTC in production) while the edit form correctly used Toronto time via `dueAtLocalInputString()`.  Each of the five sites now calls the existing `waterlooDateTimeFormatter()` helper (`America/Toronto`, `en_CA`, medium/short), matching the value the instructor typed into the edit form.
- **Older runners no longer crash decoding manifests that contain new `PatternKind` cases**: `TestProperties.patternFamilies` was being shipped verbatim in the `Job` payload to runners, even though the runner never uses it (families expand into concrete `.py` files server-side before the zip is built).  That coupled every runner binary to every `PatternKind` case the server had ever introduced — adding `.approximateEquality` in v0.4.80 made v0.4.75/v0.4.79 runners throw on `JSONDecoder().decode(TestProperties.self, ...)`, leaving claimed validation submissions stuck in `assigned` with no result ever reported.  `TestProperties.runnerSanitized()` now returns a manifest with `patternFamilies: []`, and `POST /worker/request` uses it when building the job payload, restoring rolling-deployment safety.
- **Stuck `assigned` submissions are now reclaimed automatically**: previously, a runner that claimed a job and then crashed, vanished, or failed to report results left the submission permanently pinned to `status = "assigned"` — no server-side sweep ever returned it to the pending queue.  New `StuckSubmissionReaperMonitor` (mirrors the `AssignmentDeadlineMonitor` lifecycle pattern: startup sweep + 60 s periodic task, registered via `StuckSubmissionReaperLifecycleHandler`) scans for submissions in `assigned` whose `assigned_at` is older than the configurable max-age (default 10 minutes) and resets them to `pending` with `worker_id` and `assigned_at` cleared, logging a warning with the previous worker ID.

### Changed

- **Assignment edit, new-assignment, and submit pages now use the full 900px page width**: `.form` applies a 620px cap intended for narrow inline sub-forms (publish form, login, register), but three top-level page forms were inheriting it and rendering noticeably narrower than the instructor/admin dashboards.  A new `.form--wide` modifier cancels the max-width cap; `assignment-edit.leaf`, `assignment-new.leaf`, and `submit.leaf` adopt `class="form form--wide"` so their content uses the full `.main` container width.  Login and register stay narrow.

## [0.4.81] - 2026-04-21

### Changed

- **Pattern-family rows now match script rows visually**: the ⟳ badge is gone, the name column no longer prefixes the case count with `functionName()`, the `↳` dependency badge is suppressed on family rows (the dependency is already expressed by the indent/connector), and the first-cell blue background is removed.  The **Visibility** column on a family row is now a `<select>` — editing it updates `family.defaults.tier` and fires a live `PUT /suite`, matching the inline editing experience of raw scripts.  The "Default tier" field is removed from the Pattern Family Editor modal.

### Fixed

- **Family row position survives a modal save.**  Saving edits from the pattern-family modal hits `PUT /instructor/:id/families`, which previously ran the legacy `applyPatternFamilies` ordering path and appended every family at the end of `testSuites`, clobbering the instructor's hand-placed drag-drop position.  The legacy path now reconstructs authored ordering from the existing manifest: each family is emitted at the position of its first existing generated entry, and only brand-new families are appended at the end.
- **Suite edits re-trigger validation.**  `PUT /suite` and `PUT /families` now enqueue a fresh validation submission when a solution notebook is available, matching the pre-v0.4.79 behaviour where every suite save ran the solution against the new manifest.  Debounced server-side: a new submission is skipped when a pending (unclaimed) validation already exists for the setup, since the runner's manifest-hash cache key means the in-flight submission already pulls the updated zip + manifest on download.

## [0.4.80] - 2026-04-21

### Added

- **`.approximateEquality` pattern-family kind** for float-returning functions.  The instructor picks "Approximate equality (float tolerance)" from the new kind dropdown in the family editor modal, optionally sets a tolerance (default 1e-6), and each generated test checks `abs(result - expected) <= tolerance` with a dedicated `isinstance` guard for non-numeric returns.  Failure messages include the tolerance *and* the actual delta so students see exactly how far off they are (`value outside tolerance` / `expected: 22.857 (±0.01)` / `got: 23.0` / `delta: 0.143`).  `PatternDefaults.tolerance: Double?` is decoded with `decodeIfPresent … ?? nil`, so legacy manifests roundtrip unchanged; validation rejects negative or non-finite tolerances.
- **Editable Pts on family rows** in the suite editor.  The previous read-only `<span>` becomes an `<input type="number">` whose value edits `family.defaults.points` and fires a live `PUT /suite`.  Per-case point overrides in the family editor modal continue to take precedence via `PatternCase.resolvedPoints(defaults:)`.

### Fixed

- **Regression guard for authored suite-list order**: `testApply_authoredOrderPreservedInManifestAndOutcomes` pins that authored `[script_a, family(3 cases), script_b]` lands in the manifest as `[script_a, fam_01, fam_02, fam_03, script_b]` — `topologicallySorted` never re-orders entries that have no dependencies, and the runner walks `testSuites` in array order, so submission results always match the instructor's drag-drop order.  Assignments imported from pre-v0.4.79 Chickadee may still have their families appended at the end of `testSuites`; dragging the family row once on the edit page persists the new authored order.

## [0.4.79] - 2026-04-21

### Changed

- **Assignment suite editor unified around a server-authoritative model.** Raw scripts and pattern families now live in a single ordered list in the suite table — drag-reorder, drop-to-adopt-as-dependency, and tier/points/displayName edits all persist live through the new `PUT /instructor/:assignmentID/suite` endpoint.  The old client-side `#suite-config-field` JSON blob and the `/edit/save` suite-rebuild path are gone; the main "Save" button is relabeled **"Save & Validate"** and now only handles assignment name, due date, notebook uploads, and validation-submission enqueue.  Server response from `PUT /suite` returns the reconciled state so the client never drifts.

### Added

- **Dependencies across scripts and families.**  `dependsOn` entries accept a new `family:<id>` token in the authored form; the server expands these to the family's enabled generated filenames before persisting the manifest, so the runner still sees only concrete script names.  Families may also declare their own `PatternFamily.dependsOn: [String]` which every generated case inherits.  Authored-graph cycle detection rejects self-referential families, script↔family cycles, and family↔family cycles.  Editor UI: drop a row onto a family to adopt `family:<id>`, drop a family onto a script to have every case inherit that prereq.
- **`GET /instructor/:assignmentID/suite`** returns the author-facing view of the suite list — one row per script or family, in manifest order, with `family:<id>` tokens re-collapsed from expanded filename sets in `dependsOn`.  The edit page seeds the editor state from the same payload embedded as JSON at load time.

### Removed

- **`#suite-config-field` hidden input and the `syncConfig()`/`chickadee:before-multipart-submit` pipeline.**  `saveEditedAssignment` no longer reads `suiteFiles[]` / `suiteConfig` multipart fields — clients built against v0.4.78 or earlier will find that suite edits sent via the old Save button are silently ignored.  Migrate to `PUT /suite` for suite changes.

## [0.4.78] - 2026-04-21

### Fixed

- **Pattern family cases accept bare-typed values**: the per-parameter columns in the pattern family editor previously required strict JSON, so typing `underweight` in an expected cell raised `JSON Parse error: Unexpected identifier "o"` and blocked Save.  Each typed column now accepts raw values — numbers, booleans, `null`, arrays/objects, and **bare strings without surrounding quotes** — so `bmi=18.49`, `expected=underweight` just works.  Complex values can still be written as JSON (`[1, 2]`, `{"k": 1}`).  Round-trips through re-opening the modal display strings without quote noise.
- **Family rows now stay visible in the Test Suite list**: the client-side suite-list JS was rebuilding the `<tbody>` on every render and only knew about raw-script rows, so server-rendered family rows vanished as soon as `initFromDOM()` ran.  `renderTree()` now detaches and re-inserts family rows across the rebuild so families appear alongside scripts in the suite list, where they belong.

## [0.4.77] - 2026-04-21

### Fixed

- **Pattern families survive the "Save" button on the assignment editor**: clicking Save (which rebuilds the test setup zip from the visible suite rows and rewrites the manifest) was silently wiping both the family spec in `patternFamilies` and every generated `.py` file in the zip, so saved families never appeared in the test suite after a round-trip.  `saveEditedAssignment` now forwards the existing `patternFamilies` into the rebuilt manifest and re-runs `applyPatternFamilies` so the generated scripts are regenerated back into the zip.  Each generated case continues to produce its own `TestOutcome` row with the case label as the test name, so per-case results appear as distinct tests in the submission view.  Regression guard: `testApply_surviveEditSaveManifestRebuild`.
- **`FamilySuiteRow.caseCountText` was missing from the Leaf context**: the computed property was dropped by the synthesized `Encodable`, leaving the suite-table row's subtitle blank.  Replaced with an explicit `encode(to:)` that emits the field.

## [0.4.76] - 2026-04-21

### Changed

- **Pattern family editor redesigned**:
  - "New Family" moved into the Test Suite header alongside "New Script" and "Upload"; the separate Pattern Families section is gone.  Families now render as dedicated rows inside the Test Suite table (one row per family, distinct styling with ⟳ badge) showing family name, function signature, case count, default tier, and total points.  The N generated `.py` entries no longer clutter the list — the family row represents them collectively.
  - Function is picked from a dropdown populated by scanning the assignment's solution notebook (reuses the existing `/instructor/scan-notebook` endpoint).  Selecting a function auto-fills the family id and parameter list, and rebuilds the cases table with one column per detected parameter — so instructors enter individual typed values (`18.49`, `"underweight"`) rather than composing a JSON array by hand.
  - Case keys are now auto-generated (`01`, `02`, …) as rows are added/reordered; the Key column is gone from the editor.  Fixes a 422 error when a user saved with an empty key field.
  - Save errors from the server (validation 422s) are now parsed out of the HTML error page and shown as a single-line status in the editor instead of the raw HTML.

## [0.4.75] - 2026-04-20

### Fixed

- **`require_function(name, num_args=…)` now works**: the exists-template kwarg previously raised `TypeError: unexpected keyword argument 'num_args'` because the runtime helper only accepted `name`.  `require_function` now optionally validates the student function's positional arity and emits a student-friendly `errored(…)` on mismatch.  Added a drift-guard test that fails if any template passes a kwarg the runtime doesn't accept (#373).

### Changed

- **Rich per-test failure feedback**: the Python test-runtime's `failed(msg)` / `errored(msg)` helpers now route multi-line messages through stdout (so they land in the outcome's `longResult`) and use the first non-empty line as the `shortResult` summary.  The `correctness`, `exception`, and `typeCheck` templates in the script editor were rewritten to the single-case rich-feedback shape (labelled `input:` / `expected:` / `got:` / `Hint:` lines, separate exception-handling branch, `isinstance` guard where relevant).  `cornerCases` per-case messages gained the same labelled structure (#374).
- **Assignment-new generator uses server-rendered templates**: the client-side `genPyTemplate` JS was replaced with a lookup into the `templates` array returned by `POST /instructor/scan-notebook`, eliminating the duplicated template renderer that caused #373 in the first place.  The stale inline Python templates in the assignment edit view's `INLINE_TEMPLATES` cache were removed; the editor now fetches templates from `/instructor/script-templates` so the server is the single source of truth.

### Added

- **Pattern-generated test families** (#375): instructors can now define a family of similar tests from a compact specification — one function, shared defaults, a table of cases — and Chickadee expands each enabled case into an ordinary Python test script at save time.  Generated scripts live in the test setup zip alongside hand-written ones and run through the existing worker pipeline with no runner changes.
  - New Core types: `PatternFamily`, `PatternCase`, `PatternKind` (`.boundaryEquality` is the v1 template; uses a single-arg equality check in the rich-feedback format introduced for #374).  `TestProperties.patternFamilies` carries the canonical spec; `TestSuiteEntry.generatedBy` marks generated entries.
  - Rendering is deterministic: stable filenames (`{tier}test_{familyID}_{caseKey}.py`), SHA-256 `spec_hash` embedded in the generated script header, sorted-key JSON encoding for family storage.
  - Pattern family editor UI in the assignment editor: a "Pattern Families" section below the test suite table with an "Add Family" button, a modal editor for family metadata + a dynamic cases table (args and expected as JSON literals), and a "Generated" provenance badge + read-only treatment on generated rows.
  - Raw-script edit/delete endpoints now return `409` with "edit the family" when the target entry has `generatedBy` set, so the family editor is the only mutation surface for generated scripts.
  - Cache invalidation for free: the runner's setup cache key incorporates manifest bytes, so family edits change the key and runners refetch the zip.  Covered by `testApply_addFamilyWritesScriptsAndChangesManifestHash`.

## [0.4.74] - 2026-04-20

### Fixed

- **Solution notebook filenames stay visible after upload**: the assignment edit page now displays the original uploaded validation solution filename instead of falling back to the internal draft name `solution.ipynb`.
- **Runners pick up every saved script change**: worker setup download versions now hash the actual setup ZIP contents, preventing stale runner cache hits when edited scripts keep the same file size or timestamp granularity.

## [0.4.73] - 2026-04-19

### Fixed

- **Generated and uploaded assignment tests now persist from the visible suite list**: create/edit assignment saves now submit the same queued suite files shown on screen, preventing generated function-exists tests from disappearing after Save & Validate.
- **Extensionless Python test scripts now run as Python**: files such as `BMI Boundary Cases` with a `#!/usr/bin/env python3` shebang are classified as runnable tests and dispatched through the Python test runtime instead of `/bin/sh`.

## [0.4.72] - 2026-04-19

### Fixed

- **New Script tests now validate with the active test suite**: instructor-created scripts are validated from the current manifest-backed test suite, and worker setup downloads/cache keys now include a setup version derived from the manifest and zip metadata. This prevents workers from pairing an updated manifest with a stale cached setup bundle after scripts are added or edited in place.

## [0.4.71] - 2026-04-19

### Changed

- **Student assignment links now use stable vanity URLs**: assignments now store a per-course unique slug so student-facing links can use human-readable paths like `/CS101/lab-1-intro`. Slugs are backfilled for existing assignments, remain stable when titles change, and receive numeric suffixes when duplicate titles would collide.
- **Student dashboard assignment actions now point at vanity paths**: notebook, submit, and history actions prefer `/COURSE/assignment-slug` routes while the existing canonical `/testsetups/...` handlers remain available for compatibility.

## [0.4.70] - 2026-04-18

### Changed

- **Student submit and assignment actions polished**: the submit page now shows the assignment title instead of the raw setup ID and no longer includes the browser-run helper link; student dashboard assignment actions now use neutral icon styling with a clearer upload glyph.

### Fixed

- **Browser-graded first-open notebook flow remains available**: the student dashboard keeps the browser edit action visible before a student has existing notebook work, allowing the notebook route to seed a fresh working copy from the assignment notebook. Added regression coverage for this path.

## [0.4.69] - 2026-04-18

### Changed

- **Student assignment actions now use icon buttons**: runner-graded assignments now show compact `edit` and `upload` icon actions in that order, and browser-graded assignments use the edit icon instead of the old "Open & Submit" text button.

## [0.4.68] - 2026-04-18

### Fixed

- **Create assignment: notebook upload no longer breaks after Codex 0.4.67 merge**: the JS submit handler was intercepting draft-action form submissions (notebook uploads) because `wireNotebookUpload` calls `form.requestSubmit()` without a submitter, making `e.submitter` null. The handler then deleted the file from `FormData` before posting, causing the server to return "Select a solution notebook to upload". Fixed by bailing out of the custom fetch path when the form action targets the `/draft` endpoint.
- **Detect Functions: generated tests no longer drop existing draft tests from the manifest**: when a config row used `name` (for an "existing" source item) instead of `index`, `SuiteConfigRow` failed to decode (non-optional `index: Int`), causing the fallback path to run and silently omit all pre-existing draft tests. A new `mergeExistingFilesIntoSuiteFiles` pre-processing step extracts named files from the draft ZIP, appends them to the uploaded file list, and rewrites their config rows with correct numeric indices before the ZIP and manifest are built.

## [0.4.67] - 2026-04-18

### Fixed

- **Validation submissions now ignore empty draft-only notebook upload parts**: the create-assignment page no longer includes `assignmentNotebookFile` / `solutionNotebookFile` in the final `Create & Validate` `FormData`, and the server now ignores empty uploaded notebook filenames when resolving the validation submission artifact. This prevents draft-backed solution notebooks from being queued with bad raw-file metadata and makes validation filename handling consistent across local and remote runners.
- **Raw submission filenames are now sanitized consistently before storage and runner staging**: student uploads, validation submissions, and worker-side raw-file staging now all collapse to safe basenames with sane fallbacks, preventing path-like or empty filenames from interfering with `.ipynb` extraction.

## [0.4.66] - 2026-04-17

### Fixed

- **Assignment link button now copies vanity URL**: clicking the link icon on the instructor assignments page previously copied a raw `/testsetups/{id}/submit` URL. It now copies the human-readable vanity URL (e.g. `https://chickadee.uwaterloo.ca/CS101/lab1intro`) that resolves via the `/:courseCode/:assignmentSlug` route.

## [0.4.63] - 2026-04-17

### Fixed

- **Notebook upload on create-assignment page now reliably posts to the draft endpoint**: clicking Upload for an assignment or solution notebook was submitting to the main save endpoint in some browsers (notably Safari), triggering full form validation (assignment name, both notebooks required) on what should be a single-file draft save. The wiring now explicitly sets `form.action` and calls `form.submit()` instead of relying on `formaction` on a hidden submit button.

### Changed

- Removed the "The uploaded solution is validated immediately by a runner…" hint text from the bottom of the create-assignment page.
- Admin user detail page now has a **Delete User** button. Deletes the user's enrollments and record; the account is recreated automatically on next SSO login. Intended for cleaning up corrupted SSO identity records.

## [0.4.62] - 2026-04-17

### Changed

- Version bump.

## [0.4.61] - 2026-04-14

### Fixed

- **Syntax errors in student submissions now shown to students**: when a notebook submission contains a Python syntax or indentation error that prevents the module from loading, the full traceback (file, line number, error type) is now surfaced in `longResult` so students can diagnose and fix the error. Previously only an internal harness message was shown.

## [0.4.60] - 2026-04-13

### Fixed

- **APITests boot the achievements schema again**: test app setup now registers `CreateClassAchievements()` alongside the rest of the base migrations, fixing the missing-table failure that broke web/admin test runs after the achievements feature landed.
- **Notebook working copy now updated on every browser submission**: `submitBrowserResult` previously never wrote back to the student's server-side working copy, so students returning to an assignment (or opening it on a different device) were always re-seeded with the blank starter template regardless of prior submissions. The working copy is now updated with the student's own notebook cells after each successful browser result.
- **Notebook sync no longer clobbers unsaved local edits**: `syncNotebookFromServerSnapshot` unconditionally overwrote JupyterLite's IndexedDB on every page load, destroying edits made in a previous session. It now checks `contents.get()` first and skips the write if the browser already holds a valid notebook, preserving in-progress work. First-time visitors and different devices still receive the server copy when their local storage is empty.
- **Submit button disabled until notebook is ready**: the Submit button is now disabled on page load and re-enabled only after `syncNotebookFromServerSnapshot` completes (with a 15-second hard fallback). This closes a race condition where students could click Submit before their saved notebook had loaded into the editor, causing the blank starter template to be submitted instead of their work.
- **Worker queue depth metric no longer counts browser-graded submissions**: `workerModeTestSetupIDs` checked only that a test setup existed in the database without inspecting `gradingMode`, so browser-graded pending submissions were incorrectly included in the worker queue depth. The function now decodes the manifest and excludes browser-mode setups.
- **Runner detail page improvements**: added "Online since" uptime field to the runner header; added a "User" column to the Recent Jobs table (batch-fetched from `APIUser`); removed the redundant "Prep Stages" and "Tests" columns; removed the always-empty "Last Heartbeat" column from Recent Snapshots.

## [0.4.59] - 2026-04-12

### Fixed

- **Runner version now reflects the deployed build in all result payloads**: `runnerVersion` in `TestOutcomeCollection` was hardcoded to `"shell-runner/1.0"` in the success and error paths; it now uses `ChickadeeVersion.current`, matching the heartbeat path. The admin runner dashboard and per-submission results will consistently show the running version.

## [0.4.58] - 2026-04-12

### Changed

- **Assignment create page fully redesigned to match the edit page**: the create form now uses the same compact `results-table` layout as the edit page — large inline name field, top-right action buttons, notebook rows with Edit/Clear, suite table with editable display names and Upload/New Script toolbar, and CodeMirror 6 modal for client-side script authoring. Platform and architecture fields removed. Runner requirements shown as compact inline labels.

### Fixed

- **AssignmentRoutesTests updated for redesigned create page**: tests that checked for removed HTML elements (`Notebook Composer`, `<th>Tier</th>`) updated to match the new structure.

## [0.4.57] - 2026-04-12

### Fixed

- **JSON footer stripped from student-visible test output**: the `{ "shortResult": ..., "score": ... }` line emitted by test scripts was previously shown verbatim in the output box. It is now parsed and removed before building `longResult`, so students see only human-readable stdout/stderr.
- **`:latest` Docker tag now pushed on version tag releases**: the `docker/metadata-action` condition was `enable={{is_default_branch}}`, so tagging a release never updated `:latest`. Updated to also trigger on `refs/tags/v*` pushes, so the nightly deploy script always pulls the newest released image.
- **ObservabilityTests queue-depth assertion updated for browser-mode backstop**: the metric now counts both worker-claimable and browser-mode pending submissions; test expectation updated from 1 to 2.

## [0.4.56] - 2026-04-11

### Added

- **Worker backstop for browser-graded submissions**: pending browser-mode submissions (e.g. from a browser runner failure or pre-fix backlog) are now claimed and graded by the native worker using `python3`, exactly as Pyodide would. Previously these submissions were permanently stuck in "pending".

### Fixed

- **Browser-graded assignments no longer accept zip uploads**: the student dashboard "Submit" button for browser-graded assignments now routes directly to the notebook page instead of the zip-upload form. Direct `GET`/`POST` to the submit route for a browser-mode setup redirects to the notebook page.
- **Runner detail page version/hostname now stay current after a restart**: the runner detail page now polls `GET /admin/runners` every 5 seconds (matching the main admin dashboard) and updates the version, hostname, and "Last active" fields in the header without a page reload.
- **Trivy container scan action version corrected**: `aquasecurity/trivy-action` was pinned to a non-existent tag (`0.30.0`); updated to `v0.35.0` (Trivy 0.69.3), which resolves the docker-build workflow failure.

## [0.4.54] - 2026-04-10

### Changed

- **Instructor CSV enrolment now uses a dedicated upload page**: the instructor roster header replaces the inline file picker with an `Enrol` button beside the enrollment-mode selector, opens a separate CSV upload screen modeled on the Marmoset import flow, and keeps the enrolled-students header controls inline with the search field.

## [0.4.53] - 2026-04-09

### Fixed

- **Release-build fallout from deadline auto-close is resolved**: standalone setup submissions are no longer blocked by the assignment deadline guard when no assignment row exists, observability test databases now include the `runner_profiles` migration, and the regression test covers that schema bootstrap directly.

## [0.4.52] - 2026-04-09

### Added

- **Automated GitHub release workflow**: the repository now includes a release workflow so tagged version bumps can publish a GitHub Release in a repeatable way.

### Fixed

- **Assignments now auto-close on their posted deadline entirely in the backend**: overdue open assignments are swept closed on startup and periodically at runtime, late student submissions are rejected across the web upload and browser submission endpoints, and instructors can still manually reopen a past-due assignment through a persisted backend override.

## [0.4.51] - 2026-04-08

### Fixed

- **Submission results now keep failing output readable without shrinking the table layout**: the student submission page removes the dedicated output column, keeps pass-only output collapsible, and shows `fail`/`error`/`timeout` diagnostics in full-width rows directly beneath the affected tests.
- **JupyterLite generated assets are back in sync with the favicon changes**: the rebuilt `Public/jupyterlite` HTML entrypoints are now committed alongside the favicon consistency update, so the `JupyterLite` GitHub Actions verification step stops failing on asset drift.

### Added

- **First-Try Perfect badge on student views**: students now see a `First-Try Perfect` achievement when their latest visible assignment result is a `100%` first submission, shown both on the submission page and beside the assignment on the home page.

## [0.4.50] - 2026-04-08

### Fixed

- **Admin runner detail no longer fails when runner profile metadata is unavailable**: the runner detail page now treats runner capability/profile tags as optional data, so the page still renders cleanly in environments where `runner_profiles` has not been migrated yet.

### Changed

- **New assignment creation now supports draft-backed notebook authoring on a single page**: `/instructor/new` can create hidden drafts, launch blank assignment or solution notebooks into JupyterLite, reopen uploaded notebooks for editing, preserve draft state across round-trips, and finalize assignments from those draft-backed notebooks.
- **Runner requirements can now be reviewed directly during assignment creation**: the new assignment page detects likely language and capability requirements from draft files, pre-fills editable requirement fields, and saves confirmed requirements with the final assignment.

## [0.4.49] - 2026-04-08

### Fixed

- **Browser-graded assignments no longer fall back into the native worker queue**: browser-mode submissions now stay on the browser-result path, `runner-submit` rejects browser-graded setups server-side, and a regression test covers the guard.

### Changed

- **Instructor queue card now reflects actual runner backlog**: `Queued Right Now` counts only worker-eligible submissions, so it matches runner activity instead of including browser-only work.
- **Instructor dashboard polish**: moved `Export Grades CSV` into the page header beside the course title, shortened the 24h stat labels, aligned stat card values vertically, and removed the extra `Enrolment` label next to the enrollment-mode dropdown.

## [0.4.48] - 2026-04-08

### Fixed

- **Instructor drilldown no longer blocks notebook opens for student history selections**: instructors/admins can now open notebook submissions from the course-scoped student submissions view without hitting a `403`, while setup and ownership guardrails remain in place for students.
- **Assignment summary API test now reflects course-scoped enrollment correctly**: the APITest fixture now enrolls its student before asserting on the assignment submissions page, matching the intended roster filtering.

### Changed

- **Instructor dashboard is more actionable at a glance**: the `/instructor` page now includes course-scoped activity cards for recent logins, recent submissions, active assignments, queued attempts, and students with no submissions.
- **Assignment summaries now include assignment-scoped progress cards**: `/instructor/:assignmentID/submissions` shows compact stats for submission coverage, 24-hour activity, pending latest attempts, and average best grade.
- **Instructor roster and student drilldown links are cleaner**: the enrolled-student table now shows `Last Login`, and the course-scoped student submissions page uses the assignment title itself as the summary link.
- **Assignment row controls are simpler**: the instructor dashboard removes the arrow reorder controls, keeps the drag thumb aligned directly beside the assignment name, and saves status changes immediately on dropdown change.

## [0.4.47] - 2026-04-08

### Fixed

- **Long-lived runners now keep polling through transient auth failures**: poll-time HTTP `401` and `403` responses are now treated as retryable in the worker daemon instead of terminal, so network runners recover automatically after temporary auth/configuration windows without requiring a manual restart.

### Changed

- **Admin dashboard now shows 24h jobs processed instead of peak utilization**: the `/admin` diagnostics cards replace the redundant `24h Peak Util` card with `24h Jobs Processed`, backed by the `/admin/metrics` payload.
- **Runner detail page is less verbose**: removed the explanatory setup/stage timing copy under `Recent Jobs` on `/admin/runners/:id` while keeping the stage breakdown data itself.

## [0.4.46] - 2026-04-08

### Added

- **Runner stage timing metrics now flow end to end**: the native runner now records per-job stage timings for workdir setup, submission download/unpack, test setup acquisition, prep, make, runtime helper setup, and test execution. These metrics are sent with wrapped worker execution reports, persisted on `job_execution_metrics`, and covered by Core, worker, result-route, and observability tests.

### Changed

- **Sessions are now persisted in the Fluent database**: switched from Vapor's in-memory session driver to the Fluent driver. Sessions survive server restarts and work correctly in multi-process deployments (e.g. Docker Compose with a shared database volume). (#293)
- **Cache-buster version is now automatic**: static asset URLs (`styles.css`, `app.js`, `notebook.js`, `browser-runner.js`) use `#appVersion()` in Leaf templates instead of a hardcoded version string. The query parameter now updates automatically whenever `ChickadeeVersion.current` changes.
- **Admin runner detail now surfaces setup-oriented timing overhead**: `/admin/runners/:id` shows derived setup/other timing alongside cache, download, prep, and make breakdowns for recent jobs so runner performance bottlenecks are easier to inspect before production use.

## [0.4.45] - 2026-04-06

### Fixed

- **Re-test wait time now measured from the re-test click, not the original submission**: added `retested_at` column to `submissions`; the retest handler stamps it with the current time when re-queuing. `queueWaitMs` and `turnaroundMs` in `submission_diagnostics` now use `retested_at` as the effective enqueue baseline for re-tested jobs, eliminating the skewed statistics caused by counting all elapsed time since the original submission. (#289)

## [0.4.44] - 2026-04-06

### Fixed

- **OIDC username claim now reaches the Docker container**: `OIDC_USERNAME_CLAIM` and `OIDC_EMAIL_CLAIM` were missing from the `environment:` block in `docker-compose.yml`, so values set in `.env` on the host were never forwarded to the server process. The container always fell back to `preferred_username`, producing sub-hash usernames for new SSO logins. (#288)
- **Test coverage for first-time SSO login**: added `testSSOCallbackCreatesNewUserWithCustomUsernameClaim` to verify that a brand-new user (no prior DB record) gets the username from the configured claim rather than the `sub` hash. The existing tests only exercised the stale-user repair path.

## [0.4.43] - 2026-04-06

### Fixed

- **OIDC login no longer overwrites `user_id` with the username claim**: the generalized OIDC claim mapping path was incorrectly deriving `userIdentifier` from `OIDC_USERNAME_CLAIM`, which could replace a real provider `user_id` with the username or `sub` fallback during login. Chickadee now prefers the explicit `user_id` claim when present, and APITests cover the regression case where username repair must not clobber the stored user ID. (#288)

## [0.4.42] - 2026-04-06

### Fixed

- **Existing OIDC users now repair stale usernames on login**: when an SSO user already existed in the database and had previously fallen back to the `sub` claim, Chickadee would keep showing that stale value in the UI even after `OIDC_USERNAME_CLAIM` was configured correctly. The SSO upsert path now refreshes `username` from the configured claim on every login, and APITests cover the custom-claim regression case. (#288)

## [0.4.41] - 2026-04-06

### Added

- **Runner-side LRU test setup cache**: the runner no longer re-downloads and re-unzips the test setup zip for every job. A new `TestSetupCache` Swift actor maintains a bounded LRU cache (16 entries, default root `/tmp/chickadee-runner-cache`) of fully-prepared test setup directories keyed by `testSetupID`. On a cache hit the prepared directory is copied into a fresh per-job scratch location; on a miss it is downloaded, unzipped, and committed atomically. Concurrent jobs for the same test setup share one in-flight population task — no duplicate downloads. Failed populations are cleaned up without leaving partial entries. The cache root is configurable via `--test-setup-cache-dir` or `RUNNER_TEST_SETUP_CACHE_DIR`. (#285)

## [0.4.40] - 2026-04-05

### Fixed

- **Release follow-up keeps OIDC tests aligned with the current auth models**: APITests now construct `OIDCDiscovery` with explicit `revocationEndpoint`/`endSessionEndpoint` values, provide `claimConfig` when building `OIDCConfiguration` fixtures, and split one mock-discovery construction path into simpler local values so Swift 6.3 can type-check it reliably. This fixes the `Swift Tests` failures that remained after `0.4.39`. 

## [0.4.39] - 2026-04-05

### Fixed

- **OIDC startup logging compiles cleanly again**: the generalized OIDC claim/configuration follow-up had split a startup log message across concatenated string literals, which no longer matched Vapor's `Logger.Message` expectations under the current toolchain. The log statement now uses a single interpolated message so server builds stop failing in CI. (#284)
- **OIDC claim decoding compiles cleanly again**: `OIDCIDTokenClaims.KnownKey` now declares `CaseIterable` directly rather than through an inaccessible `private` extension, restoring the `allCases` lookup used to separate typed claims from `extraClaims`. (#284)
- **OIDC auth tests now match the generalized claim model**: APITests no longer reference removed UWaterloo-specific fields (`winaccountname`, `userID`, `studentID`). `OIDCIDTokenClaims` has a direct initializer again for test token construction, and tests now use `preferredUsername`/`extraClaims` semantics so the release branch compiles end to end. (#284)

## [0.4.38] - 2026-04-05

### Fixed

- **Python test bootstrap now sets `sys.argv[0]` correctly**: the `pythonBootstrap` code that wraps Marmoset-format `.py` test scripts was leaving `sys.argv[0]` as `'-c'` instead of the script path. Test frameworks (including the Marmoset-era `chickadee.py` helper) that use `Path(sys.argv[0]).resolve()` to locate the script file would raise `FileNotFoundError`, causing every test to fail with 0/8 and no feedback. Fixed by shifting `sys.argv` before calling `runpy.run_path`. (#281)
- **`chickadee.py` exit code 3 now maps to `fail`**: `chickadee.py` exits with code 3 for test failures (`Result.Failed`); Chickadee was previously mapping this to `error`. Results now correctly show as `fail`. (#281)
- **Notebook cells sanitized on extraction to prevent import-time failures**: when a student's `.ipynb` is converted to `.py`, bare module-level "usage" code (print calls, variable references, bare expressions) no longer executes at import time. `NotebookExtractor` now wraps such code in `if __name__ == "__main__":` and strips IPython magic/shell lines (`%`/`!`). R notebook cells are unaffected. This was the root cause of the HLTH 230 Assignment 3 0/8 failures on Chickadee. (#282)

## [0.4.37] - 2026-04-04

### Added

- **Architecture documentation**: `docs/architecture.md` covers all three targets, the grading pipeline, auth modes, sandboxing, HMAC runner auth, database layout, JupyterLite, and deployment.
- **SSO token revocation on logout**: when an SSO user logs out, Chickadee now fires a non-blocking RFC 7009 revocation request against the IdP's `revocation_endpoint` (if advertised in the discovery document) and redirects the browser to `end_session_endpoint` with `id_token_hint` and `post_logout_redirect_uri` to terminate the IdP session. Falls back to `/login` for providers that don't publish these endpoints.
- **Configurable OIDC claim names**: `OIDC_USERNAME_CLAIM` and `OIDC_EMAIL_CLAIM` env vars select which JWT claims map to the Chickadee username and email address (defaults: `preferred_username` and `email`). UWaterloo DUO deployments should set `OIDC_USERNAME_CLAIM=winaccountname`. All non-standard claims are captured in a flexible `extraClaims` dictionary rather than hardcoded fields.
- **Core model test coverage**: 34 new tests covering `BuildStatus`, `TestOutcome`, `TestOutcomeCollection`, `Job`, runner payload types, `CompatibilityResult`, `CourseBundleManifest` round-trips, and backward compatibility.

### Changed

- **Large source files split for maintainability**: `RunnerDaemon.swift` extracted into `TestRuntimeSources.swift`, `NotebookExtractor.swift`, and `RunnerNetworkResilience.swift`; `AdminRoutes.swift` extracted into `AdminContextTypes.swift` and `AdminRoutes+Courses.swift`; `AssignmentRoutes.swift` extracted into `AssignmentRoutes+Editor.swift`.

## [0.4.36] - 2026-04-03

### Changed

- **Submission IDs on the runner detail page are now clickable links**: each row in the Recent Jobs table links directly to `/submissions/:id` so administrators can click through to inspect test results, errors, and timing for any job without leaving the runner view.
- **Assignment delete confirm dialog wording corrected**: the confirmation prompt now says "Delete this assignment?" to match the Delete button label (previously said "Remove this assignment?").
- **CSV enroll result page uses consistent monospace styling**: not-found usernames are now wrapped in `<code>` elements, matching the `ui-monospace` font stack used everywhere else rather than an inline `font-family` override.

## [0.4.35] - 2026-04-02

### Changed

- **Admin dashboard summary header now reflects peak load more clearly**: the compact admin metrics row now uses the site’s normal light/dark surface styling, cleaner labels, and a 24-hour max load fraction based on runner snapshot capacity instead of a momentary active-runner count.

## [0.4.34] - 2026-04-02

### Added

- **Instructor student submission drilldown**: instructors can now click any student in the course roster to open a course-scoped submissions view for that student, making it much easier to inspect work and support debugging.
- **Course-scoped student submissions page**: the new instructor view lists each student's submissions with assignment name, attempt, submitted time, status, grade, and quick actions to open results, download the submission, or jump directly into notebook work when available.

## [0.4.33] - 2026-04-02

### Fixed

- **Poll-loop retry backoff now honors the runner retry environment settings**: the worker daemon's main polling loop now uses the same `RUNNER_RETRY_BASE_DELAY_MS` and `RUNNER_RETRY_MAX_DELAY_MS` configuration as the rest of the runner network-retry paths. This makes retry timing consistent across polling, downloads, heartbeats, and result uploads, and keeps the worker retry tests deterministic in CI.

## [0.4.32] - 2026-04-02

### Changed

- **Docker runner replicas now get unique default worker IDs**: the bundled `docker-compose.yml` no longer hardcodes `runner-01`. Runner containers now default to `runner-${HOSTNAME}`, which avoids self-conflicts when scaling the `runner` service and makes the deployment docs match the supported multi-runner setup.
- **Admin diagnostics charts are now compact sparklines**: the dashboard visualizations were reduced to a much smaller height and updated to use the existing site theme variables so they sit naturally within the admin UI instead of overwhelming the page.

### Fixed

- **Long-running runners now reconnect cleanly through brief server restarts and updates**: the worker poll loop no longer exits on transient poll-time HTTP failures such as `500`, and duplicate worker-ID conflicts during recovery now back off and retry instead of forcing a manual runner restart.
- **Runner network retry classification is more realistic for short outages**: poll, heartbeat, and result/report retry logic now treats `408`, `425`, `429`, and `500` as retryable alongside the existing gateway/service-unavailable statuses, improving recovery during rolling restarts and temporary overload.
- **Worker regression coverage now protects the reconnect path**: new `WorkerDaemonTests` specifically verify recovery from transient poll-time `500` responses and duplicate worker-ID conflicts so this outage class is less likely to recur unnoticed.

## [0.4.31] - 2026-04-02

### Fixed

- **CI worker and coverage workflows now install `file`**: the scheduled `Worker Tests` matrix and nightly `Test Coverage` job now install the same `file` dependency used by runner-side Python submission normalization, keeping scheduled/test-coverage environments aligned with the runner image and push-time Swift test workflows.

## [0.4.30] - 2026-04-01

### Added

- **Runner-side Python submission normalization**: Python jobs now preprocess submissions in the worker before grading. The runner detects MIME types with `file`, classifies notebooks by JSON structure instead of filename extension, normalizes the submission into a temporary grading workspace, and keeps the original uploaded files untouched on the server.
- **Submission warnings surfaced in grading results**: the worker now emits warnings for extension/content mismatches, notebook extraction, ignored unsupported files, and compatibility filename copies, and those warnings are returned through the API and shown on the submission page.

### Changed

- **Notebook handling is content-aware and backward-compatible**: `.ipynb` submissions still normalize to the legacy `foo.py` filename in the grading workspace, while notebook JSON uploaded under `.py` or another name is detected and converted into a usable Python source file before tests run.

### Fixed

- **Python grading no longer depends on uploaded filenames**: valid scripts are copied as-is, notebooks with code cells are extracted in cell order, and assignments using `requiredFiles` can receive a conservative compatibility copy when exactly one Python source is available.

## [0.4.26] - 2026-04-01

### Fixed

- **Admin runner table reverts to old layout after 5-second poll**: the `renderWorkers()` JavaScript function was never updated when v0.4.25 added the Version, Load, Avg Run, and Avg Wait columns. Every poll overwrote the correctly server-side-rendered table with the old 5-column rows, placing "Last Active" in the "Avg Run" slot and leaving Version, hostname, and Avg Wait blank. The function now emits all seven columns matching the Leaf template.

## [0.4.25] - 2026-03-31

### Added

- **Admin runner dashboard: version, load, and performance diagnostics**: the runner table now shows seven columns instead of five.
  - **Runner** — worker ID and hostname (hostname shown in muted text below the ID).
  - **Version** — Chickadee version the runner is running (`0.4.25`+); shows `—` for older runners.
  - **Load** — current assigned jobs out of the runner's declared capacity (e.g. `2 / 4`); bold when busy. Shows bare count for pre-0.4.25 runners that don't advertise capacity.
  - **Jobs Processed** — lifetime count (unchanged).
  - **Avg Run** — rolling average execution time over the last 50 jobs (e.g. `14s`, `850ms`); shows `—` until data accumulates.
  - **Avg Wait** — rolling average queue-wait time (submission → runner claim) over the last 50 jobs; shows `—` until data accumulates.
  - **Last Active** — relative time (unchanged).
  - The redundant "Status" column is removed; the Load column makes it obvious at a glance.
- **Runner advertises concurrent-job capacity on every poll**: `POST /worker/request` now includes `maxConcurrentJobs` alongside the existing `runnerVersion`. The server stores both in `WorkerActivityStore` and surfaces them in the dashboard.
- **`submission_diagnostics` table is now populated**: `OperationalDiagnosticsService` call sites wired in:
  - `recordSubmissionCreated` — called when a student submits via the web form.
  - `recordJobAssigned` — called inside the claim transaction when a runner picks up a job.
  - `recordWorkerExecutionReport` — called when results are received; populates `execution_ms` (from `TestOutcomeCollection.executionTimeMs`) and `queue_wait_ms` (from `assignedAt − submittedAt`). The table was schema-complete but never written to before this release.

## [0.4.24] - 2026-03-31

### Fixed

- **Safari autofills search/filter inputs with saved credentials**: Safari ignores `autocomplete="off"` and uses its own heuristics to identify credential forms. It was treating the admin user-filter input (whose placeholder contains "username") as a username field paired with the adjacent `name="secret"` worker-secret input. Three fixes applied: (1) filter inputs now carry `readonly` on load and remove it on first focus — Safari skips autofill on readonly fields; (2) the worker-secret input uses `autocomplete="new-password"` instead of `autocomplete="off"`, which correctly signals to Safari that this field is for entering a new secret rather than recalling a saved login.

## [0.4.23] - 2026-03-31

### Changed

- **Runner reports its version on every poll**: `POST /worker/request` now includes a `runnerVersion` field in the request body, populated from `ChickadeeVersion.current`. The server decodes it as an optional field so pre-0.4.23 runners continue to work. The value is available for future server-side compatibility checks (see #256).

## [0.4.22] - 2026-03-31

### Fixed

- **`ExponentialBackoff` could return zero-duration delay on first call**: the jitter range `Double.random(in: 0...doubled)` included 0 as a lower bound, meaning the first poll after a transport error could retry immediately with no sleep. The range now uses `initial` (1 s) as the lower bound so every backoff sleep is at least 1 second.
- **`Reporter.report()` had no retry logic**: a transient network error or server restart during result reporting immediately failed the submission. Results are now retried up to 3 times with a 5-second pause between attempts before a permanent error is thrown. Closes #255.

## [0.4.21] - 2026-03-31

### Fixed

- **Web form submissions stored with wrong filename**: the web submit handler decoded the uploaded file as raw `Data`, discarding the original filename from the multipart `Content-Disposition` header. When `uploadFilename` was nil and the JSON heuristic fell through, files were stored as `submission.txt`, preventing `extractNotebooksToCode` from converting the notebook to a `.py` file and causing test scripts to report "bmi.py not found". The handler now decodes the upload as `Vapor.File`, which captures the browser-supplied filename automatically, so `.ipynb` submissions are stored under their correct name and extracted correctly.

## [0.4.20] - 2026-03-30

### Changed

- **`ScriptRunner` timeout uses `Task` instead of `DispatchQueue.asyncAfter`**: the macOS subprocess timeout now fires via `Task.sleep` in a structured child task rather than a `DispatchWorkItem` on a global dispatch queue, keeping the timeout logic within Swift's cooperative concurrency model. `timedOut` is promoted to `Mutex<Bool>` for safe cross-task access. Closes #242.
- **`ZipArchiver` drops `DispatchQueue` bridge**: `runZipProcess` previously wrapped process setup in `DispatchQueue.global().async` before setting `terminationHandler`. Process setup is non-blocking, so the dispatch queue is unnecessary — the continuation is now set up directly on the caller, and Foundation's internal monitoring queue resumes it on termination. Closes #243.
- **Domain-specific error types introduced** (`NotebookLookupError`, `WorkerJobError`): `notebookData(for:)` now declares `throws(NotebookLookupError)` so callers have a static enumeration of failure modes; `WorkerJobRoutes` adopts `WorkerJobError` for test-setup lookup failures. Both types conform to `AbortError` so Vapor's error middleware maps them to the correct HTTP status without a shim. New code should use these types; existing handlers migrate incrementally. Closes #244.

## [0.4.19] - 2026-03-29

### Changed

- **`WorkerClaimQueue` converted to Swift actor**: replaced `NSLock` + `@unchecked Sendable` with a native `actor`, giving compile-time concurrency isolation guarantees and eliminating manual lock discipline. Closes #240.
- **Admin dashboard queries parallelised**: course list, enrollment counts, and assignment counts are now fetched concurrently with `async let` instead of sequentially, reducing dashboard load time proportionally to DB latency. Closes #241.

## [0.4.18] - 2026-03-29

### Fixed

- **Marmoset import: missing starter notebook causes student 404**: when a Marmoset export has no `{n}-project-starter-files.zip` (e.g. the instructor distributed the starter notebook via the course website), the importer now creates a minimal blank notebook so every imported assignment is immediately openable. The instructor can upload the real starter via the assignment editor at any time.
- **`starterNotebook` overwritten on assignment edit**: saving the assignment editor called `makeWorkerManifestJSON` without forwarding the existing `starterNotebook` field, silently resetting any custom notebook filename back to `assignment.ipynb`. The field is now read from the stored manifest and forwarded on save.
- **Edit button shown for assignments with no notebook**: the student dashboard displayed an "Edit" button for open assignments regardless of whether a notebook existed, leading to a 404 on click. The button is now hidden when no notebook is available for that assignment.
- **Silent hidden-test injection failure in browser grading**: `BrowserResultRoutes` used `try?` when loading the instructor notebook for hidden-test injection, so a missing or unreadable notebook file silently fell back to the student's notebook (omitting release/secret test cells). The error is now logged as a warning so the problem is visible in server logs.
- **Auto-enrollment save error swallowed silently**: the SSO/login post-auth flow used `try?` when persisting auto-enrollment records, hiding database errors that would leave the user unenrolled. The save now propagates errors normally.
- **Notebook route query decoding used `try?`**: both notebook page handlers decoded query parameters with `try?`, masking decode errors. They now use `try` so malformed query strings return a proper 400 rather than silently degrading.

## [0.4.17] - 2026-03-29

### Fixed

- **Concurrent worker job claiming**: `WorkerClaimQueue` was lazily initialized on first use, allowing two concurrent worker requests to each create their own queue instance and race past the serializer. Both workers would claim the same pending job, returning `.ok` to each. The queue is now eagerly initialized at server startup alongside the other application-level stores, guaranteeing a single shared instance before any requests are served.
- **Truncated/blank student notebook on first open**: when a student opened an assignment for the first time and no previous submission existed, `latestNotebookSubmissionData` silently fell back to an empty notebook (`cells: []`) if the instructor's template file could not be read. This happened whenever the flat `.ipynb` file was missing from disk (e.g. after a redeployment without a persistent volume). The fallback is removed from the student path — a 404 is returned instead, making the problem visible rather than serving a blank notebook that appears truncated.

## [0.4.16] - 2026-03-28

### Fixed

- **Notebook/browser result labels and output formatting**: in-browser notebook grading now keeps each script's saved human-readable display name separate from its result summary, so the `Test` column shows the configured label, the `Output` column shows the actual error summary, and `Show output` displays the extracted traceback instead of the raw structured JSON blob.
- **Notebook result cache busting**: the notebook page now references refreshed static asset versions so deployed browsers pick up the latest `notebook.js` and `browser-runner.js` formatting fixes immediately after upgrade.

## [0.4.15] - 2026-03-28

### Fixed

- **Assignment edit display names on reload**: the instructor edit page now encodes its computed suite-row fields into the Leaf context, so saved human-readable test names and dependency metadata actually reappear after reopening the assignment instead of falling back to blank or stale values.
- **Multipart assignment saves in real browser submits**: assignment create/edit routes now read multipart text fields like `suiteConfig` directly from the multipart body instead of relying solely on Vapor’s multipart text decoding, making the browser `FormData` save path match the tested server-side behavior.
- **Submission results JSON cleanup**: submission pages now normalize structured JSON payloads found in either `shortResult` or `longResult`, so students see readable summaries in the `Output` column and traceback-only details in the expanded view instead of raw JSON blobs.
- **Notebook asset cache busting**: notebook/editor pages now reference refreshed static asset versions so browsers stop reusing stale `app.js`, `notebook.js`, and `browser-runner.js` after deploys.

## [0.4.14] - 2026-03-28

### Changed

- **Swift 6.3 toolchain upgrade**: `Package.swift` tools version bumped to 6.3, CI images updated from `swift:6.0-jammy` to `swift:6.3-jammy`, and Dockerfile build stage updated to match. Runner stderr logging switched from `fputs`/`stderr` to `FileHandle.standardError` to resolve a Swift 6.3 ambiguity; `WorkerCommand.configuration` changed from `static var` to `static let` for strict concurrency compliance. `swift-subprocess` adoption deferred — the Linux fork/exec path requires no changes for the toolchain upgrade.

### Fixed

- **Assignment editor multipart submit sync**: global multipart form interception now gives assignment create/edit pages a final chance to refresh `suiteConfig` before `FormData` is captured, so saved human-readable test names persist reliably.
- **Submission page traceback rendering**: expanded browser-lab failure output now prefers the best traceback-bearing payload from either `stdout` or `stderr` and extracts only the traceback text instead of showing wrapped JSON blobs.

## [0.4.13] - 2026-03-28

### Fixed

- **Assignment editor display-name saves**: editing the student-facing test name on an existing suite row now always refreshes `suiteConfig` at form submit time, so renamed tests persist reliably after save.
- **Submission page traceback extraction for browser lab errors**: expanded failure output now extracts the traceback from `stdout:`-wrapped structured JSON browser payloads instead of showing the raw JSON object.

## [0.4.12] - 2026-03-28

### Fixed

- **Submission page test names for browser-graded labs**: saved human-readable test names are now shown in the `Test` column even when browser results report the full script filename (for example `test_q1_bmi.py`) instead of a filename stem.
- **Submission page detailed failure output**: expanding `Show output` now prefers a cleaned traceback/error view instead of dumping raw JSON-wrapped runner payloads, making browser and worker grading failures much easier for students to read and debug.

## [0.4.11] - 2026-03-28

### Fixed

- **Assignment suite uploads on create/edit**: repeated multipart `suiteFiles` uploads are now collected explicitly instead of relying on single-file decoding. This fixes assignment create and edit flows that were silently keeping only one uploaded test/support file after save-and-validate.

## [0.4.10] - 2026-03-28

### Fixed

- **Assignment file save/edit round-trips**: browser-mode practice-lab style setups now preserve all test/support files across save-and-edit cycles instead of drifting when `support` rows or legacy `isTest` flags are involved. The suite config backend now treats `tier = support` as the source of truth for non-test files, and compatibility paths still preserve older unchecked rows correctly.
- **Assignment creation file table**: the legacy `Test?` column has been removed from the new-assignment screen. `support` now indicates a non-test file, and any other tier is treated as a test file consistently across the UI and backend.

## [0.4.9] - 2026-03-28

### Fixed

- **Worker result uploads over real HTTP**: workers now sign and send an explicit `X-Worker-Body-SHA256` header, and the server validates that signed hash instead of re-reading streamed request bodies in HMAC middleware. This fixes the `NSURLErrorDomain Code=-1001` timeout regression introduced by the 0.4.8 worker-auth fix and restores large result uploads during assignment validation and Marmoset import.

## [0.4.8] - 2026-03-28

### Fixed

- **Worker results auth for streamed bodies**: worker `POST /api/v1/worker/results` requests are now authenticated against the collected request body buffer rather than `request.body.data`, which could be empty for larger real-HTTP uploads. This fixes size-sensitive validation failures where some Marmoset imports passed while others failed with `Invalid worker signature.`

## [0.4.7] - 2026-03-27

### Fixed

- **Notebook edit fallback**: students who open an assignment in notebook view before uploading any work now get a fresh working copy instead of a `404`.
- **Assignment creation without uploaded tests**: instructors can now create assignments with a notebook and solution before adding test cases in the UI.
- **Nested-path notebook and Marmoset imports**: zip extraction now tolerates nested notebook paths more reliably, including Linux-generated archives from Marmoset.
- **Assignment notebook scan CSRF**: scanning a solution notebook for functions on the new/edit assignment pages now submits the required CSRF token instead of failing or hanging in the UI.
- **Linux worker timeout handling**: worker subprocess timeout cleanup was hardened and the worker test suite was restored to required CI coverage with clearer sharding.
- **Browser/WASM runner execution coverage**: the browser runner now has execution-focused CI coverage for manifest loading, dependency skips, timeouts, unsupported scripts, result submission, and notebook extraction.

## [0.4.5] - 2026-03-23

### Added

- **Test coverage expansion**: 107 new tests across 6 test files, bringing the total from 227 to 334.
  - `WebRoutesTests` (18 tests): integration tests for index page, submit form, submission history, results page, and tier visibility.
  - `MarmosetImportParserTests` (28 tests): unit tests for Java properties parsing, test class list parsing, binary title extraction, and manifest conversion.
  - `SubmissionRoutesTests` (14 tests): integration tests for submission create endpoints and download access control.
  - `ManifestValidationTests` (11 tests): cycle detection, unknown dependency refs, self-references, and valid graph shapes.
  - `UWImportantDatesTests` (28 tests): iCal date/summary extraction, escape sequences, relevance filtering, and date arithmetic.
  - `EnrollCSVHelperTests` (16 tests): header detection, quote stripping, encoding fallback, and edge cases.
  - `HTTPSRedirectMiddlewareTests` (10 tests): GET redirect, POST 426, proxy header trust, publicBaseURL override, and host fallback.

### Changed

- **WebRoutes split**: `WebRoutes.swift` (1,200 lines) split into `WebContextTypes.swift`, `WebRoutes+Notebook.swift`, and `WebRoutes+Submission.swift` for maintainability.
- **UW iCal parser refactor**: extracted private actor methods in `UWImportantDatesService` into internal free functions for testability (no behavior change).

## [0.4.2] - 2026-03-21

### Security

- **Browser runner enrollment gate**: `GET /api/v1/browser-runner/testsetups/:id/download` and `.../manifest` now verify the caller is enrolled in the course that owns the test setup (or is an instructor/admin). Previously any authenticated user could download test setups from courses they were not enrolled in.
- **Submission error messages**: removed user-supplied `testSetupID` from `400` error responses to avoid echoing untrusted input.

## [0.4.1] - 2026-03-19

### Security

- **Zip-slip guard**: `extractZipArchive` now validates every entry in an uploaded ZIP against the destination directory before invoking `unzip`. Absolute paths and `..`-traversal entries throw `ZipArchiverError.pathTraversalDetected` rather than relying on OS-level `unzip` behaviour.
- **Security headers**: `SecurityHeadersMiddleware` added to the global middleware stack. Every response now includes `X-Content-Type-Options: nosniff`, `X-Frame-Options: SAMEORIGIN`, and `Referrer-Policy: strict-origin-when-cross-origin`.
- **CSRF integration tests**: full CSRF-aware test infrastructure (`TestHelpers.swift`, `CSRFTests.swift`) added; all existing integration tests updated to supply valid session-bound tokens on POST/PUT requests.

## [0.4.0] - 2026-03-15

### Added

- **Test dependency trees**: test suites can declare `dependsOn` — a list of prerequisite script names. If a prerequisite does not pass, all dependent tests are automatically recorded as `fail` with a "Skipped: prerequisite '…' did not pass" message. Applies to both the server-side shell runner and the browser-side Pyodide runner. The manifest is validated for reference integrity and cycles at upload time; entries are topologically sorted before serialization so the runner's linear pass always sees parents before children.
- **Tree UI for assignment files**: the file/test configuration panel on the assignment create and edit pages is now a drag-and-drop dependency tree. Drop a test onto the middle of another root test to make it a child (dependent); drop onto the bottom strip to remove the dependency. Maximum one level of nesting enforced in the UI.
- **Docker Compose deployment**: multi-stage `Dockerfile` compiles both binaries with `--static-swift-stdlib` (no Swift toolchain required on the host); `docker-compose.yml` orchestrates `server`, `runner`, and an optional `nginx` service with named volumes for persistence. `deploy/docker-entrypoint.sh` syncs static assets into the data volume on each startup so template and JupyterLite updates are always picked up on redeploy.
- `deploy/nginx-docker.conf` — Docker-specific nginx config with COOP/COEP headers and a commented-out HTTPS server block ready for certbot.

### Changed

- `TestSuiteEntry` gains `dependsOn: [String]` (default `[]`); existing manifests decode without change (backward-compatible).
- `.env.example` revised: `RUNNER_SHARED_SECRET` documented as required; OIDC vars updated with clearer placeholders.
- `deploy/README.md` restructured: Docker Compose quick-start added at the top; VM/systemd instructions preserved below.
- `README.md` revised: deployment section added, test dependency trees documented, auth description corrected to reflect full SSO implementation.
- `CLAUDE.md` updated: SSO marked complete; Docker deployment marked complete; next-work list updated.

## [0.3.0] - 2026-03-10

### Added

- **Course bundle export/import** (closes #68): instructors can export a course as a `.chickadee` zip bundle containing all assignments and test setups, and re-import it on another instance.
- Admin course detail page with bulk CSV enroll, unenroll, and per-student assignment view.
- Admin users table with course filter.
- Archive/unarchive course action with confirmation dialog.
- Assignment count per course displayed in the admin courses table.

### Changed

- Admin courses section reworked: course list and create/edit pages consolidated into a single `admin-course.leaf` template with an `isNew` flag.
- Edit course falls back to existing values when submitted with blank fields.
- Removed dead `GET /assignments/new/details` route (was an immediate redirect; template deleted).
- Removed abandoned `BuildStrategy` / `PythonBuildStrategy` scaffolding (superseded by shell-script runner architecture).

## [0.2.0] - 2026-03-10

### Changed

- **Breaking (fresh DB required):** Consolidated all patch migrations into their original `Create*` files. Migration count reduced from 11 to 8; no patch migrations remain.
  - `AddUserProfileFields` and `AddUserSSOFields` folded into `CreateUsers`.
  - `AddCourseToAssignments` eliminated; `course_id` column now in `CreateTestSetups` and `CreateAssignments` from the start.
  - `AddCourses` renamed to `CreateCourses`; `AddCourseEnrollments` renamed to `CreateCourseEnrollments`.
- **Schema hardening** (closes #84):
  - `course_id` is now `NOT NULL` with a FK to `courses(id)` on `test_setups` and `assignments`.
  - `course_enrollments.user_id` now has `ON DELETE CASCADE` FK to `users(id)`.
  - `courses(code)` now has a `UNIQUE` constraint.
  - Added four missing indexes: `idx_assignments_course_id`, `idx_test_setups_course_id`, `idx_course_enrollments_course_id`, `idx_course_enrollments_user_id`.
- `APITestSetup.courseID` and `APIAssignment.courseID` are no longer optional; both models require a course.
- `saveNewAssignment` now resolves the instructor's active course and assigns it to newly created test setups and assignments.
- `POST /api/v1/testsetups` now requires a `courseID` field in the multipart form.
- Migration order resequenced to respect FK dependencies (`CreateCourses` before `CreateTestSetups`).

## [0.1.0] - 2026-02-24

### Added

- Baseline database schema now includes canonical fields and foreign key constraints.
- SQLite foreign key enforcement and WAL journaling at startup.
- Performance indexes for high-frequency submission/result/user queries.
- Version scaffold:
  - `VERSION` file.
  - Shared `Core` version constant (`ChickadeeVersion.current`).
  - Runner `--version` support.

### Changed

- Migration chain simplified to canonical create migrations plus index migration.
- API and worker startup now consistently report/consume project version metadata.

### Removed

- Legacy additive migrations that were made obsolete by the canonical baseline schema.
