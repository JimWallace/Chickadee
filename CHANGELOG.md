# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project follows Semantic Versioning.

Releases before 0.5.0 (the 0.1.0 – 0.4.669 history, ~660 releases across the
first course offering) are archived in [CHANGELOG-0.4.md](CHANGELOG-0.4.md).

## [Unreleased]

## [0.5.15] - 2026-08-05

### Added

- **The editor smoke matrix now probes `input()` against the kernel students
  actually get.** The selftest runs `?kernel=python` — the Pyodide kernel, which
  since v0.5.14 is no longer the editor default (`defaultKernelName` is
  `xpython`). Without this, every stdin and freeze-detector result we had
  described a kernel nobody boots. The new step is blocking on both engines, and
  both must run: they use different synchronous-stdin transports, so a change
  that breaks only one would otherwise ship green. Chromium is cross-origin
  isolated and carries stdin over `SharedArrayBuffer`; WebKit is served
  non-isolated and carries it over the service worker, which
  `JupyterLiteConfigFlagMiddleware` re-enables per request for that engine.
  Measured: `input()` round-trips on both.

### Changed

- **Corrected three stale editor-kernel claims.** `docs/xeus-r-kernel-spike.md`
  asserted that xeus "hard-requires SharedArrayBuffer with no fallback" —
  untrue, and load-bearing: it is why we believed moving Python to xeus would
  break Safari, and why #1270 briefly shipped a changelog entry describing a
  Safari regression that does not exist. The same document still routes builds
  through `emscripten-forge-dev`, frozen since 2026-04-09.
  `docs/notebook-editor-kernel-boot.md` separately described cross-origin
  isolation as "unconditional" when `COEPMiddleware` exempts WebKit, and
  described the service worker as disabled when that is true of Chromium only.
  All three now record what was measured, when, and against which kernel.


## [0.5.14] - 2026-08-05

### Changed

- **The editor's Python kernel is now xeus-python.**
  `Tools/jupyterlite/environment-python.yml` and `environment-r.yml` build
  `xpython` (xeus-python 0.19.0, Python 3.13.1) and `xr` (xeus-r 0.11.2,
  R 4.5.3), so authoring runs one kernel technology for both languages.
  Notebooks normalize to `xpython` / `xr`; new starter scaffolds are written
  with the `xpython` kernelspec. Verified in headless Chromium against the
  vendored bytes: both kernels boot and execute cross-origin isolated,
  pandas/numpy/matplotlib import, and the boot makes zero external network
  requests.
- **Each kernel gets its own emscripten-forge env.** A xeus kernel fetches its
  whole env at boot, so building Python and R into one shared env made every
  Python boot pull all of `r-base` and every R boot pull numpy/pandas/
  matplotlib — slow enough to time out the editor probes with "kernel never
  reported idle". `check-xeus-vendored.sh` now asserts the two envs stay
  distinct, and that neither has acquired the other's packages, so a re-vendor
  cannot silently recombine them.
- **Kernel builds moved to the `emscripten-forge-4x` channel.** The
  `emscripten-forge-dev` alias the R kernel was pinned to serves the frozen 3x
  (emscripten 3.x ABI) channel — its last build of any package was 2026-04-09 —
  so the vendored R kernel was tracking a channel that no longer receives fixes.
  This also unblocked Phase 3 of the xeus spike: xeus-python has been built
  against xeus 6 with a real `run_exports` pin since 0.18.1 (2026-03-09), which
  is the supported pairing the spike said to wait for.
- **`scripts/check-xeus-vendored.sh` now guards both kernels.** It asserts
  `xpython` and `xr` are registered, share one env, declare the right language,
  and each have both a loader and its `.wasm` beside it — so a partial
  re-vendor fails in CI rather than in front of a student.

### Fixed

- **The editor kernel no longer hangs on cross-origin-isolated engines.**
  `pyodide-http` (an unavoidable dependency of `xeus-python-shell-lite`) selects
  a Pyodide-specific streaming implementation whenever `crossOriginIsolated` is
  true. It is not pyjs-compatible, so on Chromium the kernel never left
  `kernel_starting` and the editor sat on "Kernel Connecting" indefinitely;
  WebKit, which Chickadee serves non-isolated on purpose, took the library's
  XMLHttpRequest fallback and worked fine. `scripts/patch-xeus-python-http.py`
  forces that fallback on every engine — upstream's own documented degradation
  for non-isolated contexts — and `check-xeus-vendored.sh` asserts it on the
  committed bytes, since the fault is invisible both in the JupyterLite REPL and
  on WebKit.

### Known issues

- **Editor and browser grader are no longer the same Python.** Authoring runs
  xeus-python 3.13; browser grading and `/validate` still run Pyodide 3.14. The
  native worker remains the authoritative grader, so marks are unaffected.


## [0.5.13] - 2026-08-05

### Added

- **Review: what the corrected Leaf rule unblocks.** `docs/leaf-decomposition-review.md`
  sizes the `assignment-new` / `_assignment-edit-body` duplication against real diffs
  rather than marker counts, and lands on a four-slice plan. Verifies (control-first,
  with a falsified assertion) that three inline partial includes resolve inside an
  extend/export block. Records two live create-page defects traced to duplicated
  JavaScript rather than to template structure: per-student `=` expressions degrade to
  literal strings in section inputs, and section drag-reorder raises a spurious failure
  alert because a second, redundant handler posts to an endpoint that does not accept
  the method.

### Fixed

- **Per-student `=` expressions no longer degrade to literal strings on the
  Create Assignment page.** That page carried a pre-v0.4.160 inline copy of the
  section-inputs editor whose value parser had no `=` branch, so an expression
  typed into a section input was persisted as the literal text and the payload
  omitted `expressions` entirely. It now loads the same shared modules the edit
  page uses.
- **Section drag-reorder now persists on the Create Assignment page.** The
  reorder endpoint was derived from the suite URL by rewriting a trailing path
  segment, which no-ops on that page's query-string URL and posted to a GET/PUT
  endpoint; the page's own fallback handler read an out-of-scope `draftID` and
  threw before its request. The list reordered on screen, nothing was saved, and
  a failure alert appeared. The endpoint is now an explicit, required builder.
- **Deleting a suite section no longer raises two confirmation dialogs** on the
  Create Assignment page, which bound duplicates of handlers `suite-table.js`
  already owns.

### Changed

- **The suite-section shells are one shared partial** (`_suite-sections.leaf`),
  used by both authoring surfaces, parameterized on the per-page endpoint base
  and whether its forms submit in place.
- **`checkUWDates` is shared** (`ChickadeeUI.checkUWDates`) instead of living as
  three inline copies that had drifted on null-handling and on label text. Both
  labels are preserved.


## [0.5.12] - 2026-08-05

### Changed

- **Switching notebooks in the workbench no longer reloads the page.** Opening
  the solution, or toggling between the authored template and the rendered
  values, swaps the notebook half in place instead of navigating. The Pyodide
  kernel still restarts — it belongs to whichever notebook is open — but the
  edit half is no longer rebuilt with it, so assignment details typed and not
  yet saved survive the switch. The address bar still moves, so a reload lands
  on the same notebook and Back returns to the previous one.

### Fixed

- **The workbench's view control showed the wrong view as selected.** "With
  values" was marked as the active choice regardless of what was open. Course
  staff are defaulted to the *template* on a notebook carrying placeholders, so
  the control mislabelled itself on exactly the assignments it exists for.

- **The workbench page no longer scrolls.** The shell sized itself to the full
  viewport while the site nav sat above it, making the document taller than the
  window — so the nav scrolled away under the pointer while the panes stayed
  pinned, contradicting the invariant the layout is built on. The chrome and the
  page body now share the viewport.


## [0.5.11] - 2026-08-05

### Changed

- **The assignment workbench is now a single document.** The edit page and the
  notebook editor were composed as two same-origin iframes; they are now
  rendered inline by one template, each bound to its own sub-context. The
  wrapper frames are gone and the only remaining `<iframe>` is the JupyterLite
  editor itself. Writes refresh the edit half by swapping its DOM rather than
  reloading, so a save, a suite-section rename, or a support-file upload no
  longer costs the live Pyodide kernel a 10–30s reboot. Switching between the
  starter and the solution stays a full navigation — the kernel restarts either
  way — and is guarded by an unsaved-changes prompt.

### Fixed

- **Leaf partial decomposition was never blocked by a LeafKit parser bug.** The
  long-standing rule of "at most one inline `extend(...)` include per template"
  traced to a misdiagnosis: what actually fails is the literal tag text
  appearing in template *prose*, including inside HTML comments, which Leaf's
  lexer reads as a real tag with no parameters. Multiple includes, and the
  sub-context form, work fine. `CLAUDE.md` is corrected.

- **An assignment with no starter notebook no longer breaks its workbench.**
  Inlining the notebook made a missing one able to fail the whole authoring
  page; the pane now degrades to a placeholder and the edit half stays usable,
  which is where a starter gets uploaded in the first place.


## [0.5.10] - 2026-08-04

### Fixed

- **Writes in the workbench no longer navigate the editor pane away.** Every
  form on the assignment editor — Save, Create solution, the secret-reveal
  toggle, and suite-section create/rename/delete — redirects to the chromed
  standalone editor when it succeeds. Inside the workbench that redirect landed
  *in the left pane*, so adding a suite section replaced the editor with a
  second copy of itself under the workbench's own Save button; because the
  standalone page is not cross-origin isolated, the browser then refused it
  under `require-corp` and the pane went blank. Those writes are now fetched and
  the pane re-renders itself, keeping the author's scroll position. The
  standalone `/edit` page is unchanged and still follows its redirects.
- **The workbench's Save reports the real result.** It replied "saved" before
  submitting, because the pane was about to navigate and a later reply would
  never arrive — so a failed save looked like a successful one.
- **`Create solution` no longer redirects to a 404.** It writes a draft
  notebook, but the solution resolver only looked in the test-setup zip and at
  validation submissions, so its own redirect target reported that no solution
  existed. Every other place that asks whether an assignment has a solution
  already counted the draft, which is why the Files table showed an Edit button
  beside a dead link.


## [0.5.9] - 2026-08-04

### Fixed

- **Browser probe setup retries the Ubuntu package fetch.** Installing Node and
  npm is an unauthenticated plain-HTTP fetch of ~40 packages from
  `archive.ubuntu.com`; when that mirror is unreachable the step exits 100 and
  takes the whole probe — and the required editor-smoke gate — down with it.
  Observed on PR #1264: `Unable to connect to archive.ubuntu.com`. The
  network-bound half now retries three times with a short backoff. `npm ci` is
  deliberately left outside the loop, so a genuine lockfile failure still fails
  once and clearly.

### Fixed

- **The CI image rebuild no longer times out.** `mirror-images.yml` builds the
  derived `swift-ci` image by apt-installing a heavy package set from
  `archive.ubuntu.com` behind a retry loop; with that mirror flaking the build
  step alone consumed 29.3 of its 30-minute budget and was killed, leaving the
  image unpublished. Since the job runs weekly, a silent timeout means a stale
  CI image for everyone. Budget raised to 60 minutes.

### Changed

- **Browser probe jobs run in the `swift-ci` image and own a build cache.** They
  previously used the plain Swift mirror and `apt-get`-installed Node and npm at
  job start — the same per-job cost the `swift-ci` image already exists to
  remove, and a hard failure whenever `archive.ubuntu.com` is unreachable.
  `nodejs`/`npm` are now baked into that image and the probes use it; the apt
  path remains as a guarded fallback so a caller on the plain mirror, or a run
  that beats the image rebuild, still works.

  They also now save and restore a probe-owned build cache when the shared
  swift-tests key misses. That key is written by a job in another workflow, so
  nothing could order the probes after it; a miss meant a cold Swift build, and
  re-running a probe on the same commit paid for it again every time because
  nothing the probes did ever populated a key they could read back. The shared
  key is deliberately left alone — a probe winning that race would publish a
  `.build` holding only `chickadee-server` for the swift-tests jobs to restore.

### Fixed

- **Browser probe jobs no longer time out on a cold build.** `browser-probe-setup`
  builds `chickadee-server`, and the shared build cache it restores is keyed on
  `hashFiles('Sources/**', 'Tests/**')` — so the key is new on any PR touching
  either, and the job that populates it lives in a different workflow, which
  `needs:` cannot order against. The probes therefore cold-build, and the setup
  step alone measured 23.2 min on a passing run and 29.0 min on a killed one,
  against a 30 min ceiling. The budget only ever fit the cache-hit path; on a
  miss the job died in setup with every test step `skipped`, and GitHub reports
  a timeout-kill as `cancelled`, which reads as an unrelated concurrency cancel.
  Budgets raised to 50 min (75 for the grading probe, which runs 12 iterations
  per engine on top of the same setup).

### Changed

- **The workbench is now the assignment editor.** The `/instructor` dashboard's
  Edit buttons open it, and its chrome has been cut back to what the panes do
  not already provide: no Assignment/Solution tab strip, no Hide-editor or
  Full-width-editor buttons, no repeated assignment title, and no Download in
  the notebook pane. The left pane already names the assignment, lists its
  files with links, and offers Edit for each.

- **One Save, in the top-right corner.** "Save & Validate" and "Save to
  assignment" were two buttons for what an author thinks of as one action.
  The single Save writes the open notebook and the assignment's details and
  re-validates.

  It deliberately does **not** close the assignment. The standalone edit page
  still does, unchanged — but the workbench is a live-edit surface, where the
  suite, families and notebook endpoints all already write without changing
  visibility, and closing on save there would pull a lab out from under the
  students sitting in it.

- **Clicking Edit in the Files table opens that notebook in the workbench's
  notebook pane.** Previously those links carried no `embedded=1`, so inside
  the workbench they navigated the *left* pane into a fully chromed notebook
  page and the assignment editor disappeared. They are still ordinary links on
  the standalone page.


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

