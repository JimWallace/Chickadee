# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project follows Semantic Versioning.

## [Unreleased]

## [0.4.138] - 2026-04-30

### Changed

- **Centralized SHA-256 hex hashing in `Core` (#445).**  Six places
  across the server and runner had grown their own copy of the
  `Data(SHA256.hash(...)).map { String(format: "%02x", ...) }.joined()`
  one-liner — `WorkerJobRoutes` (test-setup download version),
  `AssignmentHelpers.manifestHash` (the v0.4.93 retest dedup key),
  `PatternFamilyRenderer` and `NotebookCheckRenderer` (manifest spec
  hashes), `RunnerDaemon` (test-setup cache key), and
  `WorkerRequestSigner` (X-Worker-Body-SHA256 header).  Both the server
  and the runner have to agree byte-for-byte on the format of the
  retest hash, but nothing was pinning that contract.

  Adds `sha256HexDigest(_:)` (over `Data` and `String`) to
  `Core/Hashing.swift` and migrates every site to call it.  Adds
  `swift-crypto` as a direct dependency of `Core` (already present
  transitively via Vapor; resolved version is unchanged).  New
  `HashingTests` pins the digest format with FIPS 180-4 reference
  vectors so a future algorithm change has to be intentional.

  HMAC-SHA256 (the worker-auth signature primitive) stays where it is
  — it's a different primitive with constant-time-equality concerns of
  its own, not a content fingerprint.

  Also cleaned up three pre-existing unused `import Crypto` lines
  (`AssignmentRoutes`, `AssignmentRoutes+Editor`, `WebRoutes`) so every
  remaining `import Crypto` in the tree corresponds to genuine
  cryptographic use.

## [0.4.137] - 2026-04-29

### Fixed

- **Solution-notebook load timeout now surfaces a clear error
  instead of leaking the internal sentinel.**  v0.4.136 added the
  30s `LOAD_TIMEOUT_MS` cap on the cell-load phase but the rejection
  fell through to the outer `catch` in `callSolution`, which had no
  branch for `__chickadee_timeout__` (only the inner `catch` did).
  Result: the Expected cell showed `⚠ __chickadee_timeout__` —
  technically correct (the load DID time out) but unhelpful.  Now
  translates the sentinel into `solution notebook load timed out
  after 30s`, sets `res.timedOut = true` so the UI's existing
  timed-out branch handles it, and shows a load-specific tooltip
  pointing the instructor at top-level setup cells (vs the
  function-under-test, which is what the run-phase tooltip
  describes).  Closes the polish gap on the
  "infinite loop in the first cell of the solution notebook"
  scenario.

## [0.4.136] - 2026-04-29

### Fixed

- **Pattern-family auto-compute solution-load can no longer hang
  forever.**  v0.4.135's worker-based fix moved Pyodide off the main
  thread so synchronous tight loops in the *function under test* no
  longer froze the browser — but I left the cell-load phase
  (`workerSend({type:'loadCells', cells:...})`) without a timeout
  (passed `0`).  A pathological top-level cell — `while True: pass`
  *outside* any function, a `pd.read_csv(...)` with a typo that
  loops forever, etc. — would hang the auto-compute on
  "computing…" forever.  The browser stayed responsive (worker
  thread, not main thread), but the user got no signal that the
  load failed.

  Adds `LOAD_TIMEOUT_MS = 30000` (30s) for the load phase.  Generous
  enough for legitimate heavy imports / large pandas reads, bounded
  enough to recover the editor when a setup cell goes wrong.  On
  timeout the worker is terminated and the next attempt re-loads
  from scratch.

### Verified (no code change needed)

- **`return None` from the solution function is correctly handled
  through the worker pipeline.**  Traced end-to-end: the value-mode
  Pyodide snippet's `_result is None` branch sets
  `__chickadee_kind__: "none"`; the JS side detects that key and
  returns `{ok: true, value: null, returnedNone: true}`; the UI
  renders the "⚠ solution returned None" hint without filling the
  Expected cell.  The 5-second function-call timeout still kicks
  in if the function takes too long *to return* None — the worker
  is terminated on the main-thread timer regardless of what the
  function would have returned.

## [0.4.135] - 2026-04-29

### Fixed

- **Pattern-family editor's auto-compute can no longer hang the
  browser.**  Pyodide ran on the main thread, so a synchronous tight
  loop in the instructor's solution notebook (`while True: pass`,
  infinite recursion) blocked the event loop indefinitely — the 5s
  `Promise.race` timeout fired but the main thread was already
  frozen, so the modal and the rest of the page became
  unresponsive until the tab was force-quit.  Past mitigations
  (v0.4.124 None-return guard, v0.4.125 AST-shape fix, v0.4.130
  type-check guards) only addressed cooperative hangs (code that
  yields via `await`); they couldn't catch CPU-bound run-aways.

  v0.4.135 moves Pyodide into a Web Worker (`Public/pyodide-worker.js`).
  The worker thread is independent of the UI thread, so a synchronous
  tight loop no longer freezes the page.  When the 5s timeout fires
  the main thread terminates the worker (killing whatever Python is
  running) and allocates a fresh worker for the next call — the first
  call after a kill pays the ~5s Pyodide reload cost again, but the
  modal stays interactive throughout.  No SharedArrayBuffer required
  (the COEP headers a SAB-based interrupt would need are deliberately
  scoped away from `/instructor/:id/edit` so CodeMirror's CDN imports
  keep working).



### Fixed

- **Sections, notebook checks, and per-entry `sectionID` were dropped on
  publish from the create page.**  `saveNewAssignment` rebuilt the
  manifest via `makeWorkerManifestJSON(testSuites:patternFamilies:)`
  with `sections` and `notebookChecks` defaulting to `[]`, silently
  discarding anything authored on the draft.  Per-entry `sectionID`
  was also stripped through the `ReindexedSuiteConfigRow` JSON
  round-trip.  Combined effect: an instructor who built sections + a
  notebook check on the create page would publish an assignment with
  none of that state — sections became empty headers; check-generated
  entries fell into the trailing Ungrouped block.  Surfaced during the
  v0.4.132 / v0.4.133 audit (the `applyPatternFamilies` re-run was
  gated on `!existingFamilies.isEmpty`, so a draft with sections but
  no families never got the `applyPatternFamilies` rebuild that would
  have re-stamped per-entry `sectionID`).

  Fix: forward `notebookChecks` + `sections` through
  `makeWorkerManifestJSON`, run `applyPatternFamilies` whenever
  *any* of families / checks / sections is present, and propagate
  `sectionID` (plus `.check(id:, sectionID:)` items, previously
  unhandled) through `authoredSuiteItemsFromDraftManifest`.
  Regression guard: `testApply_createPublishPreservesSectionsAndChecks`
  in `Tests/APITests/PatternFamilyTests.swift`.

## [0.4.133] - 2026-04-29

### Fixed

- **Save & Validate on every assignment edit page 403'd with "No CSRF
  token provided".**  Pre-fix, `Public/suite-table.js`'s submit listener
  flushed any pending suite/section-vars saves and then re-submitted the
  form via `form.submit()` — but `form.submit()` deliberately bypasses
  submit-event listeners, including [`base.leaf`](Resources/Views/base.leaf:78)'s
  multipart-CSRF intercept that adds `x-csrf-token` to the request
  headers.  Without that header the multipart body's `_csrf` field is
  unreachable to the CSRF middleware (the body isn't buffered before the
  middleware runs), so every save was rejected.  Switched to
  `form.requestSubmit()` (which fires submit events) plus a one-shot
  `__chickadeeFlushed` flag that skips suite-table's listener on the
  re-fired event, letting base.leaf's intercept handle it.  Bug present
  since v0.4.102 — masked on browsers with stale-cached pre-0.4.102
  `suite-table.js`, hence the "works on my laptop, fails on my desktop"
  asymmetry.

## [0.4.132] - 2026-04-29

### Added

- **Create-page UI parity (#433).**  Four small follow-on PRs land
  together as v0.4.132, bringing the create-assignment page
  (`/instructor/new`) up to date with the edit page on the features
  instructors are using heaviest this term.  None of these are new
  capabilities — they're parity work; the underlying server-side
  endpoints are the v0.4.131 shared core (`SuiteEditHelpers.swift`)
  applied to draft-scoped routes.

  - **Sections on the create page (#435 / parity PR 1).**  Five new
    draft-scoped section-CRUD endpoints
    (`POST /instructor/new/draft/suite-sections{,/reorder,/:sid/rename,
    /:sid/delete,/:sid/variables}`) and a leaf rewrite that drops the
    legacy `suite-list.js` IIFE in favor of the unified `suite-table.js`.
    Instructors can now author with sections **before** publishing —
    no more publish-then-reopen-to-add-sections two-step.
  - **Notebook Checks editor on the create page (parity PR 2).**  New
    `PUT /instructor/new/draft/checks` endpoint plus the check-editor
    modal HTML, `notebook-checks-seed`, and per-section `+ Add Check`
    button delegation copied from the edit page.  `notebook-check-editor.js`
    is shared.
  - **Support files on the create page (parity PR 3).**  New
    `GET /instructor/new/draft/files/item?draftID=…&name=…` download
    endpoint; existing `POST /draft/scripts` (with `tier: "support"`)
    and `DELETE /draft/scripts/:filename` already worked.  Notebook
    files-table grows a "Support file" row per bundled CSV/JSON plus an
    "+ Upload file" picker — same behaviour as the edit page.
  - **"Create from Assignment" button (parity PR 4).**  New
    `create-solution-from-assignment` draft action copies the assignment
    notebook bytes (normalized for JupyterLite) into the draft solution
    path, mirroring the assignment-scoped `POST /:id/create-solution`.
    Visible only when an assignment notebook exists but no solution does.

### Refactor

- **`mutateManifest` promoted out of `AssignmentRoutes+SuiteSections.swift`**
  and into `SuiteEditHelpers.swift` so the new
  `AssignmentRoutes+DraftSections.swift` (parity PR 1) can share it.
  Identical behaviour; the helper is just no longer file-private.
- **`NewAssignmentContext` grows `suiteStateJSON`, `suiteSectionRows`,
  `supportFileRows`, and `notebookChecksJSON`** alongside the existing
  `EditAssignmentContext` fields it now mirrors.  The `instructorNewAssignment`
  handler reuses the existing `suiteStateJSON(fromManifest:)` and
  `suiteSectionShellRows(fromManifest:)` helpers from
  `AssignmentRoutes+Suite.swift` — no new helpers, no duplication.

## [0.4.131] - 2026-04-29

### Refactor

- **Shared core for the suite / families / checks / suite-sections
  endpoints.**  Pre-fix, every `:assignmentID`-scoped editor handler had
  a draft-scoped sibling at `/instructor/new/draft/...` that duplicated
  the auth check, setup resolution, body decoding, DTO translation, and
  JSON response building.  That duplication was the structural reason
  the create page is multiple versions behind the edit page on
  Sections, Notebook Checks, and Support Files: each new feature on the
  edit side meant writing (and forgetting) a parallel draft handler.
  The new `Sources/APIServer/Routes/Web/SuiteEditHelpers.swift` exposes
  `requireInstructor`, `loadAssignmentAndSetup`, `loadDraftSetup`,
  `applySuiteEdit`, `applyPatternFamiliesEdit`, `applyNotebookChecksEdit`,
  and `jsonResponse` — `AssignmentRoutes+Suite.swift`,
  `AssignmentRoutes+Families.swift`, `AssignmentRoutes+Checks.swift`,
  `AssignmentRoutes+SuiteSections.swift`, and `AssignmentRoutes+Draft.swift`
  all collapse to thin handlers that resolve their target and call into
  the shared core.  Net: ~150 fewer lines, and adding a draft-scoped
  Checks / Sections / SectionVariables endpoint is now a few lines of
  routing rather than a duplicate handler.

### Fixed

- **Drafts now persist `sectionID` on suite items through `PUT /draft/suite`**
  and preserve pattern-family `variables` on row-level edits.  Both
  fields landed on the assignment-scoped path
  (`AuthoredSuiteItem.sectionID` in v0.4.96, `PatternFamily.variables`
  in v0.4.94) but the draft-side handler still used the pre-v0.4.96
  payload shape — a section assignment made via the suite editor on
  the create page would silently drop on save.  Routing draft saves
  through `applySuiteEdit` (the same shared core the assignment-scoped
  handler uses) closes the gap as a side effect of the refactor.  No
  draft data has been lost; pre-fix the field simply wasn't accepted on
  save (the create page hasn't shipped a Sections UI yet, so this only
  manifested for clients sending the field directly).

## [0.4.130] - 2026-04-29

### Fixed

- **Pattern family auto-compute now flags non-JSON-native return types
  instead of silently storing the wrong value.**  When the instructor's
  solution function returned a `coroutine` (async function used by
  mistake), `generator`, `async-generator`, `set`, `tuple`, `bytes`, or
  `complex`, the Pyodide auto-computer used `_json.dumps(..., default=str)`
  as a fallback and landed `"<coroutine object f at 0x...>"` (or, for
  tuples, a JSON array that compared `False` against the runner-side
  tuple at grading time) in the Expected cell as if the instructor had
  typed it.  The cell now shows a specific reason ("solution returned
  an async function (returned a coroutine without awaiting it)", "…a
  set", "…a tuple", etc.) with an actionable tooltip; `Expected` stays
  blank so it can't accidentally round-trip the wrong value.
- **Auto-compute now explains *why* a missing function is missing.**
  When a solution-notebook cell raised before reaching the function
  definition, the editor saw a generic "function `foo` not defined in
  solution notebook" message that didn't mention the underlying cell
  failure.  Per-cell errors are now collected during solution load and
  folded into the missing-function message ("…not defined (cell 2
  failed: NameError on line 3)") so the instructor knows which earlier
  cell to fix.

### Added

- **Validation runner availability is pre-checked on every save path,
  not just create-assignment.**  The live-edit save path
  (`POST /instructor/:id/edit/save`) and the suite-edit auto-trigger
  (`scheduleValidationAfterSuiteEdit`, fired by `PUT /suite` and
  `PUT /families`) now pre-check
  `ensureCompatibleValidationRunnerAvailability` against the
  assignment's persisted requirements.  If no compatible runner is
  available (and local-runner-autostart can't bring one up), the
  assignment's `validationStatus` is set to a new `"no-runner"` state
  and *no validation submission is enqueued* — pre-fix the row was
  queued and sat indefinitely.  The assignments list shows a distinct
  "no runner" badge with a tooltip directing the instructor to ask an
  admin to start a compatible runner, then re-save.  Mirrors the
  create-assignment path's pre-existing behaviour.

## [0.4.129] - 2026-04-28

### Fixed

- **"Students With No Submissions" dashboard card now includes pending
  pre-enrollments.**  v0.4.126 widened the per-assignment
  `enrolledStudentCount` (the badge denominator) to include CSV-uploaded
  students who haven't logged in yet, but the dashboard card was left
  scoped to active student users only.  Result: an instructor who bulk-
  enrolled 151 students via CSV and had only 12 of them log in saw
  "Students With No Submissions: 12" on the day of upload, which
  massively understated the engagement gap (the other 139 students
  hadn't even signed in yet, let alone submitted).  The card now adds
  `pendingPreEnrollments.count` to the active-student gap so it's
  consistent with the badge denominator.
- The other dashboard cards (24h Active, 24h Submissions, Assignments
  Active (24h), Queued Right Now) were already correct: they count
  events or recently-active users, neither of which a pending pre-
  enrollment can contribute to.

### Added

- Regression test
  `AssignmentRoutesTests.testInstructorDashboardCountsPendingPreEnrollmentsAsNoSubmissionYet`:
  enrolls 2 students (1 submits, 1 doesn't) plus 1 pending
  pre-enrollment, asserts the card reads 2.  Pinned to the literal
  card structure via regex so a regression in another metric's value
  can't accidentally pass it.  Verified to fail with a precise
  diagnostic ("1" vs "2") against the pre-fix code.

## [0.4.128] - 2026-04-28

### Fixed

- **Brightspace gradebook CSV bulk-enrol now imports the whole class
  (not just the test accounts).**  In a real UWaterloo HLTH 230
  gradebook export, the `Username` column carries two distinct shapes:
  - `#<digits>.<rest>` for institution-issued gradebook test accounts
    (e.g. `#174667.teststudent1`)
  - bare `#<rest>` for actual students (e.g. `#mj39lee`,
    `#20878497`) — Brightspace prepends `#` to every cell purely as
    an Excel-anti-coercion hack so spreadsheet tools don't auto-
    convert numeric quest IDs to numbers
  v0.4.120's prefix-stripping handled only the dotted form, so
  uploading a real export accepted the 2 test rows but rejected
  every actual student (their `#mj39lee`-style values fell through
  unchanged and were then rejected by
  `isAcceptableUsernameForEnrollment` for containing `#`).
  `stripBrightspacePrefix` now drops the leading `#` for every
  Brightspace-shaped cell.  Verified against the user's real export
  (146 rows, 144 students enrolled where 0 were enrolled pre-fix).

### Changed

- **Brightspace gradebook test accounts are now filtered out of the
  enrol roster.**  Rows whose value matches the namespaced
  `#<digits>.<rest>` shape are dropped at parse time — those are
  Brightspace gradebook test accounts and shouldn't pollute a real
  class roster.  New `isBrightspaceTestAccount` predicate gates the
  filter so the rest of the class (bare-`#` values) parses normally.
  In the user's real export this drops the 2 `teststudent` rows
  alongside the existing 144 students.

### Added

- Updated `EnrollCSVHelperTests`:
  - Renamed `brightspaceGradebookExport` →
    `brightspaceGradebookExportFiltersTestAccounts` and inverted its
    expected output to reflect the new filtering behaviour (all-test-
    account input → empty parsed list).
  - Renamed `stripsBrightspacePrefixOnSingleColumn` →
    `brightspaceTestAccountsAreSkippedOnSingleColumn` (same flip).
  - Replaced `leavesNonBrightspaceHashPrefixedUsernamesAlone` (which
    encoded the wrong assumption that a bare `#` prefix wasn't a
    Brightspace artifact) with `stripsBareHashPrefix`.
  - Added `brightspaceRealWorldClassExportFiltersTestAccountsAndKeepsStudents`
    driven by the actual user-reported file shape: 5 rows
    (2 test accounts + 3 real students) → 3 students emitted.

## [0.4.127] - 2026-04-28

### Fixed

- **Class-wide achievement badges no longer go to admin/instructor
  submissions.**  An instructor or admin who tested an assignment via
  the same submit flow students use could earn — and lock in — the
  Pathfinder (first to submit) and Trailblazer (first to score 100%)
  badges before any real student got to attempt the assignment.  Both
  badges have a unique constraint on `(test_setup_id, achievement_id)`,
  so once an instructor's test submission claimed them no real student
  could ever earn them.  Speed Champion / Minimalist (record-holder
  badges) had a milder version of the same problem: an
  admin/instructor's record persisted until a student beat it.
- **Pathfinder fix** (`WebRoutes+Submission.swift`): the award block
  now checks the submitter's role and tests for an existing pathfinder
  row directly (using the unique constraint as the natural gate),
  instead of relying on `classCount == 1` over the unfiltered
  student-kind submissions count.  An admin's submission no longer
  blocks the next real student from earning Pathfinder.
- **Trailblazer / Speed Champion / Minimalist fix**
  (`ClassAchievements.swift`): `awardClassBadgesFor100Percent` now
  loads the submitter's `APIUser` and bails early when
  `role != "student"`.  This is defence-in-depth at the helper entry
  so every current and future call site (currently
  `ResultRoutes.swift`) inherits the gate without needing to
  reimplement the check.

### Added

- Three regression tests in `WebRoutesTests`:
  - `testPathfinderNotAwardedToAdminSubmission` — admin submits, no
    Pathfinder row created.
  - `testPathfinderAwardedToFirstStudentEvenAfterAdminSubmits` — admin
    submits first (no badge), then a real student submits and Pathfinder
    lands on the student's userID, not the admin's.
  - `testAwardClassBadgesFor100PercentSkipsAdminAndInstructor` —
    direct-helper test: calls with admin and instructor users yield
    zero rows; calls with a student yield all three badges
    (`trailblazer`, `speed_champion`, `minimalist`), each owned by
    the student.

### Notes

- Per-submission badges (Ace / First-Try Perfect, Rally, Tenacious,
  Swift) are still computed on-read for any submitter and shown on the
  submitter's own pages.  These are personal feedback, not aggregate
  stats — an admin viewing their own test submission seeing
  "First-Try Perfect" doesn't pollute any class-level metric.  If you
  want these gated as well, that's a follow-up: the BadgeContext
  computation in `WebRoutes+Submission.swift` is where to filter.
- Pre-existing class-wide badges held by non-students (from before
  this fix) are not retroactively cleaned up.  If your database has
  any, run a manual `DELETE FROM class_achievements WHERE user_id IN
  (SELECT id FROM users WHERE role != 'student');` once.

## [0.4.126] - 2026-04-28

### Fixed

- **Per-assignment "X / Y students submitted" badge now excludes
  admin/instructor users.**  When an instructor enrolls themselves in
  their own course (a common pattern for testing assignments through
  the same submit flow students use), their submissions inflated both
  sides of the badge: `submittedStudentCount` (X) was computed from a
  submissions query with no role filter, and `enrolledStudentCount` (Y)
  was just `enrolledStudents.count` — which includes admins/instructors
  enrolled in the course.  Both counters now scope to enrolled users
  with `role == "student"`, plus pending pre-enrollments on the
  denominator (so the badge reflects the instructor's roster intent
  rather than just who has logged in).  Regression test in
  `AssignmentRoutesTests.testInstructorDashboardBadgeCountsStudentsOnly`
  enrolls 2 students + 1 instructor + 1 admin, has each submit, and
  asserts the badge reads `2 / 2 students submitted` (not `4 / 4`).
- The other dashboard cards (24h Active, 24h Submissions, Assignments
  Active (24h), Queued Right Now, Students With No Submissions) were
  already filtered correctly via `enrolledStudentIDs`; only the
  per-assignment badge had the inconsistency.

## [0.4.125] - 2026-04-28

### Fixed

- **Pattern family auto-compute (value-mode) was broken in v0.4.124.**  The
  v0.4.124 sentinel-keyed Pyodide snippet ended in an `if/else` top-level
  statement.  Pyodide's `eval_code` only returns a value to JS when
  `body[-1]` of the parsed AST is an `ast.Expr`; for any other top-level
  statement type (`If`, `With`, `Assign`, `Import`, …) it returns `None`.
  That meant `runPythonAsync` resolved with `undefined`, downstream
  `JSON.parse(undefined)` threw, and the Expected cell always landed in
  the `⚠ Unexpected token …` error branch instead of filling with the
  function's return value.  The stdout-mode snippet from v0.4.124 was
  unaffected (its last statement was already an expression).
- The fix factors the JSON payload into a single conditional expression
  assigned to `_payload`, with a final bare `_json.dumps(_payload,
  default=str)` expression statement on the last line — that's now an
  `ast.Expr` and Pyodide returns the JSON string as expected.

### Added

- **Regression test in `Tests/BrowserRunnerJSTests/pattern-family-editor.test.mjs`.**
  Reads each Pyodide snippet from the live JS file (between
  `// PYODIDE_SNIPPET_BEGIN: <name>` and `// PYODIDE_SNIPPET_END: <name>`
  marker comments), reconstructs the Python source under fake
  `fnLit`/`argsLit` substitutions, and shells out to `python3` to assert
  `body[-1]` is `ast.Expr`.  Catches the v0.4.124 shape directly (verified
  by re-introducing the bug locally — test fails with a precise
  `last top-level statement is If, not ast.Expr` diagnostic).  Picked up
  automatically by the existing `node --test Tests/BrowserRunnerJSTests/*.mjs`
  step in `.github/workflows/swift-tests.yml`.

## [0.4.124] - 2026-04-27

### Added

- **`stdout_equality` pattern family kind** — a seventh `PatternKind` for grading
  beginner exercises where the student is expected to `print(...)` rather than
  return.  Each case calls the function with its args inside
  `contextlib.redirect_stdout(io.StringIO())`; the captured string is compared
  to the case's `expected` (a string).  A single trailing newline is trimmed
  from both sides so `print("hi")` matches an instructor-typed Expected of
  `"hi"`; internal newlines and leading whitespace are preserved.  The
  function's return value is ignored — instructors who care about both stdout
  and the return value should write two families.  Empty-string Expected is
  permitted (the legitimate "this function should print nothing" case).
- **Auto-compute now captures stdout for `stdout_equality` families.**  The
  Pyodide-backed Expected auto-compute in the family editor uses
  `redirect_stdout` when the kind is `stdout_equality`, so the cell auto-fills
  to whatever the solution function prints.
- **`assignment-new.leaf` now exposes all seven pattern kinds** in the kind
  dropdown.  Pre-v0.4.124 the new-assignment page only listed three of the six
  existing kinds (`return_type_check`, `exception_expected`,
  `performance_threshold` were missing); fixed in passing.

### Fixed

- **Pattern family auto-compute no longer hangs / mis-fills when the solution
  function returns `None`.**  Pre-fix, the JSON round-trip turned Python
  `None` into the string `"null"`, which then landed in the Expected cell
  as if the instructor had typed it (round-trippable as a literal value,
  silently broken).  The Pyodide bridge now uses a sentinel-keyed wrapper
  (`{"__chickadee_kind__": "none" | "value"}`) that distinguishes a `None`
  return from a legitimate `null` value; the editor renders this with an
  empty cell and an orange `⚠ solution returned None` placeholder, with a
  tooltip suggesting `stdout_equality` (the most common reason a function
  returns None is that it `print()`s instead of returning).
- **5 s hard timeout on Pyodide auto-compute.**  `callSolution` now switches
  to `runPythonAsync` and races against a `Promise.race` timer, so a
  cooperative hang in the solution notebook (`asyncio.sleep`, blocking I/O,
  `input()`) flips the cell to a clear `⚠ timed out after 5s` instead of
  stranding the modal on the "computing…" placeholder forever.  Tight Python
  CPU loops still block until the runtime returns control to JS — fully
  fixing that needs Pyodide-in-Web-Worker, which is a larger rework.

## [0.4.123] - 2026-04-27

### Added

- **Pending pre-enrollments now show in the instructor roster.**  v0.4.121 added the `pre_enrollments` table but the instructor's roster view only queried `APICourseEnrollment`, so bulk-uploaded students who hadn't logged in yet were invisible.  Now they appear in the same Enrolled-students table, visually muted with an "awaiting first login" tag and a `(pending)` role label, and the row's Remove button cancels the pending pre-enrollment instead of erroring.
- **`POST /courses/:courseID/pre-unenroll/:preEnrollmentID` endpoint** to cancel a pending pre-enrollment.  Same instructor-only authz as the regular unenroll endpoint.
- **`users.last_seen_at` column + `UserActivityMiddleware`.**  Refreshes a user's activity timestamp on every authenticated request (debounced to 60 s).  Without it, the admin/instructor dashboards' "Last Login" column froze at the moment the cookie session was first established and read "active 2 weeks ago" for users browsing daily.  The instructor "24h Logged In" metric is now "24h Active" and counts students seen within the window, not just freshly logged-in ones.  Admin and instructor roster columns renamed accordingly; ISO-formatted timestamp surfaced via `data-iso` for client-side relative formatting.

### Changed

- **`EnrolledStudentRow` carries an `unenrollURL` field** so the template doesn't have to branch on row type to produce the right form action.  Active rows point at `/unenroll/:userID`; pending rows at `/pre-unenroll/:preEnrollmentID`.

## [0.4.122] - 2026-04-27

### Added

- **Server health alerts.**  A periodic monitor evaluates four threshold rules and
  pushes a JSON webhook (Slack / Discord / ntfy.sh / Pushover / Twilio Studio Flow)
  when one fires, with a 30-minute cooldown per rule and a follow-up
  `"resolved": true` message when a rule clears.  Pattern mirrors
  `StuckSubmissionReaperService` — `ServerHealthAlertMonitor` actor + a
  `LifecycleHandler` registered in `configure()` next to the other monitors.
  Cost is in the noise: ~3 small indexed queries per minute, all reusing existing
  signal sources (`WorkerActivityStore`, `JobExecutionMetric`, the same
  `SELECT 1` probe `/health` already runs).
  - **Rules** (all opt-in via `ALERT_ENABLED=1`):
    - `runnerOffline` — no runner heartbeat for `ALERT_RUNNER_OFFLINE_SECONDS` (300s)
      while at least one submission is pending.  Avoids weekend noise: a silent
      runner with an empty queue is fine.
    - `queueBackedUp` — `pendingCount` ≥ `ALERT_QUEUE_DEPTH_THRESHOLD` (25) OR the
      oldest pending submission is older than `ALERT_OLDEST_PENDING_SECONDS` (600).
    - `errorRateSpike` — over the last 50 finalised jobs, `error+timeout` ratio
      ≥ `ALERT_ERROR_RATE_THRESHOLD` (0.30).  Skipped if fewer than 10 samples in
      the window, so freshly-restarted servers don't false-fire on a single
      timeout.
    - `databaseUnreachable` — same `SELECT 1` probe used by `/health`.
  - **Admin UI** at `GET /admin/alerts`: webhook URL form (persisted to
    `.alert-webhook-url`, mirroring `.worker-secret`'s on-disk cascade), a
    "Send test alert" button that exercises the configured notifier without
    needing a real outage, a per-rule status table, and the last 50 firings
    (in-memory ring buffer; persistence is out of scope for v1).
  - **Webhook payload** is consumable as-is by Slack, Discord, ntfy.sh, and
    Pushover — every firing includes a top-level `text:` summary alongside the
    structured fields (`rule`, `severity`, `firedAt`, `resolved`, `summary`,
    `details`, `serverURL`).
  - **Configuration** is env-var driven (`ALERT_ENABLED`, `ALERT_CHECK_INTERVAL_SECONDS`,
    `ALERT_COOLDOWN_SECONDS`, `ALERT_RUNNER_OFFLINE_SECONDS`,
    `ALERT_QUEUE_DEPTH_THRESHOLD`, `ALERT_OLDEST_PENDING_SECONDS`,
    `ALERT_ERROR_RATE_THRESHOLD`, `ALERT_WEBHOOK_URL`); `ALERT_WEBHOOK_URL` is
    also editable via the admin UI and persists across restarts.

## [0.4.121] - 2026-04-27

### Added

- **Pre-enrollment from CSV — instructors can populate a course roster before students log in.**  Bulk-enroll's behaviour for usernames with no matching `APIUser`:
  - **Before:** silently dropped (reported as "not found").
  - **After:** recorded in a new `pre_enrollments` table.  The next time the matching student authenticates (SSO or local), a post-login resolver creates the `APICourseEnrollment` and deletes the pending row.
- The login flow itself is **completely untouched** — `upsertUser` is unchanged, the new resolver runs *after* the user is already authenticated.  A bug in the resolver can leave a student off the roster (which the instructor can correct manually) but cannot block them from signing in.  This is a deliberate design choice over the alternative of pre-creating placeholder `APIUser` rows: that approach would have introduced a new claim-on-first-login path inside the SSO upsert, where any failure mode means lockout.

### Changed

- **Bulk-enroll result page** distinguishes Enrolled (existing accounts), Pre-enrolled (queued for first login), Already enrolled (skipped), and Rejected (invalid format) — the old "Not found" bucket merged the second and fourth, which was misleading.
- **Bulk-enroll is idempotent**: re-uploading the same CSV makes no further changes — pre-enrollments get a `(course_id, username)` unique constraint.

## [0.4.120] - 2026-04-27

### Changed

- **Bulk-enroll CSV parser now handles Brightspace / D2L gradebook exports.**  Three loosened rules:
  - `OrgDefinedId` joins the recognised header keywords, so the header row in `OrgDefinedId,Username,End-of-Line Indicator` exports is correctly skipped instead of being treated as a username.
  - When the header has multiple columns, a column literally named `Username` is preferred over the first column (Brightspace puts the friendlier identifier there).
  - Values matching the Brightspace `#<digits>.<rest>` shape are stripped to the bare username — `#174667.teststudent1` resolves to `teststudent1`, matching the quest name UW's OIDC sets as `APIUser.username` (via `winaccountname`).  Conservative: only fires when the prefix is `#<digits>.`, so non-Brightspace `#`-prefixed usernames pass through unchanged.

  The previous parser silently dropped Brightspace exports — first column was `OrgDefinedId`-prefixed, never matched any account, so every student landed in "not found".

## [0.4.119] - 2026-04-27

### Fixed

- **Multipart-form interceptor 404'd handlers that render a result view directly.**  Every multipart form on the site goes through a JS interceptor in `base.leaf` that re-submits via `fetch` with `x-csrf-token` in a header (because the body stream isn't read before the CSRF middleware runs).  The post-fetch step set `window.location.href = res.url`.  When the server responded with a redirect, fetch followed it and `res.url` was the redirect target — fine.  When the server responded with **200 + an HTML result page** (no redirect), `res.url` was the POST URL itself; setting `location.href` to a POST URL triggers a GET, which has no handler, hence the 404.  Affected `instructorBulkEnrollCSV` and `adminBulkEnrollCSV` (both render `admin-enroll-csv-result` directly) and any future multipart handler that returns a View.  Fix: the interceptor now distinguishes `res.redirected` (still navigates) from a non-redirect response (renders the response HTML in place via `document.open/write/close` so the result page replaces the form, the URL bar matches what the server saw, and a refresh resubmits — exactly what a native form submit would do).

## [0.4.118] - 2026-04-26

### Added

- **Phase C, part 2 — three more kinds.**  Completes the script-template absorption work flagged in v0.4.117 (NotebookCheck + PatternFamily as the primary authoring paths; scripts stay as the escape hatch and the templates remain for examples and starting points):
  - `.exceptionExpected` PatternFamily kind — calls the function with each case's args and asserts a specific exception type was raised.  Per-case `expected` is a string naming the class (`"ValueError"`, `"TypeError"`, etc.).  Matches via class-name MRO walk so subclasses count as a match.  Useful for input-validation exercises.  Replaces the `py:exception` script template's logic structurally.
  - `.performanceThreshold` PatternFamily kind — wraps the function call in `time.perf_counter()` and asserts the elapsed time stays below a per-case millisecond budget.  Per-case `expected` is a number (decoded as Double; integer JSON tolerated).  Single-trial for v1; multi-trial median can come later if jitter becomes a problem.  Replaces the `py:performance` script template.
  - `.astStructure` NotebookCheck kind — parses every code cell of the preserved `_submission.ipynb` and asserts a list of structural predicates: `for_loop`, `while_loop`, `list_comprehension`, `lambda`, `recursion`, or `import:<module>`.  Negate any predicate with a leading `!` (`!for_loop` = "must NOT use a for-loop").  Replaces the `py:structural_check` script template.
- **Auto-compute skips for non-scalar-expected kinds.**  `.returnTypeCheck` / `.exceptionExpected` / `.performanceThreshold` all want the instructor to type a class name or millisecond budget, not the function's return value, so the auto-compute path no-ops for these kinds.  Same skip behaviour as `.variableEquality`.

## [0.4.117] - 2026-04-26

### Added

- **Phase C, part 1 — two new kinds + a student-side download endpoint.**
  Per the v0.4.114 follow-up direction (NotebookCheck + PatternFamily as the primary authoring paths, scripts as the escape hatch):
  - `.functionExists` NotebookCheck — asserts a named function is defined on `student_module` and is callable, with optional exact-arity check.  Mirrors the `py:exists` script template's logic in a structured kind.  Useful as a precondition before correctness tests so a missing function fails clearly instead of erroring every dependent test.
  - `.returnTypeCheck` PatternFamily kind — calls the function with each case's args and asserts the result is an instance of the expected type.  Per-case `expected` is a string naming the type: Python builtins (`"int"`, `"list"`, `"dict"`, etc.), library types via class-name MRO walk (`"DataFrame"`, `"Series"`, `"ndarray"`), or any user class name.  Auto-compute is intentionally skipped for this kind (the type name is what the instructor wants to type, not the value).
- **Student-side support file download** — new `GET /api/v1/testsetups/:setupID/support/:filename` endpoint, parallel to the existing `/assignment/download` route with the same enrolled-student gate.  Refuses to stream test scripts and notebooks; only serves files classified as `tier == "support"`.  Pairs with the JupyterLite read-only symlink mechanism (v0.4.116) so students can both edit the notebook in-browser AND download support data for offline work.

## [0.4.116] - 2026-04-26

### Fixed

- **Support files uploaded via "+ Upload file" weren't reaching student JupyterLite working dirs.**  The infrastructure already exists (`createSupportFileSymlinks` symlinks every support file from a shared extraction at `{testSetupsDir}/shared/{setupID}/` into each student's per-user JupyterLite working dir at notebook-open time, and the symlinks render as read-only via the existing `isSymlink` check in `JupyterLiteContentsRoutes`).  But the shared dir was only re-extracted by the bigger `/edit/save` flow, not by the single-file `POST /scripts` path used by the new support-file UI.  After this fix, `POST /scripts` (with `tier=support`) and `DELETE /scripts/:filename` both call `extractSupportFilesToSharedDirectory` so the shared dir stays in sync with every upload/delete.  Students opening the assignment notebook in JupyterLite now see the support files alongside `assignment.ipynb`, can `pd.read_csv("assignment4_vitaldb_cases.csv")` directly in-browser, and the symlinks are read-only so they can't accidentally overwrite shared data.

## [0.4.115] - 2026-04-26

### Fixed

- **Notebook check save returned 403 "No CSRF token provided".**  The Vapor CSRF library does case-sensitive intersection against lowercase keys (`x-csrf-token`); v0.4.114's editor JS sent `X-CSRF-Token` (capitalized).  Every other JS module in the codebase already used lowercase — this was a v0.4.114 regression isolated to the new check editor and the new support-file upload/delete handlers.  Fixed in `Public/notebook-check-editor.js` and the inline support-file JS in `assignment-edit.leaf`.

### Changed

- **NotebookCheck modal no longer edits tier or points.**  Per the same interaction model as scripts and pattern families, tier and points are edited inline on the test-suite row.  New checks default to `public` / 1 point; existing checks preserve their tier/points across modal saves so inline edits aren't clobbered.  Modal markup loses the tier/points inputs and gains a one-line hint.

## [0.4.114] - 2026-04-26

### Added

- **Phase B notebook checks (continued).**  Two new kinds extend the
  v0.4.113 set, neither requiring sidecar files:
  - `.figureCount` — asserts the student notebook produced at least
    `minFigures` matplotlib figures.  Reads `plt.get_fignums()` after
    `test_runtime.py`'s `load_student_module()` runs the student code,
    so every `plt.figure` / `plt.subplots` / `df.plot` contributes.
    No new runtime infrastructure.
  - `.cellContains` — asserts at least one code cell in the student's
    submission contains a substring (or regex).  Optional
    `mustDifferFrom` flags cells that match the pattern AND are
    identical to a reference string ("not the same as the example"
    exercises).  Reads cells from a preserved copy of the original
    notebook.
- **`SubmissionNormalizer` preserves the original `.ipynb`.**  When a
  student uploads a notebook, the workspace now gets both the
  flattened `.py` (used by `test_runtime.py`) **and** a copy of the
  original at `_submission.ipynb` so cell-source-level checks
  (`.cellContains` today, future markdown checks) have visibility into
  the cell-by-cell structure that flattening discards.  Pure addition
  — existing tests don't read it.
- **NotebookCheck editor modal.**  Instructor assignment editor grows
  a `+ Add Check` button per section, and a kind-aware modal with
  field cards for all seven NotebookCheck kinds (`.dataFrameShape`,
  `.dataFrameColumns`, `.dataFrameEquality`, `.seriesEquality`,
  `.numericArrayClose`, `.figureCount`, `.cellContains`).  Saves via
  the existing `PUT /instructor/:id/checks` endpoint.  Module lives at
  `Public/notebook-check-editor.js`.
- **Support files moved to the top file table.**  Files in the test
  setup zip with `tier == "support"` (data fixtures, CSVs, JSON
  helpers) now render in the same top-of-page table as the assignment
  and solution notebooks instead of in the test suite below.  New
  `+ Upload file` button writes through the existing `POST /scripts`
  endpoint with `tier=support`; per-row `Remove` button uses the
  existing `DELETE /scripts/:filename` endpoint.  Distinguishes
  pedagogically meaningful tests from instructor-bundled data without
  needing a new manifest field — the categorization was already in
  the data, just rendered together.

## [0.4.113] - 2026-04-26

### Added

- **Notebook checks — Phase A backend.**  New spec type sibling to `PatternFamily`: each check expands at save time into one generated `.py` test script (and optionally a sidecar `_expected_<id>.csv` for DataFrame/Series equality kinds), referenced from `TestSuiteEntry.generatedByCheck`.  Five kinds ship in this drop, all asserting on `student_module.<variable>` after the existing `test_runtime.py` infrastructure loads the student submission:
  - `.dataFrameShape` — `df.shape == (rows, cols)`.
  - `.dataFrameColumns` — column list matches expected; `.exact` (order matters) or `.superset` (instructor-required columns must be present, extras allowed).
  - `.dataFrameEquality` — `pandas.testing.assert_frame_equal` with sidecar CSV expected; toggles for `checkDtype` / `checkLike` / `rtol` / `atol` / `ignoreIndex` (defaults: strict dtype, order matters, pandas-default tolerances, ignore index).
  - `.seriesEquality` — `pandas.testing.assert_series_equal` with single-column sidecar CSV.
  - `.numericArrayClose` — `numpy.testing.assert_allclose`; expected encoded inline as `[Double]` in the manifest (no sidecar).
- **GET / PUT `/instructor/:assignmentID/checks` endpoints** mirroring the families routes.  Atomic replace; the shared `applyPatternFamilies` save path now also accepts `nextChecks: [NotebookCheck]?` and writes families + checks + sidecars in one zip-mutation pass.
- **`TestSuiteEntry.generatedByCheck: String?` and `TestProperties.notebookChecks: [NotebookCheck]`** — both stripped from the runner-facing manifest by `runnerSanitized()` so older runners never decode new `NotebookCheckKind` raw values.

### Fixed

- **`ZipArchiverTests` EFAULT flake under parallel test execution.**  Foundation's `Process` race surfaced as `NSPOSIXErrorDomain Code=14 "Bad address"` at ~5–8% on macOS when ZipArchiver's `Process` invocations stacked up against other suites' direct `Process` use.  Three-layer fix: `ZipArchiverTests` is now `@Suite(.serialized)` (matches existing `APIServerAppTests` / `DatabaseConfigurationTests`); `ZipArchiver.swift` holds a process-wide `zipProcessLock` across the whole zip subprocess lifecycle (Process / Pipe construction + setup + `run()`); and `Process.run()` now retries once on transient EFAULT to absorb cross-call races we can't lock against (other test suites that use `Process` directly).
- **Cross-suite env-var race between `APIServerAppTests` and `DatabaseConfigurationTests`.**  Both suites manipulate `setenv` / `unsetenv` for config-from-env tests, both were `.serialized` *within* their suite, but env vars are process-global so a test reading `SESSION_COOKIE_SECURE` could see another suite's mid-flight change.  Added a shared `EnvTestLock` (`NSLock`) acquired in each class's `init` / released in `deinit` — exactly one env-touching test in either suite holds it at a time.

## [0.4.112] - 2026-04-26

### Removed

- **Top-level Upload button hidden on the assignment edit page.**  Tests are authored in-house via the family/script editor or imported from Marmoset on the create page; the manual zip-upload path was rarely used and added clutter.  Same approach as v0.4.104's New Script / New Family hide — `hidden` attribute on the button, kept in DOM in case any latent listener expects it.

### Fixed

- **Auto-compute failures are now visible** instead of silently dropping back to an empty placeholder.  When Pyodide raises (TypeError because the input wasn't a dict, NameError because the function isn't defined in the solution, malformed `$varRef`, …), the Expected cell now shows `⚠ <error>` as its placeholder + a red outline.  Previously the user only saw "computing…" briefly disappear with no feedback — the actual error was buried in the cell's `title` tooltip.
- **Input cells and section/family variables accept Python repr** (single-quoted strings, `True`/`False`/`None`) when JSON parsing fails.  Pasting `{'address': {'city': 'Waterloo'}, 'name': {'family': 'Nguyen', 'given': 'Ava'}}` (a Python dict literal) now Just Works.  Conservative — only kicks in when the input doesn't already contain double quotes (so genuinely-mixed strings still fail loudly), and only swaps `'` → `"` plus `True`/`False`/`None` → `true`/`false`/`null`.

## [0.4.111] - 2026-04-25

### Fixed

- **Function-dropdown filter switched from "tests in this section" to "functions defined under this section's `##` header in the solution notebook"** — works on brand-new sections that don't have any tests yet.  v0.4.108–110 looked at the manifest's testSuites entries to figure out which functions "belonged" to a section, which broke when:
  - the section had only one promoted family (the user got stuck with just that one option, since other functions had no test entries to match against) — the v0.4.110 widening still required at least one matching test per function;
  - the section had no tests at all — nothing to match.
  Switched the scan endpoint to `scanNotebookForSectionsAndFunctions` so each function carries the `##` header it was defined under.  The editor filters by matching that header to the family's section name (read from the section block's `<strong>`).  Falls back to "show all" when the section name doesn't match any header (e.g. the instructor renamed it).

## [0.4.110] - 2026-04-25

### Fixed

- **Function-dropdown filter no longer over-restricts** in sections whose tests don't follow the `publictest_exists_<X>.py` naming convention.  v0.4.108 looked for that exact pattern (or displayName "X is defined and callable"), so a Challenge section with `publictest_countPatients.py`, `publictest_countAdults.py`, … only matched whichever scripts already had a family attached — leaving the user unable to add families for the others.  Now widens detection to a token-tokenize-and-cross-check approach: split each script filename on non-word boundaries and accept any token that exactly matches a name in the solution-notebook scan.  Also adds the `<X> exists` displayName form (the auto-scaffold's actual format — v0.4.108 had it wrong).

## [0.4.109] - 2026-04-25

### Changed

- **Locked section-variable rows in the family Variables table are quieter.**  Drop the leading 🔒 icon and the trailing "from section" label — the section name in the table title (`Variables — section: Challenge`) is enough context.  Read-only `<code>` styling + the shadowed-by-family note (when applicable) stay.

## [0.4.108] - 2026-04-25

### Fixed

- **Saving a new family that references a `$sectionVar` no longer rejects with "references unknown variable".**  `validatePatternFamilies` was strict: it required the family's home section be known up-front, but a brand-new family being created via `PUT /families` doesn't have an authored sectionID yet (the per-section toolbar stamps that on the follow-up `PUT /suite`).  When the family had no known section, the validator now treats every declared section variable as in-scope; the strict per-section check still runs once the family is placed (the suite-save path passes `authoredItems` with the actual `sectionID`, so a family in section X using `$varInSectionY` correctly fails at suite-save time).

### Changed

- **Section-level shared inputs now render INSIDE the family's Variables table** instead of in a separate "Shared inputs from section: X" block above it.  Locked rows show at the top with a 🔒 indicator and a "from section" label in the Remove column; rows shadowed by a same-named family variable get a strike-through and an inline amber note.  Section name appears next to the table title (`Variables (shared across all cases) — section: Challenge`).
- **Function dropdown in the family modal is filtered to functions used by tests in the family's section** — opens "+ Add Family" in Warm Up and you only see `mailingLabel`, `bmi`, `age`, not every function in the solution notebook.  Detection: family `functionName`s + raw scripts whose filename matches `*_exists_<X>.py` or whose displayName starts with `<X> is defined and callable` (the auto-scan scaffold's convention).  Currently-selected function is preserved across the filter so editing an existing family in a section that "owns" a different function still works.  Falls back to the full list when the section has no detected function names.

### Fixed

- **Top-level "New Script" / "New Family" buttons now actually hidden.**  v0.4.104 added the `hidden` attribute on those buttons, but the author-level `.btn { display: inline-block }` rule beat the user-agent `[hidden] { display: none }`, so they kept rendering.  Pinned the attribute globally with `[hidden] { display: none !important }` in `styles.css` so future uses Just Work without per-element style hacks.

### Changed

- **Section header buttons standardised on "Add" verb.**  `+ New Script` / `+ New Family` → `+ Add Script` / `+ Add Family`, matching `+ Add Input` already in the same row.  Consistent verb across the three peer actions.

## [0.4.106] - 2026-04-25

### Fixed

- **New-family modal: section-wide shared inputs now visible + usable for auto-compute.**  Clicking `+ New Family` from a section's toolbar (Warm Up, Challenge, …) now reads that section's declared inputs into the read-only "Shared inputs from section: X" block — previously the new-family branch unconditionally cleared `currentSectionVariables`, so the block stayed empty and `$OnePatient`-style refs in arg cells silently bailed out of the Pyodide auto-compute path (line 1426: `if (!(varMatch[1] in varsNow)) return;`).  The fix reuses the per-section `__chickadeeTargetSection` flag the toolbar already stashes — no new wiring on the leaf side, just a sibling lookup function (`readSectionContextBySectionID`) that walks straight to the section block by id instead of working backwards from a not-yet-rendered family row.

## [0.4.105] - 2026-04-24

### Fixed

- **Submission view: pattern-family case bled into the next section** when two families across different sections happened to use the same case label (e.g. both `bmi` (Warm Up) and `age` (Warm Up II) had a "Test 1" case).  `groupOutcomesBySection` was keyed by displayName, and the second entry silently overwrote the first, sending bmi's "Test 1" outcome under Warm Up II's heading.  Switched to parallel-index correlation: the helper now takes a `sectionIDPerOutcome: [String?]` array that matches `outcomes` 1:1 (built by zipping the tier-filtered manifest entries against the visible outcomes — both lists are walked in the same order by the worker).  Regression test added.

### Changed

- **Pattern-family pass message no longer echoes the full input dict.**  Previously: `mailingLabel({huge HL7 record}) returned 'NGUYEN, AVA\\n...'`.  Now: `Returned 'NGUYEN, AVA\\n...'`.  The row's case label already names the test, and the failure path still emits the full input alongside expected/got, so we only lose redundant context.  Applies to `.boundaryEquality` and `.approximateEquality` kinds.
- **Pattern-family failure message includes the source line for the failing assertion.**  A bare `assert x == y` (no message) used to render as `error: AssertionError:` with no context.  We now walk the traceback's last frame and append a `source:` row (`source:   assert name == record["name"]["given"]`), so students see exactly which assertion failed even when the assertion text is empty.
- **Allow 0-mark tests on the assignment edit page.**  Useful for "function exists" guards that purely short-circuit downstream tests without contributing to the grade.  Server clamping moved from `max(1, …)` to `max(0, …)` (in `AssignmentRoutes+Editor.createScript` and `AssignmentRoutes+Draft.createScript`); client-side `Math.max(1, …)` and `<input min="1">` similarly relaxed.

### Removed

- **Dependency badge ("↳ test_detect_marker.py") on the suite editor table.**  The parent/child indent + connector already conveys the dependency relationship visually; the trailing filename text added clutter without information.  `depBadgeHTML` is now a no-op (kept so callers don't need to change).

## [0.4.104] - 2026-04-24

### Changed

- **Top-level "New Script" and "New Family" buttons hidden on the assignment edit page.**  Redundant — every section (including Ungrouped) has its own inline `+ New Script` / `+ New Family` buttons since v0.4.102.  The buttons are kept in the DOM (with the `hidden` attribute) so the per-section delegate's `btn.click()` still routes to their handlers.  `+ Section` and global `Upload` remain visible.  Create-assignment page is unchanged (it has no sections yet).

## [0.4.103] - 2026-04-24

### Changed

- **Section header now hosts the per-section action buttons inline.**  `+ Add Input`, `+ New Script`, and `+ New Family` were each on their own row above their respective tables — now they sit on the right side of the section header, beside the section name and edit pencil.  Eliminates two empty-margin rows per section.  Ungrouped block (which has no header) keeps its slim toolbar above its tests table.
- **Trash icon for section-input Remove buttons** (matching `admin-user` / `admin-course` delete buttons).  Same 13×13 `action-danger` icon button used elsewhere; click handler walks `closest('.section-var-remove')` so clicks on the SVG bubble correctly.
- **Read-only section-vars block in the family modal is more visible.**  Previously hidden entirely when the section had zero declared variables, which made it look like the feature wasn't wired.  Now shows the section name + a "No shared inputs declared in this section" placeholder whenever the family lives inside a named section, so the instructor sees the wiring is alive even before they declare their first input.

### Removed

- **Per-section Upload button.**  Redundant with the global Upload button at the top of the page; instructors rarely upload script zips in the per-section context.  Global Upload still works.

## [0.4.102] - 2026-04-24

### Added

- **Per-section create buttons.**  Each section block (including the trailing Ungrouped block) now renders its own inline `+ New Script` / `+ New Family` / `Upload` toolbar above its Tests table.  Items created via these buttons auto-land in that section — the per-section button stashes its `sectionID` on `window.__chickadeeTargetSection` and the suite-table's `addExistingScript` / `syncFamilies` read that flag to stamp the new item.  Global toolbar buttons still work for "I don't care which section" creates.
- **Read-only section variables in the family edit modal.**  When the instructor opens a family that lives in a section with declared variables, the modal shows a compact read-only "Shared inputs from section: X" block above the family's own Variables table.  Lists each `$name` + a truncated preview of the value, and flags rows that a family variable would shadow.  Not editable here — edit in the section's Inputs table — so changing a shared value doesn't accidentally ripple through all the other tests in the section.

### Changed

- **Version badge moved from the global nav to the top of the admin page.**  Previously visible next to the Admin link on every page for admin users; now only appears on `/admin` itself.  Less visual noise for admins on instructor / student flows.

## [0.4.101] - 2026-04-24

### Fixed

- **Pattern family auto-compute now fills Expected on every case row that references a variable.**  The scheduler used a single-slot `_autoComputeRow`, so when the `rescheduleAutoComputeForVariableRefCases` loop queued up N rows that all reference `$patients`, only the LAST row survived the 400ms debounce — every other row sat with an empty Expected.  Replaced the single slot with a `Set<row>` that accumulates pending rows for the next tick; one shared timer processes them all.  Also covers the case where the instructor types `$var` in row 1, finishes, then types `$var` in row 2 while row 1's Expected is still computing.

### Changed

- **Section "Shared Inputs" is now a fixed table, not a collapsible expander.**  Each named section renders an Inputs table directly above its Tests table.  Removed the `<details>`/`<summary>` wrapper, the "Declare once; reference from any pattern family…" hint line, the explicit **Save inputs** button, and the old thead.  First-column placeholder reads **Input Name** so the purpose is obvious at a glance.  `+ Add input` sits above the table instead of beside the removed Save button.
- **Inputs auto-save — no explicit Save button.**  Debounced POST fires 500ms after the last edit; also flushes via the **Save & Validate** button so any in-progress typing persists alongside the assignment save.  Invalid rows (bad identifier / unparseable value / duplicate name) skip the auto-save silently — the row's red outline already signals the problem, and the next valid edit retries.

## [0.4.100] - 2026-04-24

### Added

- **Section-level variables.**  Each test-suite Section can now declare shared variables (same syntax as family-scoped `$name` variables added in v0.4.94).  Variables live on the Section, are rendered as module-level Python assignments at the top of every generated test in that section, and are referenceable from any pattern family in the section via `$name`.  Family-level variables with the same name shadow section-level ones — standard Python "last assignment wins".  New endpoint `POST /instructor/:id/suite-sections/:sid/variables`; new inline "Shared inputs" expander in each section's header; family editor modal looks up the family's home-section variables from the DOM when opening, so auto-compute resolves `$patients`-style refs to real values and the Expected cell fills in automatically.  Unlocks the Assignment 3 Challenge pattern: declare `patients` once, reference it from five families (one per function) that all run against the same test data.
- **Auto-scan create flow.**  When the instructor uploads a solution notebook on the Create page, the server now scans it for `## ` markdown headers and top-level function definitions, then scaffolds the test setup in one shot: one `TestSuiteSection` per header (in notebook order), one `publictest_exists_<fn>.py` per detected function (placed in the section whose `##` header most recently preceded the `def`).  One-shot — silently skips on a re-upload of the solution notebook if the manifest already has sections or tests.  Functions appearing before any `##` header land in the trailing Ungrouped block.  The manual "Scan for functions" button in the family editor still exists for ad-hoc scans after upload.  New scanner: `scanNotebookForSectionsAndFunctions` in Core; new helper `autoScaffoldFromSolutionNotebook` in AssignmentHelpers.

### Changed

- **Pattern family Variable-row UI tightened.**  Replaced the two verbose status lines beneath each row ("✓ referenced as $name", "✓ parsed as dict — {…}") with a single green `✓` in a leading indicator column when both name and value are valid.  Invalid inputs get a red outline + tooltip.  Much quieter by default.
- **Auto-computed multi-line expecteds round-trip correctly.**  The Expected cell is a single-line `<input type="text">`, which silently strips newlines on `.value` assignment.  `renderTypedCellValue` now JSON-stringifies any string containing `\n`, `\r`, or `\t` so the escape sequences survive as literal text in the cell; reading back via `coerceByType` JSON-parses the quoted form, reconstructing the real string.  Unlocks the `mailingLabel` case from Assignment 3 where the solution returns `"NGUYEN, AVA\n12 KING ST W, WATERLOO, ON\nN2L3X2"`.

## [0.4.99] - 2026-04-24

### Fixed

- **`+ Section` / `+ Add Section` popup is no longer transparent.**  Both the suite-editor and instructor-dashboard popups declared `class="add-section-popup card"` but `.card` wasn't defined anywhere in the stylesheet — the popup inherited whatever was behind it, which on dark-mode admin pages made the Section-name input nearly invisible.  Added a `.card` rule (solid `var(--surface)` background + border + rounded corners) and an `.add-section-popup` rule that layers on the popup-specific shadow.  Dark-mode-aware via the existing palette variables.

### Changed

- **Version badge moved to the top nav (admin-only).**  Previously you had to scroll to the bottom of the admin dashboard to see the running Chickadee version; now a small monospaced `v0.4.99` pill sits next to the "Admin" link on every page.  Visible only when the current user is an admin.  Dropped the redundant `Chickadee v…` line at the foot of `admin.leaf`.

## [0.4.98] - 2026-04-24

### Changed

- **Test-suite sections refactored to mirror the instructor-dashboard pattern.**  v0.4.96 ran section CRUD through the whole-state `PUT /suite` endpoint, which means adding a section name had to ride the full `applyPatternFamilies` pipeline (validation → zip rebuild → family expansion → topological sort).  Any hiccup anywhere in that pipeline flipped the PUT to 4xx, the client's `.catch` reloaded the page, and the user's edit evaporated — exactly what users reported when "+ Section" caused the page to refresh before they could type a name.  Rebuilt around the proven per-operation pattern the dashboard's `AssignmentRoutes+Sections.swift` has used for weeks:
  - New endpoints: `POST /instructor/:assignmentID/suite-sections{/create, /:sid/rename, /:sid/delete, /reorder}`.  Form-encoded bodies; 303 redirect back to `/edit` for write ops; JSON + 200 for the AJAX reorder.  Each handler mutates ONLY `manifest.sections` (and clears orphan `sectionID` on delete) — they do NOT call `applyPatternFamilies`, do NOT rebuild the zip, and do NOT kick validation or auto-retest.
  - `assignment-edit.leaf` now server-renders the section shells (one `.section-block` per `manifest.sections` entry, plus a trailing Ungrouped block).  `+ Section` is a `<details>` popup with a classic `<form>` POST.  Section rename is the dashboard's inline `.section-view` / `.section-edit` toggle.  Section delete uses a JS `confirm()` + dynamically-built form POST.  Section drag-reorder is an AJAX POST to the reorder endpoint — no page reload.
  - `suite-table.js` stripped: no more `sections[]` state, no more `renderTree` of section headers, no more `+ Section` JS button.  The module now owns only row-level behaviour (render rows into existing `<tbody data-section-id>`, within/cross-section drag, tier/points/displayName edits, debounced `PUT /suite` for item changes).
  - `PUT /suite` no longer mutates `sections` — the body's `sections` field is accepted-and-ignored for client back-compat.  The manifest's existing sections are the source of truth.
  - `captureLiveEdit` / `applyLiveEdit` guard extended from v0.4.97 stays: protects `suite-display-name` edits on script rows from being wiped by the debounced PUT echo.
- **Typing into a newly-created section name no longer gets clobbered.**  Falls out of the refactor: section names persist through the `/suite-sections` create+rename endpoints that redirect to a full page reload, not the debounced PUT whose response wiped mid-typing text in v0.4.96/v0.4.97.
- **Family Edit/Delete buttons (v0.4.97 patch held): pattern-family-editor.js accepts either `#suite-config-body` (pre-v0.4.96) or `#suite-sections` (v0.4.96+) as its click-delegate root.

### Fixed

- **`putSuite` rebuilt pattern families without `variables`.**  When the client sent back a family with non-empty `dependsOn` (e.g. after a drag-adopt), the handler reconstructed the `PatternFamily` via its memberwise init but forgot to pass `variables`, silently dropping all family-scoped variables (added in v0.4.94) on every save.  Cases whose `argVarRefs` referenced those variables then failed `validatePatternFamilies` on the next save, 422'd the PUT, and the client's `.catch` reloaded the page.  Init now passes `variables: f.variables`.
- **`doPush` no longer reloads the page on save failure.**  A failed PUT now surfaces an `alert()` with the server's reason and keeps the user's unsaved edits in the DOM, so the instructor can see what went wrong and recover.  Reload hid the failure and wiped in-progress work; the new path matches the dashboard's behaviour for errors.

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
