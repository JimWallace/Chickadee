# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project follows Semantic Versioning.

Releases before 0.5.0 (the 0.1.0 – 0.4.669 history, ~660 releases across the
first course offering) are archived in [CHANGELOG-0.4.md](CHANGELOG-0.4.md).

## [Unreleased]

## [0.5.8] - 2026-08-04

### Security

- **The workbench validates a notebook destination before pointing a frame at
  it.** The tab destinations reach the page as DOM text and the sink is an
  iframe `src`, where a `javascript:` URL would be script execution in
  Chickadee's own origin. The server builds that map from its own test-setup
  identifiers, so nothing hostile could reach it — but the page did not enforce
  that, and the gap between "is not attacker-controlled" and "cannot be" is the
  whole bug class. Destinations are now accepted only if they match the
  same-origin notebook-page path shape, checked both where a click is resolved
  and again at the assignment itself. Flagged by CodeQL.

### Added

- **The workbench can switch between a notebook's template and its rendering.**
  On an assignment whose notebook carries `{{placeholders}}`, the notebook pane
  gains a Template / With values control beside the Assignment / Solution tabs,
  so an author can compare what they wrote against what a student sees without
  leaving the page. The control is rendered per file and only where the two
  readings actually differ — on a notebook without placeholders they are
  byte-identical, and switching would be a kernel reboot for no change.

  Pane URLs now always carry an explicit `view=`. The server defaults staff to
  the template on a personalized notebook, so omitting it made the "Assignment"
  tab mean the template on one assignment and the rendering on another.

### Changed

- **The workbench holds one notebook document, not one per destination.** The
  tabs and the view switch repoint a single iframe. Previously each notebook got
  its own live iframe so switching was instant; with the view axis that would
  have been up to four simultaneous Pyodide kernels and an eviction policy to
  bound them — a lot of machinery for a secondary interaction. The workbench
  exists to put the edit page and *a* notebook on screen together, which holds
  with one. The accepted cost: switching notebooks re-boots the kernel.

  The browser check now asserts the iframe count directly, so reintroducing a
  frame per destination fails rather than passing quietly.

### Fixed

- **Collapsing the workbench editor now actually gives the notebook the window.**
  Hiding the edit pane removed it from the grid without re-declaring the
  columns, so the notebook landed in the content-sized column and shrank to
  roughly 300px — narrow enough that the embedded notebook page rendered its
  "Open on a larger screen" notice. Collapsing the editor to see more of the
  notebook showed none of it. Found by screenshotting the real page; the
  collapse unit tests were correct and could not see it, so the browser check
  now asserts the rendered width.

- **The workbench no longer shows two template/values controls.** The embedded
  notebook page rendered its own view-toggle link beside the workbench's, and
  that link carries no `embedded=1` — following it would have loaded the fully
  chromed page inside the pane. The page's own toggle is suppressed when it is
  a workbench pane; the workbench's control is the one that works there.


## [0.5.7] - 2026-08-04

### Added

- **The workbench smoke check now covers the two interactive behaviours that had
  no browser coverage.** It asserts that a keystroke inside a pane reaches the
  shell as `chickadee:activity` — the chain that stops the idle watchdog from
  signing an author out while they are actively typing, a bug that otherwise
  only shows up half an hour into a session — and that selecting the Solution
  tab mounts it while leaving the assignment notebook mounted, so switching back
  is a pane toggle rather than a second cold kernel boot. The seeded assignment
  now gets a reference solution so the Solution tab actually renders; without it
  those assertions were unreachable.

  Both were verified by falsification: disabling the activity forwarder and
  forcing unmount-on-switch each fail the check with the matching diagnostic.

### Changed

- **`docs/ci-flakiness.md` records the first chromium sighting of the grading
  hang.** Family 2 is documented as webkit-only, and the note that "chromium
  passes 12/12" is what makes a chromium hang look like a genuine regression.
  One was observed (and did not reproduce on rerun), so the doc now says it is
  rarer on chromium rather than absent. The gate policy is deliberately
  unchanged — chromium stays at hard zero so a recurrence is loud.


## [0.5.6] - 2026-08-04

### Added

- **The workbench's cross-origin-isolation chain is now checked in a real
  browser.** `Tools/editor-smoke-test/workbench-check.mjs` seeds an assignment
  through the real HTTP API, opens the workbench as its instructor, and asserts
  the shell, the left pane, and the *nested* notebook iframe are each isolated
  (inverted for WebKit, which runs the comlink path deliberately), that the
  nested frame really has `SharedArrayBuffer`, and that the solution pane stays
  unmounted until asked for. Runs in the editor-smoke matrix on both engines.

  Unit tests can only pin the response headers. Whether the isolation those
  headers are meant to produce actually survives two levels of framing is a
  browser question, and getting it wrong is silent — the kernel still boots,
  just on the slower service-worker transport, with no error reported anywhere.
  The check was verified by removing each half of the isolation rule in turn and
  confirming it fails with the matching diagnostic.

  The editor-smoke path filter now also covers the workbench route, template and
  scripts, so a change to any of them runs the smoke rather than skipping it.

### Fixed

- **Editing inputs in the workbench now warns that the notebook is stale.** The
  assignment workbench's shell already knew how to raise a "reload the notebook"
  chip when global inputs or section variables changed, but nothing sent the
  message — so saving an input silently left the notebook pane rendering a
  substitution of the old values, which is the confusion the chip exists to
  prevent. The two inputs editors now announce their saves. The notice is
  deliberately advisory rather than an automatic reload: reloading that pane
  restarts the Python kernel and discards the author's live state, so the author
  chooses when to pay for it.

### Added

- **Collapse the workbench's editor pane.** A "Hide editor" toggle in the
  workbench toolbar (and `Enter`/`Space` on the splitter) gives the notebook the
  full window and restores the pane to its previous width. Previously the only
  way to widen the notebook was to drag the splitter to its stop, which matters
  most on a 1280–1440px laptop where the split leaves the notebook near its
  minimum.

### Changed

- **`ChickadeeUI.notifyWorkbench`** replaces the private copy in `notebook.js`
  as the one place a page tells the workbench shell that something the other
  pane depends on has changed. Three pages send these notes and each is also
  reachable as a standalone page, so the guards — silent when there is no shell
  above, and an explicit target origin rather than a wildcard — are now written
  and tested once instead of per caller.


## [0.5.5] - 2026-08-04

### Added

- **Assignment workbench — the edit page and the notebook editor, side by side.**
  A new instructor surface at `/instructor/:assignmentID/workbench` puts the
  assignment editor in a left pane and the embedded JupyterLite editor in a
  right pane, with a tab strip that switches the notebook pane between the
  starter notebook and the reference solution. Authors can read and change
  global inputs, section variables, suite entries and deadlines while a Pyodide
  kernel boots or a validation run finishes, instead of paying a full editor
  cold boot on every hop between the two pages. Reached from a "Workbench"
  button on the edit page; the standalone `/edit` and
  `/testsetups/:id/notebook` pages are unchanged and remain the default.

  The shell renders no assignment content of its own — it composes the two
  existing pages as same-origin iframes, so the suite editor, inputs editors and
  `notebook.js` all run unmodified. The solution pane stays unmounted until its
  tab is first selected, then stays warm, so switching costs one kernel boot
  rather than one per switch; a device reporting low memory keeps a single
  kernel and reboots on switch instead. The splitter is drag- and
  keyboard-operable and clamps so the notebook pane can never fall under the
  width at which it would replace the editor with its "open on a larger screen"
  notice; below a viewport that can hold both panes honestly, the layout falls
  back to one pane at a time.

### Fixed

- **Cross-origin isolation now covers the whole editor frame chain.** Isolation
  is a property of every ancestor, so nesting the notebook page inside another
  page requires the outer documents to carry `COOP`/`COEP` as well. Without it
  the editor iframe would lose `SharedArrayBuffer` and silently fall back to the
  service-worker kernel transport on Chrome and Firefox — and, under
  `require-corp`, the sibling pane would have been refused outright. The
  workbench routes are isolated on the same terms as the notebook page,
  including the WebKit exemption that keeps Safari on its comlink path. Plain
  `/instructor/*` pages are unaffected.


## [0.5.4] - 2026-08-03

### Added

- **Course staff author notebooks against the template, not a rendering.** A
  notebook with personalization is two documents: the template the author
  writes (`patients = {{patients}}`) and the per-viewer rendering the server
  produces from it. Staff only ever saw the second one — their own values,
  substituted in — so the placeholders were not visible, not editable, and
  edits to a substituted cell were silently reverted on save (correctly: the
  alternative was baking one person's values into the class template). Staff
  opening the starter or the solution now get the template by default, with
  `{{name}}` standing as written; typing a placeholder into a cell stores it
  verbatim. The two views are separate working copies, so a "View with values"
  switch in the editor toolbar moves between them without either clobbering the
  other's edits, and Submit stays on the rendered view — a template does not
  run. Nothing changes for students, who always get their rendering, or for an
  assignment with no personalization, where the two views are identical bytes.

### Fixed

- **The reference solution was reachable by any enrolled student through
  `/testsetups/:id/notebook/source?file=solution`.** The notebook *page* has
  always gated the solution to course staff — with a comment warning against
  relying on the absence of a UI link — but the raw content endpoint behind it
  never applied the same check, so a student who guessed the query parameter was
  served the answer key as JSON. It now enforces the same staff gate.


## [0.5.3] - 2026-08-03

### Added

- **`variable_equality` pattern families support a per-student `expectedVarRef`.**
  "This student's `sd_systolic` equals this student's value" is the simplest
  personalization there is, but it was rejected outright — so an author who wanted a
  per-student answer for a variable exercise had to reshape it into a function first,
  purely to satisfy the grader. The R renderer already had the plumbing; the Python
  one never emitted the personalization preamble and baked the expected in as a
  literal. Both now bind the value from `_ck_inputs`, and the validator's single
  per-student gate is split in two: `kindSupportsPerStudentArgRefs` (unchanged — a
  bound `$name` must reach a called function) and `kindSupportsPerStudentExpected`
  (now including `variable_equality`). Arg refs stay rejected for
  `variable_equality`, whose `args[0]` is the variable *name* and is baked in as a
  literal — a ref there would be silently ignored rather than personalizing anything.
  Families with no per-student refs render byte-identically, so existing `spec_hash`
  / `TestSetupCache` keys do not churn.


## [0.5.2] - 2026-08-03

### Added

- **"Save to assignment" in the notebook editor.** Course staff (TA+) can now
  write the notebook they are editing in the embedded JupyterLite editor back to
  the assignment, from the browser — the starter notebook and the reference
  solution both. Previously JupyterLite kept the live document in the browser
  and the only ways to change an assignment's notebooks were an upload on the
  new-assignment page or the MCP `update_notebook` / `update_solution` tools;
  the editor's Edit button was effectively a scratchpad. The new endpoint
  (`POST /testsetups/:id/notebook/save`) reuses those tools' server-side steps,
  is versioned like every other authoring write, and re-runs validation — but,
  matching the other live-edit endpoints rather than the MCP tools, it never
  changes the assignment's visibility, so fixing a starter notebook mid-lab does
  not close the assignment out from under students.

### Fixed

- **Course staff can edit an assignment's notebooks while it is closed.** The
  notebook editor locked itself read-only ("This assignment is closed — view
  only") for everyone on a closed assignment, including the staff authoring it —
  and an assignment is closed for exactly the window in which it is being
  written, since creating, cloning, or saving one returns it to closed. Staff
  (TA+ or admin in the assignment's course) now keep an editable starter and
  solution notebook regardless of the closed state; students are unaffected, and
  submission stays gated by the closed state for everyone.


## [0.5.1] - 2026-08-02

### Added

- **`delete_support_file` MCP tool.** Removes one non-graded support/data file from
  an assignment's test setup. `author_script(tier: "support")` could create and
  replace support files but never remove one, so retiring a helper module or a stale
  fixture meant overwriting it with a stub — leaving a dead entry in the setup zip
  that students could still download. The tool refuses graded rows (pointing at
  `delete_suite_item` or the owning family/check) and the reserved setup members
  (`test.properties.json`, `assignment.ipynb`, `solution.ipynb`), clears any
  `graderOnlyFiles` / `datasets` mark naming the file, re-syncs the shared support
  directory so student symlinks disappear, and re-runs validation — so a remaining
  test that still sources the file fails loudly instead of at submission time.
  Content catalog is now 52 tools.

### Fixed

- **R pattern-family and notebook-check cases can express `NA`.** An authored JSON
  `null` now renders as R's `NA` rather than `NULL`, and a null interleaved among
  scalars no longer demotes the whole array to `list(...)` — `[60, null, 20]` renders
  as `c(60, NA, 20)`, `["G2", null, "G4"]` as `c("G2", NA, "G4")`. Previously `NULL`
  silently vanished inside `c()`, so an NA-bearing case handed the student's function
  a list and failed with `'list' object cannot be coerced to type 'double'` before the
  function was meaningfully exercised. This made the "NA in, NA out" half of a
  function's contract unauthorable as a pattern family, forcing hand-written scripts.
  Mixed-kind arrays still render as `list(...)`; a null does not rescue them.


## [0.5.0] - 2026-08-01

### Changed

- **Chickadee 0.5.0.** Marks the conclusion of the first full course offering
  run on Chickadee and the close of the 0.4 series. The system this milestone
  snapshots: Python and R assignments; browser (Pyodide/wasm) and native
  worker grading sharing one RunnerCore implementation; per-student
  personalization, pattern families, and notebook checks; achievements and
  slip days; per-course roles; BrightSpace grade sync; the MCP authoring and
  admin-diagnostics surfaces; OIDC SSO; and zero-downtime auto-deploys. The
  0.1.0 – 0.4.669 release history is archived in CHANGELOG-0.4.md;
  development now shifts to next year's feature work.


## [0.4.670] - 2026-08-01

### Changed

- **0.5-boundary cleanup pass.** Closes out the 0.4 series ahead of the 0.5.0
  milestone: the CI test image now installs `r-base` and pandas/matplotlib so
  the R execution-path and dataframe/plot suites actually run in CI (their
  availability guards were permanently false before); the browser graders'
  shared Python snippets, exit-code derivation, MEMFS writer, and package
  preloader moved into one `Public/grading-shared.js` consumed by both the
  grading worker and the main-thread fallback (the fenced-region drift test is
  retired, and the grading worker is now spawned with the page's cache-buster
  so all grading files pin to one release); six APITests suites that spawn
  subprocesses or bind ports gained `.timeLimit` traits; the `alert()` ratchet
  now also covers first-party `Public/*.js`; and the second migration
  consolidation folded the post-#502 incremental migrations into their
  canonical `Create*` files, removing the boot-order hazard class behind
  #1077.

### Removed

- **Pre-0.5 compatibility shims.** The `WORKER_SHARED_SECRET` env alias (a
  deprecation warning had been shipping; use `RUNNER_SHARED_SECRET`), the
  `GET /admin/workers` and `POST /admin/worker-secret` route aliases, the two
  "one-time" legacy boot sweeps that ran on every boot, the decode-and-ignore
  `suiteFiles`/`suiteConfig` fields on `/edit/save`, the verified-dead overlay
  pattern-family editor path, the `NotebookFunctionScanner` memberwise-init
  realignment shim, and the legacy `isOpen` key on course-bundle exports (the
  read-side fallback stays, so old bundles import unchanged).

### Fixed

- **Documentation debt.** `CHANGELOG.md` history through 0.4.669 archived to
  `CHANGELOG-0.4.md`; CLAUDE.md's per-version log compressed into a 0.4
  retrospective; `docs/architecture.md` and `README.md` refreshed to describe
  the five-target + wasm reality, both MCP surfaces, and per-course roles;
  finished-era investigations moved to `docs/archive/`; stale "not yet built"
  headers corrected; and the manual minor-bump procedure is now documented in
  `docs/release-process.md`.

