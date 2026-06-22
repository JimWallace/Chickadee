# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project follows Semantic Versioning.

## [Unreleased]

## [0.4.505] - 2026-06-22

### Added

- **Self-service "reset the notebook editor" page (`/reset-editor`).** When the
  in-browser editor wedges and the Python kernel spins forever — usually stale
  persisted browser state (a corrupted IndexedDB-backed JupyterLite Drive, a
  stale service worker, or cached assets) that a plain reload can't shift — a
  stuck student (or a TA) can hit `/reset-editor` for a one-click fix. The
  confirmation POST returns `Clear-Site-Data: "cache", "storage"`, the
  server-side equivalent of "Clear site data" scoped to Chickadee: it drops
  cache storage, IndexedDB, and service-worker registrations so the next load
  boots the kernel from a clean slate. It deliberately omits `"cookies"`, so the
  student stays logged in. Two-step and CSRF-protected so a cross-origin page
  can't silently wipe in-progress work; the `next` return path is sanitized to a
  same-origin path. The notebook fallback panel links to it (pre-filled with the
  current assignment) when the editor fails to load.


## [0.4.504] - 2026-06-22

### Fixed

- **In-browser editor: boot the Pyodide kernel on engines without native
  `Atomics.waitAsync` (older Safari / iPadOS), with cross-origin isolation
  intact.** The kernel polyfills `Atomics.waitAsync` with a `data:` worker, which
  our CSP (`worker-src 'self' blob:`) and COEP `require-corp` both block on the
  isolated editor — hanging the kernel ("Kernel Unknown"-class). The polyfill
  worker is now vended as a `blob:` URL
  (`scripts/patch-pyodide-waitasync-worker.py`, run from the JupyterLite build and
  asserted by `verify-jupyterlite.sh`), which both CSP and COEP allow, so those
  engines boot the kernel on `SharedArrayBuffer` with **no fallback needed**. A
  new `SMOKE_SIMULATE_NO_WAITASYNC` editor-smoke config (CI, Chromium + WebKit)
  deletes native `waitAsync` and asserts the editor still boots isolated, so it
  can't regress unseen. This supersedes — and removes — the short-lived
  `ck-editor-compat` cookie fallback that dropped cross-origin isolation to use
  the service-worker path (`EditorCompatMode`, the COEP/asset-isolation cookie
  bypasses, and the `notebook.js` compat switch); the stale-service-worker
  cleanup and the `sw_state` `coi`/`waitasync` telemetry remain.


## [0.4.503] - 2026-06-22

### Changed

- **Per-course instructor authority (multi-course-roles Phase 4b).** A person
  can now be an instructor in one course and a student in another: the
  `/instructor` section admits a per-course instructor (gated on the caller's
  role *in their active course*), not just a global one, and an instructor or
  admin sets a roster member's per-course role from a dropdown on the Students
  page. The param-taking enrollment endpoints (unenroll, set enrollment mode,
  bulk-enroll, cancel pre-enrollment, set role) check per-course instructor
  access on the course named in the URL, so a per-course instructor can't be
  driven against another course. Existing **global** instructors keep their
  access unchanged — the global-instructor fallback is removed when the global
  role is shrunk in a later phase. See `docs/multi-course-roles.md`.


## [0.4.502] - 2026-06-22

### Fixed

- **Notebook editor: stop the new kernel-boot watchdog from false-alarming on
  healthy kernels.** The v0.4.500 `kernel-boot-timeout` beacon fired on mere
  *absence* of a positive kernel-ready signal, but the parent page often cannot
  read the kernel's state inside the cross-process editor iframe — so it
  false-positived on healthy Chrome **and** Safari kernels (a spurious "kernel
  taking unusually long" message plus phantom kernel errors on the dashboard).
  The watchdog deadline now stops watching silently instead of beaconing;
  genuine no-`SharedArrayBuffer` hangs are still pre-empted up front by the
  cross-origin-isolation compat switch. The `sw_state` beacon now also reports
  `waitasync`, so the at-risk `coi=true; waitasync=false` cohort is visible
  without any iframe probing.


## [0.4.501] - 2026-06-22

### Changed

- **Notebook editor reclaims vertical space.** The student/instructor notebook
  page now hands more of the viewport to the editor itself — valuable on laptops
  and iPads. The Submit/Download header lost its 2rem top margin and slimmed its
  bottom gap, the embedded JupyterLite editor grew to match (the outer page no
  longer scrolls), and the redundant Notebook 7 header strip (jupyter/kernel
  logos, the filename + "Last Checkpoint" line, and the "Not Trusted" indicator)
  is now hidden inside the iframe. The notebook toolbar (Save/Run/kernel status)
  is unchanged.


## [0.4.500] - 2026-06-22

### Fixed

- **Notebook editor: restore a kernel-boot fallback and stop hung kernels from
  hiding.** After the SAB-only switch (cross-origin isolation, service worker
  removed) some students hit a Pyodide kernel that never finished loading. Two
  causes: (1) a stale, now-redundant JupyterLite service worker left registered
  by a pre-SAB build kept controlling `/jupyterlite/*` and broke the boot — it is
  now proactively unregistered on load; (2) engines that lack native
  `Atomics.waitAsync` (older Safari / iPadOS) hit the kernel's `data:`-worker
  polyfill, which COEP `require-corp` blocks, hanging the kernel with no
  fallback. notebook.js now detects that exact case (`crossOriginIsolated &&
  !Atomics.waitAsync`), opts the client out of isolation via the
  `ck-editor-compat` cookie (the isolation middlewares drop COEP for that
  client only), and re-registers the JupyterLite service worker so the kernel
  uses the SW sync path — the cross-origin-isolated majority is unchanged.

### Added

- **Kernel-liveness telemetry so a hung kernel is visible.** The editor now
  beacons `kernel_ready` when the Pyodide kernel actually reaches idle/busy (not
  just the shell mounting, which `editor_ready` already counted), and a
  `watchdog_timeout` / `kernel-boot-timeout` diagnostic when it never does —
  tagged with `coi` / `waitasync` / `compat` so the admin browser-diagnostics
  surface shows which kernels are hanging and why, instead of recording a hung
  kernel as a successful load.


## [0.4.499] - 2026-06-22

### Fixed

- **Nightly clean-build coverage canary restored.** `test-coverage.yml` runs
  every target in one process but never installed `python3`, so the
  python3-dependent APITests (generated pattern-family syntax checks,
  seed-expression validation grading) trapped — a broken-pipe write to a
  never-spawned interpreter, and a test `Application` leaked past a python3-skip
  guard tripping Vapor's `ServeCommand did not shutdown before deinit`
  assertion — each SIGILLing the whole run. The container now installs `python3`
  (matching `swift-tests.yml`); the skip guard in
  `WorkerRoutesTests.materializeValidation_resolvesExpressionForSeed` moved
  inside `withApp` so a skip can't leak the app; and `pfAssertValidPythonSyntax`
  skips cleanly and uses a throwing write so a missing/failed interpreter
  degrades to a skip instead of a process-killing trap.


## [0.4.498] - 2026-06-22

### Changed

- **LEARN (BrightSpace) tab cleanup for the service-account model.** The
  instructor **LEARN** tab drops the per-instructor "Your LEARN account"
  connect/disconnect UI and the "Org-unit link" section (the override handlers
  stay in code, just unused) and opens straight at the grade-sync dashboard. The
  **Export Grades CSV** button moves to the top-right of the tab. A new
  **"Auto-map by name"** button maps every unmapped assignment to the D2L grade
  item whose name matches in one click (fills empty mappings only; safe to
  re-run). The admin **BrightSpace** tab is renamed **LEARN** and drops the
  in-app authorize / redirect-callback flow (UW uses a central credential
  service — the "Set credentials manually" path remains).


## [0.4.497] - 2026-06-22

### Added

- **Per-course role seeding for new enrollments (multi-course-roles Phase 4a).**
  Every enrollment-creation path now seeds the new enrollment's per-course role
  from the user's current global role (a global instructor/admin becomes a
  per-course instructor, everyone else a student) via a single
  `saveSeededEnrollment` helper. **No observable behavior change** — the
  per-course role still mirrors the global role; this keeps it accurate for new
  enrollments so a later phase can move authorization onto the per-course role
  without dropping anyone's access. See `docs/multi-course-roles.md`.


## [0.4.496] - 2026-06-22

### Added

- **Per-course role authorization chokepoint (multi-course-roles Phase 3).**
  `CourseRole` is now ordered (`Comparable`), and `CourseAccessHelpers` gains
  `requireCourseRole(caller:courseID:atLeast:db:)` — the role-aware
  generalization of the existing enrollment check, which becomes its `.student`
  case. Authorization is purely per-course (admin bypass only). **No observable
  behavior change:** production callers use the `.student` bar, and every
  enrolled user is at least a student. See `docs/multi-course-roles.md`.


## [0.4.495] - 2026-06-22

### Added

- **Per-course role groundwork (multi-course-roles Phases 1–2).** Each course
  enrollment now carries a `role` (`student` / `instructor`) — the foundation
  for a user being an instructor in one course and a student in another. A
  migration adds the column and backfills it behaviour-preservingly from each
  user's current global role (Phase 1), and the home/nav read path now derives
  the "Instructor" tab from the *active course's* role rather than the global
  one (Phase 2). **No observable behavior change yet:** every enrollment's role
  mirrors the global role until per-course roles become authorable in a later
  phase. See `docs/multi-course-roles.md`.


## [0.4.494] - 2026-06-22

### Fixed

- **Release-tier results now respect per-student extensions.** Release-test
  output is gated on the student's *effective* deadline — the later of the
  assignment due date and their own extension — instead of the bare
  assignment-wide due date. A student with an active extension no longer has
  the hidden release tests revealed while their extended submission window is
  still open; the reveal is only postponed to their own deadline, not
  suppressed. Both the JSON results API
  (`GET /api/v1/submissions/:id/results`) and the web submission page route
  their tier-visibility decision through `effectiveDueAt(for:user:)`.


## [0.4.493] - 2026-06-21

### Changed

- **SwiftLint bumped 0.63.3 → 0.64.0** (`SwiftLintPlugins`). The codebase
  stays at zero violations under the new version's `--strict` gate; no rule
  baselines were touched. Every other Swift dependency (direct and transitive)
  was already pinned to its latest release.


## [0.4.492] - 2026-06-21

### Fixed

- **api-tests flakiness: migrated the HTTP-test surface off XCTVapor to Vapor's
  Swift-Testing-native `VaporTesting`.** The `APITests` target drove requests
  through XCTVapor (`app.testable().test(...)`), which reports a thrown
  request/decoding error via `XCTFail`. Called from a Swift Testing `@Test`,
  `XCTFail` is mis-attributed and intermittently dropped — surfacing as
  unattributed "issues" and the "test failures not being reported" CI warning.
  All 102 `APITests` files now `import VaporTesting` and use `app.testing()`,
  so request-execution failures are recorded with `Issue.record(sourceLocation:)`
  and attributed to the right test. The central `Application.asyncTest` /
  `asyncSendRequest` helpers thread the new `fileID`/`filePath`/`line`/`column`
  source location through. Incidental XCTest assertions in the migrated files
  (`XCTFail`, `XCTAssert{Greater,Less}Than*`, `XCTSkip`) were converted to
  `Issue.record` / `#expect` / `IssueRecorded`. `scripts/no-new-xctest.sh` now
  also blocks `import XCTVapor` so the flaky bridge can't return. No production
  code changed.


## [0.4.491] - 2026-06-21

### Changed

- **Disabled the now-redundant JupyterLite service worker — the editor runs on
  SharedArrayBuffer alone, no fallback.** With cross-origin isolation
  unconditional, the kernel syncs stdin/Drive over `SharedArrayBuffer`, so the
  service worker (`@jupyterlite/application-extension:service-worker-manager`) is
  no longer needed and is now in `disabledExtensions` (source + served config).
  This is the deterministic end state: one sync path, no fallback — which also
  removes the SW-control "Kernel Unknown" race entirely (no SW to race).
  `JupyterLiteConfigTests` now asserts the SW manager is disabled. Verified by
  the editor-smoke selftest (kernel + `input()` over SAB with no SW) and the
  authenticated notebook-page e2e (the real editor loads the notebook from the
  Drive and grades a real submission with no SW), both under **Chromium and
  WebKit**. Trade-off: without the SW asset cache the page's two Pyodide loads
  are heavier, so grading-to-result is somewhat slower (noticeably under WebKit)
  but still completes — the notebook-page e2e's submit budget was widened
  accordingly. Its redundant active worker-spawn probe (which started a second
  Pyodide and could perturb the real grading) was removed in favour of asserting
  no COEP-blocked resources plus a clean `1 / 1 passed`, making the e2e
  deterministic across engines.


## [0.4.490] - 2026-06-21

### Added

- **Full authenticated end-to-end browser test of the real student notebook
  page.** A new `notebook-page-check.mjs` (run under the Chromium + WebKit
  editor-smoke matrix) seeds a browser-graded assignment over the HTTP API
  (register instructor → create course → auto-enroll → upload a browser test
  setup → register + log in a student), then drives the actual
  `/testsetups/:id/notebook` page — the cross-origin-isolated parent that embeds
  the JupyterLite editor iframe *and* spawns the grading / freeze-failover Web
  Workers. It asserts the page is cross-origin isolated, the app workers spawn
  (the #986 regression, now guarded on the *real* page, not just
  `/jupyterlite/repl`), the editor loads the student notebook from the Drive,
  and a real Submit runs in-browser grading and renders a passing result. This
  closes the exact coverage gap that let the grading-worker COEP block ship:
  the standalone editor smoke never drove the real page or a real submission.
  `run-smoke.sh` is now parameterized by `SMOKE_CHECK`.


## [0.4.489] - 2026-06-21

### Changed

- **The editor-smoke CI workflow is now a requireable merge gate.** Previously it
  was advisory and path-filtered at the trigger, so it couldn't be marked required
  (a path-filtered check is *skipped* on unrelated PRs, and a required-but-skipped
  check blocks those merges). It now runs on every PR: a fail-safe `changes` job
  decides whether the editor / grading / cross-origin-isolation surface was touched,
  the expensive Chromium + WebKit `smoke` matrix runs only when it was, and an
  always-running **`editor-smoke-gate`** job reports a single status — green when the
  smoke passed or was skipped, red only when it actually failed (or when change
  detection itself failed, i.e. fail-closed). Enforcing it is now one repo setting:
  add `editor-smoke-gate` to `main`'s required status checks (see
  `docs/notebook-editor-smoke-test.md`). The change-detection set also gained
  `grading-worker.js` and `CrossOriginIsolationHeaders.swift`.


## [0.4.488] - 2026-06-21

### Fixed

- **Browser grading + the freeze failover are no longer blocked under the
  notebook editor's cross-origin isolation.** Making the editor unconditionally
  isolated meant the `/testsetups/:id/notebook` page is served `COEP: require-corp`
  — and a `require-corp` page cannot spawn a dedicated `Worker` whose script
  lacks COEP (Chrome `ERR_BLOCKED_BY_RESPONSE`). The app's own worker scripts
  (`/grading-worker.js`, `/freeze-watchdog-worker.js`) are served from the Public
  root, not the fast path that stamps COEP, so the global headers gave them CORP
  but never COEP — which would have silently broken in-browser grading and the
  main-thread freeze failover on deploy. `NotebookAssetIsolationMiddleware` now
  stamps the isolation trio on those two worker scripts as well.
  (`/pyodide-worker.js` is intentionally excluded — it is spawned only by the
  non-isolated assignment-editor pages.) Guarded going forward by a new
  worker-spawn probe in the editor-smoke harness — it spawns these workers from
  the isolated page under **both Chromium and WebKit** and fails if either is
  blocked — plus `COEPMiddlewareTests` coverage of the worker-script headers.


## [0.4.487] - 2026-06-21

### Changed

- **The notebook editor is now cross-origin isolated unconditionally — the
  `NOTEBOOK_CROSS_ORIGIN_ISOLATION` env var is removed.** The cross-origin
  isolation fix (which gives the Pyodide kernel `SharedArrayBuffer` and so
  eliminates the service-worker-control "Kernel Unknown" race) shipped behind a
  flag; it is now always on, so there is nothing to configure. The
  `AppSecurityConfiguration.notebookCrossOriginIsolation` field and the env read
  are gone; the isolation middlewares keep their `enabled`/`isolateNotebook`/
  `crossOriginIsolation` parameter purely as a unit-test seam, set `true` at the
  bootstrap call site. The headless editor-smoke selftest now proves the editor
  boots isolated, **stays healthy with the service worker disabled** (SAB carries
  stdin — the direct proof the SW-control race is gone), and still detects a
  genuine no-sync freeze. **Verify the editor on Safari before promoting a build
  to production** — the kernel's `Atomics.waitAsync` `data:`-worker polyfill is
  blocked under COEP, and Chromium (covered by the harness) has the API natively
  while Safari may not. Rollback is reverting the change (no flag). See
  `docs/notebook-editor-kernel-boot.md`.
- **Editor telemetry now reports cross-origin-isolation state.** The notebook
  page's `sw_state` beacon includes `coi=<crossOriginIsolated>;sab=<SharedArrayBuffer present>`
  so the admin browser-diagnostics breakdown can confirm — per browser/device
  class — that the SharedArrayBuffer path is live after a deploy, and correlate
  any "Kernel Unknown" failure with it (e.g. a browser reporting `coi=false`, or
  `kernel-unhealthy` with `coi=true`, is the one to investigate).
- **The editor smoke test now runs under WebKit (Safari) as well as Chromium.**
  The headless harness is parameterized by engine (`SMOKE_BROWSER`) and the CI
  `editor-smoke` workflow runs the selftest under a `chromium` + `webkit` matrix.
  WebKit is the engine behind every Safari-class editor bug we have shipped
  blind (spurious phase-1 timeouts; the `Atomics.waitAsync` `data:`-worker that
  COEP blocks); both engines now pass all three configs (isolated boot, SW
  disabled, no-sync freeze), so the Safari risk for cross-origin isolation is
  covered in CI rather than only in front of a student.


## [0.4.486] - 2026-06-20

### Fixed

- **Cross-origin isolation now works for the notebook editor — the deterministic
  fix for "Kernel Unknown".** Turning on `NOTEBOOK_CROSS_ORIGIN_ISOLATION` gives
  the Pyodide kernel `SharedArrayBuffer` for synchronous stdin/Drive, removing
  its dependence on the JupyterLite service worker and eliminating the
  service-worker-control race that caused the "Kernel Unknown" boot failures
  (the root cause behind the recovery-ladder mitigation). The flag had been
  unusable because, under COEP `require-corp`, the editor's Pyodide **kernel
  worker** is served by `EditorAssetFastPathMiddleware`, which short-circuits the
  chain *before* the isolation middleware ran — so the worker script went out
  with no `Cross-Origin-Embedder-Policy` header and Chrome blocked it
  (`ERR_BLOCKED_BY_RESPONSE`). The fast path is now isolation-aware: when the
  flag is on it stamps COOP/COEP/CORP on the vendored editor asset trees it
  serves (`/jupyterlite/build`, `/jupyterlite/extensions`, `/pyodide`,
  `/vendor`), via a shared `Response.setCrossOriginIsolationHeaders()` so the
  isolation middlewares can't drift. Proven end-to-end in the headless-browser
  smoke harness (`Tools/editor-smoke-test/selftest.sh`): the isolated config now
  boots the kernel with `crossOriginIsolated=true` and round-trips `input()` over
  `SharedArrayBuffer` with no service worker, while the freeze detector stays
  discriminating. The flag remains **default off** pending real-browser (esp.
  Safari) rollout — see `docs/notebook-editor-kernel-boot.md`.


## [0.4.485] - 2026-06-20

### Fixed

- **Hardened the in-browser editor's recovery from "Kernel Unknown" boots.**
  When the Pyodide kernel registers `dead`/`unknown` at startup — the
  service-worker control race (the SW the kernel needs for its sync path is
  *registered* but not yet *controlling the page* when the kernel mounts its
  Drive) — the watchdog previously did a single in-place iframe reload and
  then gave up, so failures showed up annotated "persisted after auto-reload":
  the reset just re-raced the same SW startup. Recovery is now a three-rung
  ladder, and each reload first waits (bounded) for the service worker to
  settle: reload the iframe → reload the whole tab (a full document load is the
  only thing that re-bootstraps the SW → client *control* relationship; guarded
  by a per-(tab, setup) `sessionStorage` flag so it happens at most once and
  can't loop) → only then surface the upload fallback and the unchanged
  `watchdog_timeout` / `kernel-unhealthy` diagnostic. Mitigation, not a cure
  (it still depends on the SW eventually controlling); the deterministic
  root-cause fix (cross-origin isolation + `SharedArrayBuffer`, and why it's
  still blocked) is written up in `docs/notebook-editor-kernel-boot.md`. Also
  corrects a stale `COEPMiddleware` comment that claimed the JupyterLite service
  worker was disabled — it was re-enabled in v0.4.467.


## [0.4.484] - 2026-06-20

### Added

- **Per-test time-limit overrides for pattern families and notebook checks (MCP).**
  A pattern family can now carry a family-wide `defaultTimeLimitSeconds` (applied
  to every generated case and the auto-existence guard) and each case its own
  `timeLimitSeconds`; a notebook check can carry a check-level `timeLimitSeconds`.
  The resolved value (case override wins over the family default; nil = inherit
  the assignment-wide default) is threaded onto the generated `TestSuiteEntry` so
  the worker and browser graders already honor it. Settable over the MCP content
  API via `create_pattern_family` / `update_pattern_family`
  (`defaultTimeLimitSeconds` + per-case `timeLimitSeconds`) and
  `author_notebook_check` (`timeLimitSeconds`); the range is 1–600 seconds and a
  `0` over MCP clears an override. `get_suite` surfaces the values on each
  family/check spec. The suite-editor UI for these stays deferred.


## [0.4.483] - 2026-06-20

### Added

- **Adjustable per-test execution time limit.** The per-test timeout is now
  editable two ways: an assignment-wide default (`TestProperties.timeLimitSeconds`,
  set over MCP with the new `set_time_limit` tool) and a per-test override on a
  hand-written script (`TestSuiteEntry.timeLimitSeconds`, settable via
  `author_script` / `update_suite` `timeLimitSeconds` and readable in
  `get_suite`). The effective limit for a script is
  `entry.timeLimitSeconds ?? manifest.timeLimitSeconds`, resolved in each
  executor (the worker's `NativeScriptExecutor` and the browser runner) rather
  than in the shared wasm `executeSuites` loop, which still receives the
  assignment default as the fallback. Both write paths validate the bound
  (1–600 seconds). Per-family / per-notebook-check / per-case overrides are
  deferred to a later change (TODOs mark the hook points); generated entries
  inherit the assignment default for now. `set_time_limit` is metadata-style
  (like `set_grading_mode`): it changes a grading-environment knob, not what the
  tests check, so it does not re-grade, re-validate, or close the assignment.


## [0.4.482] - 2026-06-20

### Changed

- **Docs:** added `docs/brightspace-per-instructor-status.md` — a status/decision
  record for the per-instructor BrightSpace rollout (what shipped, the LMS
  per-user app-authorization blocker hit during pilot prep, and the
  service-account-fallback unblock), plus a `brightspace-setup.md` troubleshooting
  entry for the "This application is not authorized on this LMS instance" error.


## [0.4.481] - 2026-06-20

### Added

- **BrightSpace sync-identity health on the LEARN tab.** The instructor LEARN
  tab now shows when you connected your LEARN account ("connected since …") and,
  when a course's designated grade-sync instructor has **disconnected**, flags it
  **"needs reconnect"** — making the deferred (grades-paused) state visible rather
  than silent. Another connected instructor can take the course over with "Use my
  account for this course". `docs/brightspace-setup.md` Step 4 updated for the
  instructor self-serve binding + the disconnected-identity behaviour.


## [0.4.480] - 2026-06-20

### Fixed

- **Browser grader survives CPU-bound infinite loops in student code.** The
  in-browser submission grader now runs student Python in a Web Worker
  (`Public/grading-worker.js`) instead of on the main thread, so a synchronous
  run-away loop (e.g. `while True: pass`) that never yields to JS can be killed
  via `Worker.terminate()` when the per-test time limit fires — previously the
  `Promise.race` sleep timer never got a turn, the tab froze, and the submission
  was lost. After a timeout a fresh worker is respawned to grade the remaining
  tests. Environments without `Worker` keep the unchanged main-thread path.


## [0.4.479] - 2026-06-20

### Added

- **Instructor self-serve BrightSpace org-unit binding.** Instructors can now
  link a course to its D2L org unit directly from the LEARN tab (previously
  admin-only on the course page). The org unit is verified with the instructor's
  own connected LEARN key — so a key that can't see the org unit fails loudly at
  bind time instead of at grade-push time — and binding makes the instructor the
  course's grade-sync identity (the "binder = default" rule). Requires a connected
  account; the admin course-page binding remains as an override.


## [0.4.478] - 2026-06-20

### Added

- **Per-instructor BrightSpace grade-sync identity.** Grade sync can now push as
  an individual instructor's connected LEARN account instead of a single
  deployment-wide service account — the model UW requires, since a service
  account can't be enrolled in courses but instructors already are. On the
  instructor **LEARN** tab, "Connect my LEARN account" verifies a pasted Valence
  User ID + User Key via `whoami` and stores it against that instructor; each
  course designates one connected instructor (`brightspace_sync_user_id`,
  default = whoever connects, reassignable via "Use my account for this course").
  The sweep, manual sync, grade-object listing, connection test, and classlist
  reconcile all resolve the course's designated identity (cached per identity in
  a new `BrightSpaceClientRegistry`), falling back to the deployment-wide
  (admin/env) identity when a course has none. A course whose designated
  instructor hasn't connected yet **defers** (rows stay pending) rather than
  clearing — so the grade pushes once they connect. The admin authorize / env
  path is retained as the fallback identity. New columns:
  `brightspace_credentials.user_id` (NULL = deployment-wide) and
  `courses.brightspace_sync_user_id`.


## [0.4.477] - 2026-06-19

### Changed

- **BrightSpace/Valence client hardened against UW's reference library.** The
  D2L request layer in `BrightSpaceAPIClient` now negotiates the API version per
  product (`GET /d2l/api/{lp,le}/versions/` → `LatestVersion`, cached; env pins
  `BRIGHTSPACE_LP_API_VERSION` / `BRIGHTSPACE_LE_API_VERSION` override) instead
  of hardcoding a version the LMS may not support — a too-high version 404s every
  call and masks the real cause. Fallback floors moved to UW-known-good values
  (`lp 1.47`, `le 1.75`). The classlist read now follows `/classlist/paged/`
  across all pages (both Valence paging conventions) so large courses aren't
  silently truncated. A `403 "Timestamp out of range"` now teaches the client its
  clock skew and retries once. Signing-path extraction no longer silently sends
  an unsigned request when `URL(string:)` declines to parse. Ported from UW IST's
  `learn_api` / `d2lvalence` reference client; pinned by `BrightSpaceTransportTests`.


## [0.4.476] - 2026-06-19

### Fixed

- **Unenrolled admins no longer see course content they're not part of.** An
  admin (or any user) with no course enrollment was shown the course-scoped
  "Instructor" nav tab and a deployment-wide list of every assignment/test
  setup on the home dashboard. The home dashboard is now course-scoped for
  every role — with no active enrollment it renders the empty "not enrolled in
  any courses" state, and the Instructor tab only appears for a user enrolled
  in a course (labelled with the active course code). The global admin role
  still grants the Admin tab and `/admin`; course participation is governed by
  enrollment, matching the existing `CourseAccessHelpers` policy.


## [0.4.475] - 2026-06-19

### Added

- **BrightSpace "Set credentials manually" (admin).** A new field on the Admin →
  BrightSpace page accepts a pasted Valence **User ID + User Key** — for
  institutions (like UW) that register a *central credential service* as the
  app's Trusted URL (`d2l-api-cred.fast.uwaterloo.ca`) rather than this server's
  own callback, so the in-app authorize handshake can't run. The pair is
  `whoami`-verified against D2L, stored (same `brightspace_credentials` row,
  taking precedence over env), and the live client is rebuilt — connecting grade
  sync with no env edit or restart. See `docs/brightspace-setup.md` Step 1C.


## [0.4.474] - 2026-06-19

### Fixed

- **BrightSpace "Authorize" button really works now (form-action on the right
  response).** The earlier fix relaxed `form-action` on the authorize POST
  response, but the browser enforces `form-action` using the CSP of the page
  that *contains* the form — so the relaxation has to be on the
  `GET /admin/brightspace` render, not the POST. Moved it there (matching the
  MCP consent-page pattern); the button no longer silently does nothing.


## [0.4.473] - 2026-06-19

### Fixed

- **BrightSpace authorize uses an exact Trusted-URL `x_target`.** D2L matches
  the registered Trusted URL strictly (a parent host does **not** cover a
  sub-path, and a query string breaks the match — `"x_target does not match the
  allowed values"`). The authorize handler no longer appends a `?state=` query
  to the callback, so its `x_target` is exactly the registered callback URL
  (`{PUBLIC_BASE_URL}/admin/brightspace/valence-callback`); CSRF is now bound to
  the admin session that initiated the authorize rather than an echoed token.


## [0.4.472] - 2026-06-19

### Fixed

- **BrightSpace "Authorize" button silently did nothing.** The admin authorize
  POST 303s to the LMS origin, but the global CSP `form-action 'self'` blocked
  that cross-origin redirect (Chrome/Firefox enforce form-action across the
  redirect chain). The handler now relaxes `form-action` to the LMS origin for
  that response, matching the SSO/MCP consent flows.
- **BrightSpace "Test connection" now shows the real error.** A failed `whoami`
  surfaced as Swift's generic `"The operation could not be completed.
  (… error N.)"` because `BrightSpaceSyncError` wasn't a `LocalizedError`. It now
  is, and `whoamiFailed` carries D2L's response body — so the admin/instructor
  panels report the actual HTTP status and message (e.g. a 403 "Timestamp out of
  range" vs. an egress-proxy denial). The CLI helper prints the same detail.


## [0.4.471] - 2026-06-19

### Fixed

- **Frozen in-browser grades now fall back to the worker backstop.** Browser
  grading runs Pyodide on the page's main thread, so a non-terminating (or
  blocking) student submission froze the tab: the in-browser per-test timeout
  couldn't fire on the blocked thread, grading never completed, and — because a
  browser submission row is only created when grading *finishes* — nothing was
  ever enqueued, so the v0.4.56 worker backstop had nothing to grade and the
  student was stuck on "Testing…" indefinitely. The freeze-watchdog worker (the
  one thread still alive while the main thread is frozen) now POSTs the stashed
  notebook to a new `POST /api/v1/submissions/browser-failover` endpoint after a
  grading stall, and the browser-runner does the same on a non-freeze hard
  failure. That enqueues a `pending` browser-mode submission the native backstop
  grades via `python3`, where a runaway loop is killed and reported as a clean
  `timeout` instead of a dead kernel. The failover is gated identically to a
  normal browser submission (enrollment + effective-open) and is idempotent per
  (student, assignment). A `submit_failover` diagnostic breadcrumb makes the
  fallback visible in the admin browser-diagnostics surface.


## [0.4.470] - 2026-06-19

### Added

- **In-app BrightSpace authorization (admin).** A new **Admin → BrightSpace**
  page performs the D2L Valence "App + User" handshake server-side: it redirects
  the admin to D2L, captures the user key on the `/admin/brightspace/valence-callback`
  redirect, verifies it with `whoami`, persists it (single-row
  `brightspace_credentials`), and rebuilds the live client so grade sync picks
  it up within one sweep — no env change or restart. A stored (authorized) key
  takes precedence over `BRIGHTSPACE_USER_KEY` in env; "Clear authorization"
  reverts to env (or disables sync). The deployment app creds
  (`BRIGHTSPACE_URL`/`_APP_ID`/`_APP_KEY`) stay env-only.
- **BrightSpace setup tooling.** `scripts/brightspace-valence-auth.py` performs
  the same handshake from the CLI (localhost or an approved `--callback` Trusted
  URL) for local/scripted setup, and `docs/brightspace-setup.md` documents the
  full credential → connection → org-unit → grade-item → roster → testing flow.

### Fixed

- **BrightSpace request signing.** The Valence per-request signature base string
  was `<timestamp>\n<METHOD>\n<path>`; the correct format (per Brightspace's
  `valence-sdk-python`) is `<METHOD>&<lowercase_path>&<timestamp>`. Every grade
  push / lookup would have failed authentication against a live D2L. Pinned by
  cross-language test vectors. (The bug was latent: grade sync had never run
  against a real server.)


## [0.4.469] - 2026-06-19

### Added

- **Pre-merge headless-browser smoke test for the notebook editor.** A new
  Playwright harness (`Tools/editor-smoke-test/`) boots the real
  `chickadee-server` and drives the JupyterLite editor in headless Chromium,
  asserting the Pyodide kernel actually comes up, runs a cell (`7*191` →
  `1337`) with no blocked-resource errors, and round-trips `input()` without
  hanging. This is the gate the recent editor breakages slipped through: `swift test`, the render tests, and the
  `BrowserRunnerJSTests` only prove code/templates *resolve* — none put a
  browser in front of the editor, so the COEP cross-origin-isolation attempt
  that blocked the Pyodide kernel worker passed CI and only failed in front of a
  student. The harness is verified to catch exactly that regression: its
  `selftest.sh` fails unless the editor passes on the default config **and**
  fails on both `NOTEBOOK_CROSS_ORIGIN_ISOLATION=true` (the blocked kernel
  worker) and `SMOKE_SIMULATE_FROZEN=1` (the service worker disabled, which
  reproduces the #959 "Page Unresponsive" freeze — `input()` hangs while the
  trivial cell still runs), so the guard can't silently rot. Wired into CI as a
  new
  `Editor smoke test` workflow that runs nightly and per-PR (path-filtered to
  the notebook/editor/middleware/asset files that can break the editor);
  advisory for now. See `docs/notebook-editor-smoke-test.md`.


## [0.4.468] - 2026-06-19

### Added

- **Editor success/SW telemetry + per-browser breakdown for diagnosing the notebook editor.** The client-diagnostics pipeline gained two non-failure beacons and the admin tool a new aggregation, so we can measure the editor *rate* and localize problems instead of only counting failures: `editor_ready` (the editor shell came up, with `elapsed_ms`) is the **success denominator** — paired with `preflight_fail` / `watchdog_timeout` / `page_unresponsive` it yields a real success rate and boot-time distribution; `sw_state` reports whether JupyterLite's service worker registered (`supported=…;registrations=…`), the signal that diagnoses "Kernel Unknown" per device; and `get_browser_diagnostics` now returns a **`byBrowser`** breakdown (coarse browser/OS from the User-Agent, e.g. `Safari/iOS`) so editor failures can be pinned to a browser/device class. All PII-safe (no student identifier), same boundary as the existing telemetry. Also adds `docs/notebook-editor-smoke-test.md` — a proposal for a pre-merge headless-browser smoke test that would have caught the recent COEP/kernel breakages at the gate.


## [0.4.467] - 2026-06-19

### Fixed

- **Re-enabled the JupyterLite service worker to fix the editor "Page Unresponsive" freeze.** The SW intercepts `/api/drive` and `/api/stdin/` and broadcasts to the Pyodide kernel — it is the kernel's synchronous-execution mechanism. v0.4.150 disabled it (to dodge a "Kernel Unknown" registration race), but that removed the kernel's *only* sync path (with no `SharedArrayBuffer` either), so a synchronous op (`input()`) hard-froze the page — a side-effect v0.4.150's own notes flagged ("input() in cells will hang"). The vended SW already does `skipWaiting()` + `clients.claim()` (the standard lifecycle that addresses the original controller race), so re-enabling restores sync and removes the freeze without cross-origin isolation (the COEP approach blocked the kernel worker). Reverses the `JupyterLiteConfigTests` guard accordingly. **Reintroduces the risk of the "Kernel Unknown" race on devices where the SW fails to control the page; must be browser-verified (Chrome + Safari + a managed device) before shipping — CI cannot test it. If it recurs, the follow-up is a kernel-wheel patch gating `mountDrive` on the SW actually controlling the page.**


## [0.4.466] - 2026-06-19

### Changed

- **Notebook editor cross-origin isolation is now unconditional** (removed the `NOTEBOOK_CROSS_ORIGIN_ISOLATION` flag introduced one release earlier). The student notebook page and the `/jupyterlite/*` iframe assets are always served with `Cross-Origin-Opener-Policy: same-origin` + `Cross-Origin-Embedder-Policy: require-corp` (+ `Cross-Origin-Resource-Policy: same-origin` on the assets), so the iframe document — where the Pyodide kernel worker runs — is cross-origin isolated and the kernel gets `SharedArrayBuffer` for synchronous execution. This is the fix for the "Page Unresponsive" main-thread freeze: with the JupyterLite service worker disabled (the "Kernel Unknown" fix) and no `SharedArrayBuffer`, a synchronous kernel operation had no non-blocking path and hard-froze the page; cross-origin isolation restores `SharedArrayBuffer` while keeping the service worker disabled, so both failure modes are addressed. `require-corp` only constrains cross-origin subresources, which Chickadee vendors same-origin.


## [0.4.465] - 2026-06-19

### Added

- **Opt-in cross-origin isolation for the notebook editor (`NOTEBOOK_CROSS_ORIGIN_ISOLATION`, default off).** Root-cause fix for the JupyterLite/Pyodide editor "Page Unresponsive" main-thread freeze. The kernel needs a synchronous-execution mechanism — `SharedArrayBuffer` (requires cross-origin isolation) or a service worker — and currently has neither (COEP was intentionally omitted from the editor page, and the JupyterLite service-worker manager is disabled to fix "Kernel Unknown"), so a synchronous kernel operation hard-freezes the page. When the flag is enabled, `COEPMiddleware` serves the student notebook page (`/testsetups/:id/notebook`) and `NotebookAssetIsolationMiddleware` serves the `/jupyterlite/*` iframe assets with `Cross-Origin-Opener-Policy: same-origin` + `Cross-Origin-Embedder-Policy: require-corp` (+ `Cross-Origin-Resource-Policy: same-origin` on the assets), making the iframe document — where the kernel worker runs — cross-origin isolated and restoring `SharedArrayBuffer`. `require-corp` only constrains cross-origin subresources, which Chickadee vendors same-origin, and the historical objection (JupyterLite's SW synthesised responses lacking CORP) no longer applies now that SW is disabled. **Gated behind the flag because COEP on the editor page has broken the iframe before (#574): enable on staging, verify the editor boots in each target browser, then enable in production — with instant rollback by flipping the flag, no redeploy.** Default off preserves the existing behaviour exactly.


## [0.4.464] - 2026-06-19

### Added

- **Main-thread freeze watchdog for the notebook editor.** When the JupyterLite/Pyodide editor page hard-freezes — Chrome's "Page Unresponsive" — the blocked main thread can't report anything, so these freezes were completely invisible in our telemetry (a real freeze hit a student and left zero diagnostic trace; we only knew from a screenshot). A dedicated `Public/freeze-watchdog-worker.js` now runs on its own thread, receives a heartbeat from `notebook.js` every 2s, and — because a same-origin iframe shares the parent's event loop, so a kernel hang stops the parent's heartbeats too — beacons a new `page_unresponsive` client-diagnostic when the heartbeats stall past ~8s while the tab is visible (a throttled background tab is not mistaken for a freeze; the server rate-limits duplicates). It surfaces in `get_browser_diagnostics` (by kind) and the instructor "Browser errors" card. Pure, fully-guarded observability — it never touches the editor; if the worker can't start, the page is unaffected. This makes the freeze diagnosable so the root-cause fix can be verified.


## [0.4.463] - 2026-06-19

### Changed

- **The student dashboard now reflects a personal deadline extension in the status badge.** Previously a student with an active extension on a class-closed assignment saw the class-wide **"closed"** badge — and on phones, where the due-date column (with its "(extension)" note) is hidden, that badge was the *only* status cue, so the assignment looked uneditable even though the student could still submit. The badge now reads **"extended"** (styled like "open", with a tooltip explaining the accommodation) whenever the viewer has an active extension on an otherwise-closed assignment. The gate behaviour is unchanged — this is display only; the badge value is derived per-viewer from `hasActiveExtension`, scoped to the genuine published-then-closed case (preview/unpublished and class-wide-open rows are untouched, and staff carry no extensions). The due-date column already surfaced the extended date; this closes the gap for the badge (and for mobile).


## [0.4.462] - 2026-06-18

### Changed

- **The student notebook page no longer spawns an `unzip` subprocess on every visit.** `createSupportFileSymlinks` runs on each notebook load to (idempotently) link the assignment's support files into the student's working directory, and it listed the test-setup zip fresh every time — a `/usr/bin/unzip` subprocess under the global zip process lock, redundant after the first visit and a source of tail latency when many students load notebooks at once. The zip-listing cache that already backed the dashboard's "has a notebook?" check (`NotebookPresenceCache`, keyed by the zip's mtime + size) is generalized into a shared `ZipEntryListCache` that caches the full entry list; the notebook page's symlink pass now reads through it, and the presence check becomes a derived query — one zip-listing cache instead of two near-identical ones. The cache busts automatically whenever the instructor edits the zip (every mutation repacks the archive, changing its mtime/size), so newly added or removed support files are still linked. No behaviour change beyond removing the redundant subprocess.


## [0.4.461] - 2026-06-18

### Fixed

- **The session reaper was failing on every sweep in production (Postgres), so expired sessions never got purged.** `reapStaleSessions` hand-rolled raw SQL that compared the `_fluent_sessions.created_at` `TIMESTAMP` column against a *text*-bound ISO8601 cutoff. SQLite's loose typing accepted it (so CI stayed green), but Postgres rejected `timestamp < text` and the hourly sweep threw every time — leaving `_fluent_sessions` to grow without bound (fast under vulnerability-scanner traffic). Because sessions are Fluent-backed and looked up on every authenticated request, the bloated table slowed page loads server-wide. The reaper now uses a Fluent typed query — the **same pattern as `AuditLogReaperService` and `ActivityEventReaperService`, which were deliberately written this way to avoid exactly this `Date`-vs-`timestamp` binding pitfall** — so it binds correctly on both SQLite and Postgres and the three reapers no longer diverge. NULL `created_at` rows (pre-migration) are still preserved. Added `SessionReaperServiceTests` covering the deletion semantics; run under the Postgres CI job it also guards against the `timestamp < text` regression. Operators with an already-bloated table can reclaim it with a one-time `DELETE FROM _fluent_sessions WHERE created_at < now() - interval '8 days'` followed by `VACUUM`.


## [0.4.460] - 2026-06-18

### Changed

- **Closed assignments stay visible to enrolled students.** A published assignment that has closed at its deadline now remains on every enrolled student's dashboard (shown as `closed`, read-only) and is openable for review, instead of silently disappearing for any student who never opened it while it was open. Recent labs no longer vanish for students who missed the window — including those a platform issue locked out. Unpublished drafts (a `closed` assignment with no past due date), `preview` (staff-only) assignments, and not-yet-started (future open date) assignments stay hidden, so authoring-in-progress content never leaks. New shared helper `assignmentVisibleToStudentByState` drives the dashboard filter and the notebook read-only view gate so they can't drift; submission remains separately gated, so the widened access is strictly read-only.

### Security

- **The reference solution is now staff-gated on the student notebook route.** `GET /testsetups/:id/notebook?file=solution` previously rendered the instructor's answer-key notebook for any enrolled student who crafted the query (the guard relied on the absence of a UI link). It now returns `403` for non-instructors, closing the exposure on open assignments and preventing the closed-assignment read-only view from widening it.

### Added

- **Submit-phase breadcrumbs for diagnosing in-browser submission freezes.** Browser grading runs Pyodide on the main thread, so a hang during a submission (slow runtime boot, package/zip stall, or a CPU-bound test) freezes the page and produces no exception and no result POST — invisible to the server. `Public/browser-runner.js` now emits a `submit_phase` breadcrumb at each step of the grading flow (`grading_start` → `runtime_loaded` → `setup_unpacked` → `suite_started` → `suite_done` → `result_posting` → `result_posted`, plus `submit_error`), sent fire-and-forget with `fetch(keepalive:true)` so a breadcrumb dispatched *before* a phase reaches the server even if that phase then freezes. The last phase a frozen student reaches has no successor record, pinpointing where submissions stall. Breadcrumbs are scoped to real student submissions (instructor validation stays silent). The admin diagnostic tool `get_browser_diagnostics` now returns a `submitFunnel` (phase counts in order) so the drop-off is readable, and accepts the new `submit_phase` / `submit_error` kinds; the instructor "Browser Errors" card is unaffected (it still counts only `preflight_fail` / `watchdog_timeout`). No schema change — breadcrumbs reuse the existing `client_diagnostics` `source` / `message` columns and the per-(user, setup, kind, source) hourly rate limit.


## [0.4.459] - 2026-06-18

### Fixed

- **A per-student extension now lets that student complete a closed assignment until the extension's date, no matter how or why it closed.** Previously the submission gate inferred instructor intent from *when* the assignment closed and from how the extension date compared to the original deadline, so granting an extension on an assignment that was closed before its deadline — or with a date earlier than the original due date — silently had no effect, locking the accommodated student out of submitting and editing. An extension is now active purely while its date is in the future: the student may submit and edit regardless of the assignment-wide open/closed state (the only thing it still respects is a not-yet-reached *open* date, since an extension lengthens the deadline, not the start). The "is this extension live" check is consolidated into one shared `studentHasActiveExtension` helper used by the submission gate, the student dashboard gate, and the dashboard visibility filter so the three can never drift, and the contract is pinned by an exhaustive invariant test plus integration tests for the early-close and earlier-than-deadline cases.


## [0.4.458] - 2026-06-18

### Added

- **Admin diagnostic MCP: dashboard + operational-surface tools.** The admin MCP
  diagnostic surface gained eleven read-only tools so an agent has parity with
  the admin/instructor web dashboards' operational views, each served from the
  same builder its page uses. Dashboard sparklines: `get_metrics_card_series`
  (the five operational cards), `get_active_users_series` (the "Active Users"
  chart), `get_instructor_card_series` (one course's submission / active-student
  / active-assignment / browser-error counts, scoped by `courseCode`). Operational
  surface: `get_metrics_timeseries` (flexible window/bucket incl. HTTP request
  latency), `get_queue_state` (pending/in-flight/oldest-pending/stuck counts),
  `list_runners` + `get_runner_detail` (capability profile + aggregate per-stage
  timing + cache-hit rate), `get_storage_usage` (disk footprint by component +
  per-assignment), `get_request_metrics` (slowest routes / status classes),
  `list_connected_agents` (MCP OAuth grants), `get_brightspace_sync_status`
  (grade-push health), and `query_audit_log` (activity counts by action/category).
  All read-only and PII-free by construction: aggregates/percentiles, redacted
  DTOs, or counts-only — no student identity, grade, submission content, or
  enrollment is reachable. The three identity/grade-adjacent sources (audit log,
  BrightSpace sync, per-job runner metrics) drop the student fields entirely
  (`query_audit_log` returns no actor/IP/metadata; `get_brightspace_sync_status`
  drops username + grade; `get_runner_detail` omits the per-job rows the web page
  shows), each asserted by a per-tool PII test.

### Added

- **MCP achievements authoring.** The content-authoring MCP server gained
  `get_achievements` and `update_achievements`, closing the gap where an agent
  could author tests, solutions, and personalization but not an assignment's
  composable awards. The pair mirrors the web Achievements editor
  (`GET`/`PUT /instructor/:id/achievements`) and runs the same validation via a
  new shared `AchievementsEditing` service. Achievements are server-evaluated
  and display-only, so — unlike every other content edit — updating them does
  not re-validate, re-grade submissions, or close the assignment.


## [0.4.457] - 2026-06-18

### Fixed

- **Hardened the in-browser notebook editor against intermittent dead-kernel
  ("Kernel Unknown") boots.** A small, steady fraction of students hit a
  JupyterLite/Pyodide kernel that registered `dead`/`unknown` at startup — a
  load-ordering race, not a content bug. Three layers address it:
  - **Boot gating (root cause).** The editor iframe no longer boots eagerly from
    the template `src`. JupyterLite now starts only after the capability
    preflight resolves (`mountEditor` sets the src), so the kernel's cold boot
    no longer races the preflight's concurrent service-worker registration and
    IndexedDB probes — the same subsystems kernel startup depends on.
  - **Submit guard.** Browser grading runs its own Pyodide, separate from the
    editor kernel; the submit path now waits for the editor shell before
    starting it, so a submit clicked during a cold boot can't spin up a second
    Pyodide and starve the still-booting kernel. The wait is bounded, so a
    genuinely dead editor still degrades to grading.
  - **Recovery reload (safety net).** If the kernel still registers
    `dead`/`unknown`, the watchdog reloads the editor once before falling back
    to the upload panel, preserving the student's saved work (workspace restore
    + the existing reseed-preservation logic). A failure that persists after the
    reload is reported with the same `watchdog_timeout` / `kernel-unhealthy`
    classification, annotated `persisted after auto-reload` so the admin
    browser-diagnostics breakdown can distinguish it from a recoverable
    first-try failure.


## [0.4.456] - 2026-06-18

### Changed

- **Admin diagnostic MCP tied to `MCP_MODE` (no separate config).** The admin
  diagnostic surface (`docs/admin-mcp.md`) no longer has its own `ADMIN_MCP_*`
  environment variables. It now mounts (read-only) exactly when the content MCP
  is mounted via `MCP_MODE` (`read_only` or `read_write`) — all-or-nothing — and
  reuses the content surface's host/origin guards, issuer, access-token TTL, and
  ES256 signing key/authority (the two surfaces are separated by token audience,
  `…/mcp` vs `…/admin-mcp`, not by a second key). It stays read-only even under
  `MCP_MODE=read_write` (it only ever advertises/honors `diagnostics:read`).
  `AdminMCPConfig` / `AdminMCPMode` are removed.


## [0.4.455] - 2026-06-17

### Added

- **Admin diagnostic MCP — query_logs (internal).** Completes the read-only
  admin diagnostic surface (`docs/admin-mcp.md`) with `query_logs`: recent
  server log events (warning and above) filterable by level, message substring,
  and look-back window. Backed by a shared in-process `AdminEventSink` ring
  buffer fed by a `RingBufferLogHandler` multiplexed alongside Vapor's existing
  console logger — console output is unchanged, PII metadata keys are dropped at
  capture, and the buffer is per-process and resets on restart. Admin-gated; no
  database and no new configuration.


## [0.4.454] - 2026-06-17

### Added

- **Admin diagnostic MCP — browser-error tool (internal).** Adds
  `get_browser_diagnostics` to the read-only admin diagnostic surface
  (`docs/admin-mcp.md`): totals and breakdowns by kind / source / failed
  capability check over a window, plus recent samples carrying the actual
  JupyterLite/Pyodide error message and stack captured by the browser-error
  enrichment. Admin-gated; the response is a hand-built DTO that omits the
  student `user_id` (the no-student-data guarantee, asserted by a per-tool PII
  test) — no dedicated DB role.


## [0.4.453] - 2026-06-17

### Added

- **Admin diagnostic MCP — OAuth issuance (internal).** The browser OAuth 2.1
  flow (`/oauth/authorize` + `/oauth/token`) is now resource-aware: an admin can
  authorize an agent for the admin diagnostic resource (`docs/admin-mcp.md`),
  selected by the RFC 8707 `resource` parameter or the requested scope namespace
  (`diagnostics:read`). The flow branches the scope ceiling, role gate
  (`isInstructor` for content, `isAdmin` for diagnostics — re-checked at consent
  and on every refresh), signing key, and audience by resource, with no schema
  change (the disjoint `content:*` / `diagnostics:*` namespaces identify the
  surface at every step). The content authoring flow is unchanged. Note: the
  shared authorization server mounts with `MCP_MODE`, so admin OAuth issuance
  currently requires the content MCP endpoint to also be enabled.


## [0.4.452] - 2026-06-17

### Added

- **Admin diagnostic MCP — operational tools (internal).** The read-only admin
  diagnostic surface (`docs/admin-mcp.md`) gains two tools: `get_metrics_snapshot`
  (per-runner load/liveness, peak queue depth, recent job status counts,
  queue-wait/execution percentiles, compatibility counters — the same PII-free
  aggregate the admin dashboard serves) and `get_health_alerts` (live evaluation
  of the server-health rules with thresholds). Both enforce admin-only access and
  expose aggregates only — no student, submission, course, or assignment data.


## [0.4.451] - 2026-06-17

### Added

- **Admin diagnostic MCP — HTTP mount + bearer auth (internal).** The read-only
  admin diagnostic surface (`docs/admin-mcp.md`) is now mountable at
  `POST /admin-mcp` behind `ADMIN_MCP_MODE=read_only`, with its own
  `AdminMCPBearerAuthMiddleware` (separate ES256 signing key + token audience
  from the content surface, so a content token can't call admin tools), an
  RFC 9728 protected-resource discovery document, the production DNS-rebinding
  fail-safe, and per-call audit (`admin_mcp.tool_called`). Off by default; OAuth
  consent issuance lands in a follow-up, so it's reachable only with a
  directly-minted admin token for now.


## [0.4.450] - 2026-06-17

### Added

- **Admin diagnostic MCP — foundation (internal).** The dispatch-layer scaffold
  for a separate, read-only, admin-only MCP surface for operational diagnosis
  (`docs/admin-mcp.md`): `AdminMCPMode` / `DiagnosticScope` / `AdminMCPConfig`
  (`ADMIN_MCP_MODE`, off by default), `AdminToolContext` with an admin-only gate,
  a parallel `DiagnosticTool` registry + `AdminMCPDispatcher` (tools-only,
  read-only), and the first tool `get_deployment_info`. Nothing is mounted yet —
  this slice has no runtime effect; the HTTP transport, bearer auth, and OAuth
  consent land in following slices.


## [0.4.449] - 2026-06-17

### Added

- **Browser-error detail capture.** The in-browser editor now records uncaught
  JavaScript errors and unhandled promise rejections on the notebook page
  (`window.onerror` / `unhandledrejection`) as a new `editor_error` client
  diagnostic, and the kernel-unhealthy watchdog path now attaches the concrete
  failure evidence (e.g. `kernel status: dead`, `Kernel Unknown badge`).
  `client_diagnostics` gains `message`, `stack`, and `source` columns, and the
  per-(user, setup, kind) rate limit now also keys on the error source so
  distinct origins aren't collapsed. Capture is restricted to the editor-load
  path — never student-code execution — so no student-authored content is
  stored. Groundwork for the admin diagnostic tooling described in
  `docs/admin-mcp.md`.


## [0.4.448] - 2026-06-17

### Removed

- **Import-from-Marmoset workflow.** Removed the legacy "Import from Marmoset"
  instructor feature — the upload page, the `/instructor/import-marmoset`
  routes, the Marmoset export parser, and the dashboard button. The MCP
  authoring tools have superseded it (creating and validating assignment
  content directly). The runner's handling of Marmoset-style file layouts and
  the project's origin as a clean-break Marmoset rewrite are unchanged.


## [0.4.447] - 2026-06-17

### Added

- **MCP `author_script` can fetch a support file from a URL.** A data/support
  file too large to inline faithfully in a tool call (e.g. a CSV fixture) can
  now be authored by passing `sourceUrl` (an https URL) instead of `content`;
  the server downloads the body and stores it as the file. Exactly one of
  `content`/`sourceUrl` must be supplied.

### Security

- **The `author_script` URL fetch is SSRF-guarded.** Only `https` is allowed;
  the host is resolved server-side and the fetch is refused if any resulting
  address is loopback / private / link-local (incl. the `169.254.169.254`
  cloud-metadata range) / CGNAT / unique-local / multicast / reserved (IPv4,
  IPv6, and IPv4-mapped/compatible/NAT64 forms are normalised first); redirects
  are not followed; the body is capped at 8 MB while streaming; and the request
  is bounded by connect/read/overall timeouts. The fetch runs only after the
  caller is authorized for the assignment's course, and the address-range logic
  is exhaustively unit-tested (`BlockedIPClassifier`). No new env var or host
  allowlist is introduced; the one residual is a theoretical DNS-rebinding TOCTOU
  window (AsyncHTTPClient re-resolves the host), narrowed by disallowing
  redirects.


## [0.4.446] - 2026-06-17

### Fixed

- **Instructor "Reset notebook" appeared to do nothing on the student's
  next visit.** The reset overwrote the working copy on the server and the
  mtime-based cache-bust signal correctly told the browser to force-reseed
  IndexedDB — but JupyterLite's workspace restore had usually already
  re-opened the *previous* (stale) document, and `docmanager:open` on an
  already-open path only focuses it without re-reading the freshly-seeded
  contents. The reset therefore only became visible on a *second* page
  load. `syncNotebookFromServerSnapshot` now reverts the open document's
  context after reseeding when the server copy is newer (a reset), so the
  starter shows immediately. Gated on the server-newer + had-local-copy
  case via a new pure `reseedPlan` helper so a normal revisit never
  discards a student's unsaved in-editor edits. Regression-pinned in
  `Tests/BrowserRunnerJSTests/sync-force-reseed.test.mjs`.


## [0.4.445] - 2026-06-17

### Added

- **MCP `reorder_assignments` tool.** Agents can now set the instructor-defined
  display order of a course's assignments — the assignment-level counterpart to
  `reorder_course_sections`, mirroring the web dashboard's drag-reorder. Takes a
  full permutation of the course's assignment public IDs and rewrites the
  course-global `sort_order`; it's organizational metadata, so it never re-runs
  validation or changes an assignment's open/closed state.


## [0.4.444] - 2026-06-16

### Added

- **Clone / duplicate an assignment from the instructor dashboard (#546).**
  Each published assignment row gains a "Duplicate" action that copies the
  assignment (notebooks, test-setup zip, manifest) into a new closed,
  unvalidated copy in the same course (`POST /instructor/:assignmentID/clone`),
  then drops the instructor on the copy's edit page to set a due date and
  re-validate before opening. The web action and the `clone_assignment` MCP
  tool both go through `AssignmentAuthoringService.cloneAssignment`, so the two
  clone paths can't drift.

### Added

- **Per-test partial credit is now shown to students (#548).** When a test
  earned a fraction of its points (a script that emitted an explicit `score`
  in its stdout footer, `0 < score < 1`), the submission results table now
  renders the earned fraction next to the result mark — e.g. `1.5 / 2 pts` —
  instead of only the test weight. Full credit and no credit keep the plain
  weight label. Parsing, storage, and grade rollup (`earnedPoints = Σ points ×
  score`) were already wired; this surfaces the per-test breakdown in the UI.


## [0.4.443] - 2026-06-16

### Changed

- **Docs: corrected the Leaf decomposition roadmap note.** The previous
  "UNBLOCKED" claim was wrong for the large assignment editor pages. A
  LeafKit 1.14.2 parser bug makes two or more inline `#extend("_partial")`
  includes in one template fail at render (`LeafError.500: extend only
  supports one or two parameters []`). It is template-wide, not
  partial-specific: any second inline `#extend` on
  `assignment-new.leaf` / `assignment-edit.leaf` 500s the page. The note now
  records the evidence (bisected against the real render tests), the failed
  workarounds (bodied form, parent `#if`), and the practical rule — at most
  one inline partial `#extend` per template until leaf-kit is patched.


## [0.4.442] - 2026-06-16

### Changed

- **Compacter student-dashboard rows.** Assignments with no submissions now
  show a dash in the Submissions column instead of the taller "No submissions
  yet" text, and a row's achievement badges are capped to the first three
  inline awards with the rest collapsed into a "+N" overflow pill (the pill's
  tooltip names the hidden awards). Prevents rows from ballooning when a student
  has earned many badges; the full set still shows on the submission view.


## [0.4.441] - 2026-06-16

### Changed

- **Animated, easier-to-scan inline editors on the assignment edit page.** The
  inline "accordion" editors (pattern families / notebook checks in the suite
  editor, and the achievements editor) now expand and collapse with a smooth
  height animation instead of popping open. The open editor is tied to its row
  with a left accent bar and a rotating disclosure caret, rows highlight on
  hover, and per-test separators are firmer so individual tests are easier to
  tell apart. The animation is honoured uniformly through a single shared
  helper (`ChickadeeUI.accordion`) and respects `prefers-reduced-motion`.


## [0.4.440] - 2026-06-16

### Changed

- **Docker base image: Ubuntu 22.04 (jammy) → 24.04 (noble).** Both Dockerfile
  stages move together — build (`swift:6.3-jammy` → `swift:6.3-noble`) and
  runtime/prebuilt (`ubuntu:22.04` → `ubuntu:24.04`) — so the
  statically-linked-stdlib binaries still match the runtime glibc. All CI jobs
  are unified onto `swift:6.3-noble` (the historical format-lint-on-noble /
  tests-on-jammy split is gone, since noble's glibc 2.39 already satisfied the
  SwiftLintBinary GLIBC 2.38 requirement), and the now-unused jammy image is
  dropped from the mirror workflow. **Grading-environment note:** the runtime
  stage's apt packages move to noble's versions — Python 3.10 → 3.12, plus newer
  numpy / pandas / scipy / matplotlib and R — so student submissions graded on
  the worker now run against that newer environment. Validate representative
  assignments before deploying.


## [0.4.439] - 2026-06-16

### Changed

- **Dependency maintenance: refreshed transitive pins and tightened manifest floors.**
  Ran `swift package update` to pick up the minor/patch transitive bumps
  Dependabot doesn't manage (it only moves the `Package.swift` floors): `swift-nio`
  2.99.0 → 2.101.0 (+ http2/ssl/extras), `jwt-kit` 5.2.0 → 5.5.0, `swift-collections`
  1.5.0 → 1.6.0, `swift-log` 1.12.0 → 1.13.2, `swift-system` 1.6.4 → 1.7.2,
  `async-http-client` 1.33.1 → 1.34.0, plus `swift-http-types`, `swift-metrics`,
  `swift-asn1`, and `swift-async-algorithms`. Also raised the lagging `from:` floors
  in `Package.swift` to match what's resolved (`vapor` 4.121.4, `swift-argument-parser`
  1.8.2, `SwiftLintPlugins` 0.63.3). No direct-dependency major-version changes; no
  source changes.


## [0.4.438] - 2026-06-16

### Changed

- **Achievements are now a composable design space.** The closed
  `AchievementKind` taxonomy is replaced by an instructor-authored combination
  of a *scope* (this student / the class together / a class record), a list of
  typed *conditions* over a submission's graded signals (grade, attempts, run
  time, grade jump, a test passing) combined with all/any, and the scope's
  reward. The eight built-in awards are migrated to this shape, the three
  per-kind evaluation sites collapse into one condition evaluator, and existing
  manifests authored against the old kinds decode transparently (re-saving
  migrates them forward).
- **Achievements editor moved to an inline accordion with autosave.** Editing
  an achievement now expands an inline row (the suite editor's pattern) instead
  of a top-left modal, and every Save/Remove persists immediately — the
  separate "Save Achievements" button is gone.


## [0.4.437] - 2026-06-15

### Security

- **MCP compliance hardening, round 2 (UW IRA follow-ups).** Four
  defence-in-depth controls for the MCP server: (1) an optional dedicated
  least-privilege PostgreSQL pool for the MCP path
  (`MCP_DATABASE_USER`/`MCP_DATABASE_PASSWORD` +
  `deploy/sql/mcp-least-privilege-role.sql`) that walls off student tables at
  the database layer, with the content-edit re-grade moved to the privileged
  pool so auto-regrade still works; (2) write tools now **fail closed** when
  their audit record can't be persisted (reads stay best-effort); (3)
  production **refuses to mount** `/mcp` when the Host/Origin DNS-rebinding
  guards are left open, unless `MCP_ALLOW_OPEN_GUARDS=true`; and (4) a
  documented deployment egress allowlist (`deploy/egress-allowlist.md`)
  restricting outbound traffic to the server's real destinations — no model
  API endpoint.


## [0.4.436] - 2026-06-15

### Security

- **MCP server security & privacy hardening for the UW Information Risk
  Assessment.** The MCP tool surface now reaches the submissions/results tables
  only through a single validation-filtered boundary (`MCPStudentDataBoundary`),
  with a build-failing guard test if any tool handler reads student data
  directly — making the student-data wall architectural rather than
  convention. Every `mcp.tool_called` audit entry now records the call outcome
  and target resource (assignment/course), while still never logging tool
  arguments. The auto-generated MCP signing key is git-ignored, and new guard
  tests cover per-resource authorization on every tool and restrict
  reference-solution egress to `get_solution`. Adds the pre-approval audit
  artifacts under `docs/compliance/`.


## [0.4.435] - 2026-06-14

### Fixed

- **Clearing a pattern family's prerequisites now actually drops them from the
  generated test rows.** Generated-case `dependsOn` was rebuilt as
  `[guard] + family.dependsOn + the prior manifest row's deps`, and that last
  term made a once-set family-level prerequisite permanently "sticky": once a
  family pointed at a script (e.g. a hand-written `*_exists` check), every
  regeneration re-read the old generated row and re-added the dependency, so
  clearing `family.dependsOn` never propagated. The practical symptom was an
  un-deletable script — the suite editor and the MCP `delete_suite_item` /
  `update_pattern_family` tools both rejected removing it with a dangling
  "depends on … which is not listed in testSuites" error, because a
  hand-written script is not a generated file and so never entered the deletion
  diff. Generated-case dependencies are now derived solely from the current
  spec (`[guard] + family.dependsOn`), so clearing the family's prerequisites
  removes them from every generated row and unblocks the delete.


## [0.4.434] - 2026-06-14

### Fixed

- **Deleting an assignment no longer fails with "Session refreshed".** The
  three assignment delete forms in the Ungrouped table on the instructor
  dashboard (the `closed` / `open` / preview branches in `assignments.leaf`)
  were missing `#csrfFormField()`, so `POST /instructor/:id/delete` arrived
  without a `_csrf` token and the CSRF middleware rejected it with a 403.
  Because every assignment renders in that Ungrouped table when no course
  sections are defined, every delete failed; moving an assignment into a
  section (whose table already emitted the token) was the only workaround.
  All eight delete forms on the page now emit the hidden CSRF field.


## [0.4.433] - 2026-06-14

### Changed

- **Instructor dashboard: "Students With Browser Errors" is now a "Browser
  Errors" sparkline.** The static reconciled "students stuck right now" gauge is
  replaced by a cyclable 24h / 7d / 30d sparkline of raw browser-error events
  (`preflight_fail` + `watchdog_timeout` client diagnostics) per bucket, scoped
  to the course's enrolled students. Raw events (rather than the
  recovery-reconciled count) make a post-deploy decline visible, so instructors
  can confirm a browser-grading fix actually landed. Served by the existing
  course-scoped `GET /instructor/metrics/cards` endpoint. "Queued Right Now"
  remains the one static gauge.


## [0.4.432] - 2026-06-13

### Fixed

- **Admin diagnostic-card sparklines no longer overload the database.** The
  `GET /admin/metrics/cards` endpoint scanned up to 30 days of `RunnerSnapshot`
  rows (recorded every ~30s, so tens of thousands of rows); under the
  dashboard's 60s poll, concurrent requests stacked that long query on separate
  connections and could drain the Fluent pool, surfacing as
  `ConnectionPoolTimeoutError` and 500s on unrelated pages. Two changes fix it:
  (1) on Postgres the runner-load series is now pre-aggregated **in the
  database** to per-5-minute summed load, collapsing the scan to a few hundred
  rows (SQLite keeps an equivalent Swift aggregation); and (2) the whole series
  is served through a single-flight, 60s-TTL cache (`MetricsCardCache`) so the
  query runs at most once a minute no matter how many pollers or pages request
  it. The "Max Load" card's peak pair is computed at 5-minute resolution.

### Fixed

- **`/admin/metrics` and `/admin/metrics/timeseries` no longer stream the full
  `RunnerSnapshot` scan.** The snapshot and time-series endpoints loaded every
  runner heartbeat in the window (a row every ~30s) and bucketed them in Swift —
  the same unbounded-scan / pool-holding pattern that overloaded the diagnostic
  cards. The runner-load aggregation is now done **in the database** on Postgres
  (per-display-bucket utilization average / peak, and the summed-load peak pair),
  with an equivalent Swift aggregation on SQLite (dev / tests) where the data is
  tiny. Both paths produce identical results, pinned by a Postgres-exercised
  parity test. Request- and job-metric series are submission-bound and stay raw.

### Added

- **Instructor dashboard diagnostic cards now have sparklines + cyclable time
  windows.** The Submissions, Active Students, and Active Assignments cards on
  the instructor overview gained the same click-to-cycle 24h / 7d / 30d
  sparkline treatment as the admin dashboard, fed by a new course-scoped
  `GET /instructor/metrics/cards` endpoint. The whole series is derived from a
  single trailing fetch of the longest window's student submissions (projected
  to the three columns the buckets need), so the dashboard's poll stays cheap.
  The sparkline renderer and card styles are now shared between the admin and
  instructor dashboards (`ChickadeeUI.renderSparkline`, global card CSS). The
  Queued Right Now and Students With Browser Errors gauges remain static cards.


## [0.4.431] - 2026-06-13

### Added

- **Sparklines on the admin diagnostic cards.** Each of the five Overview
  cards (Max Queue, Jobs Processed, Max Load, P95 Wait, P95 Execution) now
  renders a mini bar chart of its trend, and clicking a card cycles its time
  window through 24h → 7d → 30d. Backed by a new
  `GET /admin/metrics/cards` endpoint that returns all three windows in one
  payload (per-bucket peak queue depth, completed jobs, peak runner
  utilization, and queue-wait/execution P95s), so cycling is instant and the
  dashboard polls once a minute instead of every 15 seconds.

### Changed

- **`RUNNER_SNAPSHOT_RETENTION_DAYS` default raised from 14 to 30** so the
  30-day Max Load sparkline has full data, matching
  `JOB_METRIC_RETENTION_DAYS`.


## [0.4.430] - 2026-06-12

### Added

- **MCP `get_support_files` tool.** An authorized agent can now list an
  assignment's support files — the non-graded helper/data files bundled in the
  test-setup zip (e.g. the CSV a notebook check loads) — and read one as UTF-8
  text, byte-capped (default 64 KB) so large datasets return a useful head.
  Previously an agent could *write* a support file via
  `author_script(tier:"support")` but had no way to confirm what was bundled or
  author data-aware checks against its contents. Graded scripts and the
  starter/solution notebooks are excluded (their dedicated read tools cover
  them). `content:read`, course-scoped, instructor-authored content only.


## [0.4.429] - 2026-06-12

### Added

- **MCP `get_validation_result` tool.** An authorized agent can now read the
  per-test outcomes of an assignment's latest validation run (each check's
  status plus `shortResult`/`longResult`, across all tiers), closing the
  diagnosis loop that `validate_assignment` left open — it reported only
  passed/failed/no-runner, so a failing suite couldn't be diagnosed without a
  human copying the per-test grid out of the web UI. The tool is
  `content:read`, course-scoped, and validation-only: it resolves the
  instructor's own reference-solution run from the assignment and never accepts
  or returns a student submission, identity, or grade.


## [0.4.428] - 2026-06-12

### Changed

- **swift-crypto bumped 3.15.1 → 4.5.0** (#916, supersedes #580). The 4.x
  line's breaking change is dropping Swift < 6.1 (Chickadee is on 6.3) and it
  includes the upstream CVE-2026-28815 X-Wing HPKE fix. The HMAC/SHA-256 and
  JWT APIs Chickadee uses are unchanged; verified against the MCP OAuth
  (ES256), SSO, and worker HMAC test suites.


## [0.4.427] - 2026-06-12

### Added

- **Admin dashboard "Active Users" chart.** The admin overview now shows a
  full-width bar chart of distinct active users per time bucket over a
  selectable 24-hour / 1-week / 1-month window, beneath the existing
  diagnostics, runners, and courses sections. A new `user_activity_events`
  table records throttled per-user activity pings (written by
  `UserActivityMiddleware`, at most once per user per 5 minutes); the chart is
  served by `GET /admin/activity` and reaped to a 35-day retention by a new
  hourly sweep.

### Changed

- **BrightSpace grade-sync logic is now unit-testable.** A narrow
  `BrightSpaceGrading` protocol seam covers the two network-touching client
  operations (`lookupUserID`, `pushGrade`); the sweep depends on the protocol
  so tests substitute an in-memory fake. Seven new tests cover best-grade
  selection, the debounce window, user-ID caching, missing-account and
  push-failure paths, and the validation-run exclusion. Production behaviour
  unchanged. (#629)


## [0.4.426] - 2026-06-12

### Changed

- **Leaner Embedded-Swift wasm runner.** `RunnerCore`'s ASCII-domain string
  operations (shebang/extension lowercasing, JSON `\uXXXX` hex parsing) now use
  ASCII-only helpers instead of `lowercased()` / `Character.hexDigitValue`,
  which avoids linking Unicode case-folding / numeric-property tables into the
  browser wasm build. Behaviour is identical for these ASCII inputs (pinned by
  the shared `output-contract.json`). The `wasm-opt` invocation also gains
  `--converge --strip-producers`. The shipped bytes change only when the wasm is
  re-vendored (`scripts/build-runner-wasm.sh`).


## [0.4.425] - 2026-06-12

### Fixed

- **Course copy and bundle export/import now preserve course sections and
  notebooks.** Copying a course recreates its sections (names, grading modes,
  ordering) and keeps each assignment in its section instead of dumping
  everything ungrouped; the copy also follows the setup's actual stored
  notebook path, so notebooks in the `notebooks/<setupID>/` subdirectory are
  no longer silently dropped. `.chickadee` bundles carry a new optional
  `sections` array (+ `sectionBundleID` per assignment) that round-trips
  sections through export → import; older bundles without the field still
  import fine, just ungrouped. (#342)


## [0.4.424] - 2026-06-12

### Changed

- **De-flaked the nightly clean-build & coverage run.** Test fixtures now hash
  passwords at the minimum bcrypt cost (4) instead of the production default
  (12) via a shared `testPasswordHash()` helper. Running cost-12 hash+verify for
  every login across the parallel suite saturated the 2-core CI runner; under the
  coverage build's slowdown that CPU starvation intermittently flaked
  auth-dependent tests (303/401 redirects, ~80 s stalls). The app's configured
  hasher is unchanged, so `AuthProvider`'s account-enumeration timing-equalizer
  still runs at production cost.


## [0.4.423] - 2026-06-12

### Fixed

- **Inline `#` comments no longer confuse notebook cell classification.** A
  top-level statement like `print(total_dose_mg) #when weight_kg = 30` found
  the `=` inside its trailing comment and was misclassified as a module-level
  assignment, so the `print(...)` ran at import time and leaked stray stdout
  into test `longResult`s. Comments are now stripped (quote-aware, so `#`
  inside string literals is untouched) before classification — which also
  fixes the inverse case where a real assignment whose comment mentioned a
  call (`dose = 30  # see compute()`) was wrongly quarantined. Fixed in
  `RunnerCore`, so the native worker and the browser/wasm grader both pick it
  up. (#741)


## [0.4.422] - 2026-06-12

### Changed

- **Dashboard queries parallelized.** The student dashboard's independent DB
  reads now run concurrently via `async let` (extensions, prior engagement,
  course sections; grade overrides + submissions; results + achievement
  lookups), cutting the handler's sequential round trips roughly in half.
  The engagement/extension/section loaders moved to
  `WebRoutes+IndexLoading.swift`. No behaviour change — same queries, same
  results, fewer back-to-back waits.


## [0.4.421] - 2026-06-12

### Changed

- **Website responsiveness pass.** Three hot-path fixes that make page loads
  feel snappier: (1) the student dashboard no longer spawns an `unzip`
  subprocess per assignment row on every view — notebook presence is now
  answered by `NotebookPresenceCache`, keyed by zip mtime + size so any suite
  edit still invalidates it; (2) version-fingerprinted static assets
  (`/styles.css?v=…`, page scripts, icons) are now served with
  `Cache-Control: immutable` via `StaticAssetCacheMiddleware`, eliminating the
  per-navigation revalidation round trips (each of which also paid a Fluent
  session lookup) — a release mints new URLs, so busting is unchanged;
  (3) response compression is enabled for compressible types (CSS/JS/JSON/SVG
  shrink ~4–8× on the wire). HTML is deliberately excluded from compression
  because pages embed the per-session CSRF token (BREACH); already-compressed
  formats (zip, wasm, images) are not recompressed.


## [0.4.420] - 2026-06-11

### Fixed

- **Phone/tablet overflow on admin & instructor pages ("Phase 3b").** A live
  responsiveness audit (headless, 375px/768px — see
  `docs/responsiveness-audit-2026-06.md`) found seven pages overflowing a
  phone viewport: `/admin`, `/admin/users`, `/admin/mcp`, `/agents`,
  `/admin/storage`, `/admin/retention`, `/admin/alerts` (plus the BrightSpace
  page statically). All their tables now use the `.table-scroll` wrapper, and
  the page-local fixed-width / no-wrap rules (`.toolbar--nowrap`,
  `.alerts-webhook-input`, `.retention-actions`, `.bs-grade-form`,
  `.mcp-username-input`, `.students-filter`) relax below the phone
  breakpoint. Re-run of the live audit: zero horizontal overflow on every
  reachable page at 375px and 768px; desktop unchanged.
- **Extension/grade-override popover fits a phone.** The
  `course-student-submissions` action panel drops into static flow ≤640px
  (matching the assignment-submissions form), and the instructor dashboard
  publish popover loses its 260px floor on phones.
- **iOS zoom-on-focus.** Form inputs are 1rem on phones so iOS Safari no
  longer zoom-and-pans when focusing a field.
- **Notebook editor no longer boots in the background on phones.** ≤640px the
  hidden JupyterLite iframe's eager navigation is aborted and `notebook.js`
  skips the preflight/watchdog/mount entirely (reloading if the viewport
  grows past the breakpoint) — previously the full JupyterLite + Pyodide
  stack downloaded behind the "open on a larger screen" notice.


## [0.4.419] - 2026-06-11

### Changed

- **Route-layer helper adoption completed.** Every web handler that resolved
  an assignment by public ID now goes through the shared `loadAssignment` /
  `loadAssignmentAndSetup` helpers (15 remaining inline lookup chains
  rewired); the per-student instructor pages share one
  `resolveStudentAssignmentAction` preamble and redirect helper instead of
  seven hand-rolled copies.
- **Remaining oversized route files split.** `WebRoutes+Submission.swift`
  (989 → 479 lines, result-presentation pipeline extracted to
  `SubmissionResultPresenter.swift`), `CourseBundleRoutes.swift` (801 → 346,
  import handler extracted), and
  `InstructorDashboardRoutes+Submissions.swift` (850 → 218, grades CSV and
  per-student actions extracted). The shared preferred-result fold moved to
  `Helpers/PreferredResultsBySubmissionID.swift`. Mechanical moves — no
  behavior changes.


## [0.4.418] - 2026-06-11

### Changed

- **Error vocabulary unified.** `WebAssignmentError` is now a typealias of
  `AppError` (its two extra cases folded in), and the bare-`Abort` clusters in
  the test-setup and assignment-edit routes were swept to typed errors. Status
  codes and user-facing messages are unchanged.
- **Oversized files split along their natural seams.** The worker daemon's CLI
  command, structured logging, and staging helpers moved out of
  `RunnerDaemon.swift` (894 → 474 lines); the pattern-family renderer split
  into one file per pattern kind plus a shared-template file (957 → 211 lines
  in the dispatcher) with generated script bytes verified identical by the
  existing renderer tests.
- The `PublishedAssignmentRoutes` handler cluster now resolves assignments and
  setups through the shared `loadAssignmentAndSetup` helper instead of
  repeating the inline lookup-and-404 chain.


## [0.4.417] - 2026-06-11

### Changed

- **Maintenance audit batch 4 (efficiency + drift fixes).** Hot-path query
  cleanups: vanity-URL assignment resolution filters by slug in SQL instead of
  fetching every assignment in the course; `nextAssignmentSortOrder` no longer
  loads every assignment to compute a max; admin course-copy probes all
  candidate `-COPY-n` codes in one query (was up to 10 round-trips, now
  pinned by a route test); the admin overview reuses one date formatter
  across course rows. Case-insensitive active-course-by-code resolution is
  consolidated into a shared `findActiveCourse(byCode:)` (was duplicated in
  the vanity-URL and student-history routes). The web "move to section"
  grading-mode sync now calls the same `setManifestGradingMode` helper as the
  MCP tool, so both paths emit identical sorted-key manifest bytes — the
  manifest-hash retest gate depends on that determinism. Worker workspace
  cleanup failures now emit a structured `workspace_cleanup_failed` log event
  instead of vanishing (silent disk leaks). The duplicated git-restore-mtime
  CI steps moved into one composite action.


## [0.4.416] - 2026-06-11

### Fixed

- **Admin page rendered raw HTML comment text** (regression in v0.4.415).  The `chickadee-ui.js` load comment in `base.leaf` contained `#import("content")` in its body; Leaf evaluated that as a live directive, injected the page HTML mid-comment, and the first `-->` in that content closed the comment early — leaving the remaining comment text visible on the page and duplicating the courses table.  Reworded the comment to avoid the `#` directive syntax.


## [0.4.415] - 2026-06-11

### Changed

- **Maintainability batch from the June 2026 audit.** Seven periodic services
  now share one `PeriodicSweepMonitor` instead of hand-rolled monitor
  scaffolds; submission status and user role comparisons are typed enums;
  the notebook working-copy filesystem logic moved into its own service (and
  the pre-v0.4 legacy notebook sweep runs once at boot instead of on every
  page view); a shared `Public/chickadee-ui.js` replaces ten drifted
  `escapeHtml` copies and seven CSRF readers; the four multipart body structs
  collapse into one per route via a `MultipartFileList` decoder.
- The BrightSpace grade-sync sweep batch-loads its lookups and dedupes pushes
  per (student, assignment) instead of issuing ~5 queries per pending result.
- `GET /api/v1/submissions` supports `limit`/`offset` (default 500, max 5000,
  newest first) instead of returning the entire table.


## [0.4.414] - 2026-06-11

### Changed

- **Grades are now denormalized onto the `results` table.** New
  `earned_points` / `total_points` / `pass_count` / `total_tests` columns
  (backfilled from the result blob in one migration statement) replace the
  per-row JSON decode on the student dashboard, instructor roster, grades CSV
  export, submission history, and the achievement / BrightSpace sweeps. The
  CSV export also chunks its result lookups, so term-scale exports no longer
  exceed database bind-parameter limits.
- The worker claim scan is capped at 50 candidates per group (fresh student
  work still beats retests), the achievement sweep batch-loads test setups and
  runs every 5 minutes instead of every minute, instructor-dashboard counts
  use SQL aggregates, and the per-claim test-setup zip hash is memoized.
- Worker script waits no longer block Swift concurrency pool threads
  (termination handlers / a dedicated wait thread), per-stream script output
  capture is capped at 1 MB, and the artifact download timeout was raised from
  15 s (which deterministically failed large setup zips) to 10 minutes.
- Six drifted per-template relative-time formatters were replaced by one
  shared `Public/relative-time.js`.

### Fixed

- **Concurrent submissions can no longer share an attempt number.** Attempt
  numbers are now assigned inside a transaction (`MAX + 1`, with a per-student
  advisory lock on Postgres), fixing corruption of the prior-attempt delta and
  the First-Try-Perfect badge.
- Persisting a worker result and marking its submission complete now happen in
  one transaction, so a failure between the two no longer strands a graded
  submission in `assigned` until the reaper regrades it.
- A worker job-payload decode failure (server/worker version mismatch) is now
  logged as `job_decode_failed` instead of masquerading as a transport error.
- The runner's test-setup cache reconciles with disk at startup, so entries
  surviving a restart are evictable again instead of accumulating in /tmp
  forever.


## [0.4.413] - 2026-06-11

### Security

- **Worker test scripts no longer inherit the daemon's environment.** Student
  test scripts now run with an allowlisted environment (`PATH`, `HOME`, `LANG`,
  `LC_*`, `TMPDIR`, … plus the per-job `CHICKADEE_*` overrides) instead of the
  worker's full environment, so a submission can no longer read
  `RUNNER_SHARED_SECRET` (or other daemon secrets) back out of its own output
  and forge HMAC-signed worker API requests. Covers sandboxed and unsandboxed
  runners on macOS and Linux.

### Changed

- **"Retest all" now uses a single bulk database UPDATE** instead of one write
  per submission, so re-queueing a deadline-day assignment no longer blocks the
  instructor's request on thousands of sequential saves.
- Added hot-path database indexes the audit found uncovered:
  `request_metrics(finished_at)` (the table had none), `submissions(submitted_at)`,
  `submissions(worker_id, status)`, `client_diagnostics(created_at)`, and
  `assignments(validation_submission_id)`.

### Fixed

- A failed per-student personalization-inputs write on the worker now reports
  the job as `buildStatus: failed` (retestable) instead of silently producing a
  confusing missing-file traceback that was persisted as the student's grade.
- Uploading a file on the new-assignment page no longer throws — the page now
  loads `suite-list.js` alongside `suite-table.js` (the file classifier it
  calls), and an unrelated use-before-declaration bug in the upload-merge helper
  is fixed.

### Removed

- Deleted the pre-v0.4.79 `resolveEditSuiteFiles` suite-rebuild chain and the
  superseded in-browser Pyodide grading engine in `notebook.js` (both dead;
  grading runs through the shared RunnerCore path).


## [0.4.412] - 2026-06-10

### Security

- **Instructor web access is now enrollment-scoped.** The shared course
  guard (`requireCourseEnrollment`) no longer waves instructors through:
  like students, they must be enrolled in the course that owns the content.
  Previously any instructor account could fetch another course's notebook
  and test setup — including secret tests and the reference solution — by
  URL, even though the dashboard never showed it. Admins keep the bypass
  (they administer the deployment and can grant themselves enrollment);
  their MCP agents remain enrollment-scoped, so agent scope stays a subset
  of human scope for every role.


## [0.4.411] - 2026-06-10

### Security

- **MCP admin agents are now enrollment-scoped.** An agent token authorized by
  an admin can act only on the courses that admin is enrolled in — the same
  rule every other account already had — instead of every course on the
  deployment. Enrolling widens an agent's reach; unenrolling revokes it on the
  agent's next call. Archived courses are likewise hidden from the agent's
  `list_courses` / `resources/list` view, matching the dashboard. The
  dashboard tab strip and the MCP listing now share one visibility resolver
  (`enrolledCourses`), and the web guard and MCP authorization share one
  enrollment predicate (`userIsEnrolled`), so the user view and the agent
  view can no longer drift. Existing admin agents that relied on global
  reach must enroll the admin account in the relevant courses.


## [0.4.410] - 2026-06-10

### Fixed

- **Extension/override popover no longer cut off at the screen edge.** On the
  instructor's per-student submissions page, the deadline-extension and
  grade-override panels were anchored to the left edge of their toolbar button
  and opened rightward — after more action buttons were added, the panel
  extended past the viewport and the date field and Save button were clipped.
  The panel now opens leftward from the button's right edge and is capped to
  the viewport width.


## [0.4.409] - 2026-06-10

### Added

- **Authoring guides exposed as MCP resources.** The per-student
  solution-notebook recipe is now readable by connected agents at
  `chickadee://docs/personalization-solution-notebooks`, and the MCP server
  instructions point at that resource instead of a repo path the agent cannot
  fetch. The Docker image now ships `docs/` and the entrypoint syncs it to the
  data volume alongside Public/ and Resources/.


## [0.4.408] - 2026-06-10

### Added

- **MCP tools advertise display titles.** Every entry in `tools/list` now
  carries a human-friendly `title` (derived from the tool name, e.g.
  `get_server_info` → "Get Server Info") so MCP clients can render readable
  names instead of snake_case identifiers.


## [0.4.407] - 2026-06-10

### Added

- **Startup warning for an unguarded MCP transport.** Mounting `/mcp` in
  production with `MCP_ALLOWED_HOSTS` / `MCP_ALLOWED_ORIGINS` unset now logs a
  warning naming the unset variable(s) — an empty allowlist disables the
  corresponding Host/Origin DNS-rebinding guard — instead of silently
  accepting any value. Development and testing stay quiet, where empty
  allowlists are the normal default.

### Changed

- **MCP `initialize` now negotiates the protocol version and logs the
  client's identity.** A supported requested revision (2025-06-18 or
  2025-11-25) is echoed back per the lifecycle spec; an unsupported one gets
  the latest the server speaks. The connecting client's `clientInfo`
  name/version and the negotiated revision are logged for operational
  visibility into which agents talk to the server.


## [0.4.406] - 2026-06-10

### Added

- **MCP list pagination.** `tools/list` and `resources/list` now honor the
  spec's cursor-based pagination: results carry a `nextCursor` when more pages
  remain (page size 100), and an unparseable `cursor` is rejected with
  `-32602` instead of being silently ignored. Today's 34-tool catalog still
  fits one page; the resource listing (one entry per accessible assignment)
  is what this protects on large deployments.


## [0.4.405] - 2026-06-10

### Added

- **MCP instructions/catalog drift guard.** New tests assert every tool in the
  live MCP catalog is mentioned in the server-level `initialize` instructions
  and declares a description, an object `inputSchema`, an `outputSchema`, and
  annotations consistent with its required scopes — turning the "keep the
  agent-facing copy in sync with the catalog" convention into a build failure.

### Fixed

- **MCP transport now validates the `MCP-Protocol-Version` header.** A request
  declaring a protocol revision the server does not speak (anything other than
  2025-11-25 or 2025-06-18) is rejected with HTTP 400 per the Streamable HTTP
  transport spec, instead of being silently served. Requests without the
  header remain accepted — `initialize` is sent before negotiation, and older
  clients never send it.


## [0.4.404] - 2026-06-10

### Fixed

- **Slow editor boots no longer aborted by the locked-path enforcement.** On
  the student notebook page, `enforceLockedNotebookPath()` treated an iframe
  that hadn't committed its first document yet (`location.href` still
  `about:blank`) as "student navigated away" and force-reset `frame.src` —
  with only a 1-second debounce against the 1.5-second enforcement interval.
  Any boot where the JupyterLite `index.html` took longer than ~1.5s to commit
  (slow connection, or the server busy with a class-wide 8am rush) was aborted
  and restarted indefinitely, so the shell never appeared and the phase-1
  watchdog fired `watchdog_timeout` on a healthy-but-slow boot — the students
  behind the "Students With Browser Errors" dashboard card. Enforcement now
  waits for the first committed document before acting, gives a forced reset a
  generous window to commit (cleared by the iframe load event) before forcing
  another, and `mountEditor()` no longer re-assigns the identical `src` the
  template already rendered (which aborted and restarted the eager initial
  load on every page view).

### Changed

- **Vendored editor assets skip the session middleware chain and the
  content-hashed JupyterLite bundle is cached immutably.** A JupyterLite boot
  fetches hundreds of static files, each of which previously paid a Fluent
  session lookup before FileMiddleware served it — the load that drives
  editor `index.html` latency up during a class-wide rush. The new
  `EditorAssetFastPathMiddleware` serves a strict whitelist of vendored trees
  (`/jupyterlite/build`, `/jupyterlite/extensions`, `/pyodide`, `/vendor`)
  ahead of the session chain; the auth-guarded `/jupyterlite/…/files/users/`
  paths are deliberately not on the fast path and still ride the full chain
  (pinned by a regression test). Webpack content-hashed bundle filenames get
  `Cache-Control: public, max-age=31536000, immutable`, eliminating the
  per-boot revalidation storm; unhashed names and all of `/pyodide` +
  `/vendor` keep ETag revalidation because re-vendoring rewrites those bytes
  in place under stable names.


## [0.4.403] - 2026-06-10

### Changed

- **CI images mirrored to GHCR; superseded PR runs cancelled.** The
  swift/postgres job containers are now pulled from a GHCR mirror
  (refreshed weekly by `mirror-images.yml`) instead of Docker Hub, whose
  unauthenticated rate-limited pulls were the largest source of red CI on
  main (6 docker-pull timeouts in the three-week #890 audit window).
  `swift-tests.yml` also gained a `concurrency` group that cancels
  superseded runs on PR branches (pushes to main and merge-queue runs are
  unaffected).


## [0.4.402] - 2026-06-10

### Fixed

- **Scheduled open date now publishes Preview assignments.** The scheduled-open
  sweep only auto-opened `.closed` assignments, so an assignment left in the
  staff-only Preview state silently sailed past its open date and never reached
  students (this is what kept a lab from opening at its scheduled 8am). Preview +
  open date is the intended workflow — staff test now, students get it when the
  date arrives — so the sweep now publishes Preview assignments too, with the
  same guards as before (validation must have passed, the due date must not
  already be behind us).


## [0.4.401] - 2026-06-10

### Fixed

- **WorkerTests de-flaked.** A three-week CI audit showed ~85% of genuine
  worker-test failures were one mechanism: trivial `/bin/sh` scripts in
  `WorkerTests.swift` hitting their 5 s script time limit on CPU-starved
  runners. Those limits (which only bound a hang) are now 60 s, and the
  kill-path latency assertions are correspondingly relaxed. The second
  pattern — `Process.run()` transiently failing under fork pressure with a
  misleading "file doesn't exist" error — is fixed by a shared
  `runProcessRobustly` helper that launches bare `Process` spawns under the
  subprocess throttle and retries failed launches; the `LocalHTTPTestServer`
  factories, the daemon tests' zip builder, and the Rscript probe now all
  honor the throttle they were documented to use. Also: the three
  worker-secret tests no longer `chdir` the whole process
  (`resolveWorkerSharedSecret` / `defaultWorkerSecretFilePaths` take an
  injectable `currentDirectory`), the mock URLSession timeout no longer
  gates passing runs, and the `worker-tests` CI job caps Swift Testing
  parallelism at 4 like the APITests jobs.


## [0.4.400] - 2026-06-10

### Removed

- **Dead `Public/setup-edit.js` deleted.** The legacy Phase-8 "Save notebook…"
  script was no longer loaded by any template (the JupyterLite draft flow
  replaced it) and its `PUT /api/v1/testsetups/:id/assignment` call carried no
  CSRF token, so it could never have succeeded anyway — flagged by the #883
  CSRF audit. Comments listing it as a Pyodide consumer updated to match.


## [0.4.399] - 2026-06-10

### Fixed

- **CSRF no longer rejects form POSTs whose body arrives as a stream.** Vapor
  only delivers a pre-collected body when the entire body lands in the same
  channel read as the request head; a form POST split across TCP reads (routine
  on real networks/proxies, and guaranteed for chunked transfer-encoding) was
  dispatched to the CSRF middleware with a still-streaming body, so the
  synchronous `_csrf` body read failed and the request 403'd
  "No CSRF token provided." even though the field was on the wire — the
  intermittent, production-only failure behind the TA's extension-grant report
  (#868). The token retrieval now collects the body (same size cap as the
  route's own collect step) before reading the field, and a live-socket
  regression test pins the streamed-body path.


## [0.4.398] - 2026-06-10

### Removed

- **Achievements unification (D): retired the legacy editor endpoints + JS.**
  With the single Achievements table live, the per-card endpoints
  (`/instructor/:id/badges` and `/instructor/:id/built-in-awards`) and their JS
  (`class-goals-editor.js`, `badges-editor.js`, `builtin-awards-editor.js`) are
  removed. Authoring is now exclusively the unified `GET`/`PUT /achievements`.
  The evaluation logic, the `/achievements` legacy `goals` back-compat, and the
  disabled-built-in honoring are unchanged. This completes the unification:
  one `Achievement` model, one endpoint, one editor table.


## [0.4.397] - 2026-06-10

### Added

- **MCP `update_pattern_family` can now grow and re-wire a family in place.** The
  tool gained `addCases` (append brand-new cases to an existing pattern family;
  keys must not collide with an existing case) and `dependsOn` (replace the
  family's prerequisites — script filenames or `family:<id>` tokens, `[]` to
  clear). Previously an agent had to delete and recreate a whole family just to
  add coverage or drop a redundant prerequisite, which the safety classifier
  rightly blocks as destructive. Case-building logic is now shared with
  `create_pattern_family` so the two tools can't drift, and the response reports
  the appended `addedCaseKeys`.


## [0.4.396] - 2026-06-10

### Changed

- **Achievements unification (C2): one "Achievements" table.** The three separate
  editor cards (Class Goals, Badges, Built-in Awards) are replaced by a single
  "Achievements" table at the bottom of the assignment edit page (after the Test
  Suite). Each achievement — class goals, individual badges, and the built-in
  awards — is a first-class editable row (Name / Kind / Summary / Edit / Remove);
  a row is edited in a modal whose fields adapt to the chosen kind. Driven by the
  unified `GET`/`PUT /achievements`. No custom icons.


## [0.4.395] - 2026-06-10

### Changed

- **Achievements unification (C1): seed-on-first-save for the unified editor.**
  `TestProperties` gains `builtInAchievementsSeeded`. Until an instructor first
  saves the unified Achievements table, `GET /achievements` merges the built-in
  defaults into the rows so they appear as editable defaults; the unified `PUT`
  marks the manifest seeded, after which it is authoritative (a removed built-in
  stays removed). The flag survives suite rebuilds.


## [0.4.394] - 2026-06-09

### Changed

- **Achievements unification (B): one typed `/achievements` endpoint.**
  `GET`/`PUT /instructor/:id/achievements` now round-trips the whole typed
  `Achievement` list — every kind (class goals, threshold/test badges, class
  records, and the per-submission kinds) — via an `achievements` field with
  per-kind validation. The legacy `goals` shape still works (replaces only the
  class-goal subset), so the existing Class Goals card is unaffected until the
  unified editor table lands.


## [0.4.393] - 2026-06-09

### Changed

- **Achievements unification (A3): class-record awards are manifest-driven.**
  `awardClassBadgesFor100Percent` and the Pathfinder award iterate the assignment
  manifest's authored `classRecord` achievements by `recordDimension`
  (firstToSolve / fastest / shortest / new firstToSubmit), falling back to the
  built-in registry. Behavior-identical until a manifest authors class records.
  The new `firstToSubmit` dimension distinguishes Pathfinder (first to submit)
  from Trailblazer (first to solve).


## [0.4.392] - 2026-06-09

### Changed

- **Achievements unification (A2): per-submission badges are manifest-driven.**
  `forSubmission` now sources the per-submission badges (Ace / Rally / Tenacious
  / Swift) from the assignment manifest's authored achievements when present,
  falling back to the built-in registry otherwise — wired at all three display
  sites (submission page, course history, student dashboard). Behavior-identical
  until a manifest carries per-submission achievements (the editor + seeding land
  later in the rollout); the parameterized thresholds then take effect.


## [0.4.391] - 2026-06-09

### Added

- **Per-assignment built-in award toggles.** A "Built-in Awards" card on the
  assignment edit page lists Chickadee's built-in awards — the per-submission
  Ace / Rally / Tenacious / Swift and the competitive Pathfinder / Trailblazer /
  Fastest / Minimalist class records — with an on/off switch each. Disabling one
  (e.g. turning the competitive class records off for a collaborative course)
  stops it being awarded and hides it on the submission page, history, and
  dashboard. Persisted in the manifest as `disabledBuiltInAwardIDs`.

### Fixed

- **Authored achievements no longer survive only until the next suite edit.**
  The suite-rebuild path (`makeWorkerManifestJSON`) built a fresh manifest that
  dropped the `achievements` array, so authoring a class goal or badge and then
  editing the test suite silently wiped it. The rebuild now preserves
  achievements (and the new built-in-award toggles).


## [0.4.390] - 2026-06-09

### Fixed

- **Validation grading no longer races the worker.** The substituted
  reference-solution notebook (and its cached personalization values) is now
  written *before* the validation submission is saved as `pending`, so a
  fast-polling worker can't claim and download the un-substituted `{{...}}`
  template in the window before materialization finishes. Previously a
  personalized assignment could intermittently fail its own answer-key checks
  ("variable not defined") even though the timeout regression was fixed.


## [0.4.389] - 2026-06-09

### Fixed

- **Reference-solution personalization no longer times out the runner.** A
  validation submission's `{{name}}` placeholders and `=` expressions are now
  resolved **once at enqueue** and cached — the substituted answer-key notebook
  to a `<submission>.grading` sidecar, the expression values onto the submission
  row — so the worker poll and artifact-download routes stay pure I/O. Previously
  (v0.4.388, #869) the download handler ran a `python3` subprocess inline, which
  the runner's 5 s download timeout tripped (`NSURLErrorTimedOut` / `-1001`),
  surfacing as a spurious "Build failed" on any personalized assignment graded
  via the worker (including browser-graded assignments validated through the
  worker backstop). The answer-key notebook, `_ck_inputs.py`, and
  `CHICKADEE_ASSIGNMENT_SEED` now all derive from one seed.


## [0.4.388] - 2026-06-08

### Added

- **Reference-solution notebooks are now personalized like the starter.** A
  validation (solution) notebook's `{{name}}` placeholders are substituted at
  worker download using the same per-(student, assignment) seed the worker uses
  for `_ck_inputs.py`, so the answer key resolves the same per-student values the
  grader expects. This makes a per-student **variable** answer (e.g.
  `shift = {{shift}}`) a first-class, validatable pattern — previously only a
  seed-reading *function* could survive the notebook extractor's import-time
  quarantine. The stored solution keeps its `{{…}}` template, so `get_solution`
  and re-validation by any user still work. New doc:
  `docs/personalization-solution-notebooks.md`; the MCP `initialize`
  instructions and `update_solution` description now spell out the quarantine
  rule and the two supported ways a solution produces a per-student value.


## [0.4.387] - 2026-06-08

### Fixed

- **CSRF "No CSRF token provided" failures are now observable and recoverable.**
  CSRF rejections previously threw a bare 403 with no server-side log, making
  production failures impossible to diagnose. The app's CSRF middleware now
  emits a structured `csrf_token_missing` log line (method, path, content-type,
  content-length) when a token never reaches the server, and browser users see
  an actionable "go back, reload, and try again" message instead of a cryptic
  dead-end. Added regression tests covering the per-student extension form's
  real-page token and course codes containing spaces.


## [0.4.386] - 2026-06-08

### Changed

- **Secret-test counts are now shown per section on the submission page.**
  Instead of one aggregate "Secret tests" block at the bottom, each test-suite
  section shows its own hidden-test pass/fail summary, so a student can see
  *which question's* secret tests are failing without revealing the tests
  themselves. Release tests were already itemized in their section; secret
  tests now follow the same sectioning. Assignments with no sections keep the
  single summary under the one table.


## [0.4.385] - 2026-06-08

### Changed

- **Folded the legacy awards into the unified Achievement model.** The
  previously-hardcoded badges — the per-submission Ace / Rally / Tenacious /
  Swift and the Pathfinder / Trailblazer / Fastest / Minimalist class records —
  are now defined as `Achievement` instances in one registry
  (`BuiltInAchievements`), and the display badge is derived from the model
  (`AchievementBadge(from:)`, shared with the authored individual badges). New
  `comeback` / `persistence` / `speedRun` achievement kinds give the three
  per-submission badges a model home alongside `firstTryPerfect`. Behaviour is
  unchanged — the award conditions and the class-record award logic are
  identical; only the source of each award's identity moved into the model, so
  there is now exactly one place that defines what "Ace" or "Trailblazer" is.


## [0.4.384] - 2026-06-08

### Added

- **Authorable individual badges (achievements Phase 4).** Instructors can now
  author per-student badges on the assignment edit page — a "Badges" card where
  each row is a caption, an emoji, and the condition that earns it: a score
  threshold ("Score ≥ 90% → Sharpshooter") or a specific test passing ("a secret
  test passes → Recursion Master"). Earned badges show on the student's
  submission. Cosmetic (no grade effect), evaluated per-student from their own
  result — and the evaluation reads every tier, so a badge keyed to a *secret*
  test works without revealing the test. Persisted via `PUT /instructor/:id/badges`.


## [0.4.383] - 2026-06-08

### Added

- **Class-goal grade bonus (achievements Phase 3b).** When the class reaches a
  goal, every student who submitted earns the goal's points as **extra credit,
  capped at 100%**, scaled by how far the class got — applied at the
  grade-of-record sites: the submission page, the BrightSpace grade push, and
  the grades CSV. Purely positive (never lowers a grade); an instructor grade
  override still wins; a no-op for assignments without a points-rewarded class
  goal. This completes the class-goals feature: author → evaluate → display →
  grade.


## [0.4.382] - 2026-06-08

### Added

- **Author class goals from the assignment editor (achievements Phase 5).** A
  new "Class Goals" card on the instructor assignment edit page lets you add
  class-wide goals — a name, a per-student grade threshold, the share of the
  class that must reach it, and the bonus points everyone who submitted earns —
  persisted to the manifest via `PUT /instructor/:id/achievements`. Class goals
  are display-only, so saving doesn't retest submissions or re-validate. The
  student progress bar (Phase 3a) and the grade bonus (Phase 3b) read these.


## [0.4.381] - 2026-06-08

### Added

- **Class goals shown to students (achievements Phase 3a).** The submission page
  now renders an "Achievements" section with a live progress bar for each class
  goal — e.g. "80% of the way · 41 / 64 students", the reward, and a "Reached!" /
  "final" state — read from the Phase 2 snapshots. Display only; the positive
  grade bonus these goals award lands in Phase 3b.


## [0.4.380] - 2026-06-08

### Added

- **Class-goal evaluation engine (achievements Phase 2).** A periodic server-side
  sweep (`evaluateClassGoalAchievements`, lifecycle-registered alongside the
  other monitors) computes, for each assignment carrying a `classGoal`
  achievement, how much of the enrolled class has reached the goal's threshold,
  and upserts a snapshot per (assignment, goal) into a new `achievement_results`
  table. It reads worker-authoritative results over the canonical
  enrolled-student roster, and locks — then freezes — each snapshot once the
  deadline passes. Not yet surfaced: the student progress bar and the positive
  grade bonus that read these snapshots land in Phase 3.


## [0.4.379] - 2026-06-08

### Fixed

- **Browser-wasm re-vendor no longer loses the post-merge push race.** The
  `runner-wasm-vendor.yml` job rebuilds the in-browser grading wasm whenever
  RunnerCore changes on `main` and pushes the artifact back — but
  `auto-release.yml` pushes its `chore(release)` commit to `main` in the same
  post-merge window, and the slower wasm job lost a plain `git push` on every
  RunnerCore-touching merge, leaving the re-vendor unpushed until a manual
  re-trigger. It now rebases its artifact-only commit onto the latest `main`
  and retries (up to 5×), so the artifact lands on its own.


## [0.4.378] - 2026-06-08

### Added

- **Achievements model (foundation).** A per-assignment `achievements: [Achievement]`
  manifest field (Core) — the generalized, instructor-authorable form of
  Chickadee's previously-hardcoded badge / class-achievement system. One
  `Achievement` expresses the collaborative class goal, individual badges
  (incl. First-Try Perfect), and the legacy one-holder class records, by
  `kind`. Server-evaluated and display-only; stripped from the runner-facing
  manifest like pattern families and notebook checks. Groundwork only —
  evaluation, the class-goal grade bonus, student display, and authoring land
  in follow-ups.


## [0.4.377] - 2026-06-08

### Fixed

- **Preview assignments with a scheduled open date are reachable by staff
  again.** A `.preview` assignment that also carried a future open date
  (`startsAt`) was held closed for *everyone* by the front gate in
  `isAssignmentOpenForUser` — so the instructor who put it in preview to test it
  couldn't open the notebook or submit (worse for browser-graded labs, where no
  upload fallback exists, leaving the row with no actions at all). Staff now
  bypass the future-open-date gate when previewing; the date still governs when
  the assignment auto-publishes to students, and students remain blocked. The
  preview/start-date decision is now a single `AssignmentVisibility.submissionGate`
  helper shared by the submission gate and the dashboard listing.


## [0.4.376] - 2026-06-08

### Changed

- UI consistency: the three submission-history tables now use icon action
  buttons (view-results / download / open-in-notebook for students; view /
  re-test for the instructor per-student drilldowns), matching the assignment
  list, roster, and student-dashboard rows that were already iconified. Each
  glyph keeps a `title` + `aria-label` for accessibility.


## [0.4.375] - 2026-06-07

### Added

- **Per-test partial credit (fractional `score`).** A test script's stdout JSON
  footer `score` (0…1) is now honoured: a test's earned grade is `points × score`
  instead of all-or-nothing. With no footer `score` a test still scores 1 on a
  pass and 0 otherwise, so existing suites grade exactly as before. The logic
  lives in the shared RunnerCore `interpretScriptOutput`, so the native worker
  and the in-browser wasm runner apply identical partial credit, pinned against
  both by `Tests/Fixtures/output-contract.json`. Browser-graded submissions now
  also grade with the instructor's weighted `points` (previously unweighted),
  recomputed server-side; the in-browser artifact emits `score` on the next
  RunnerCore re-vendor.


## [0.4.374] - 2026-06-07

### Changed

- **Test-suite editor: author tests inline.** The instructor assignment editor
  replaces the in-modal test-type picker with a **"+ Add Test" dropdown** on
  each section, and pattern families and notebook checks are now edited
  **inline in expandable rows** (Save/Cancel in place) rather than in a modal —
  only custom scripts still open the code editor. Notebook-check rows also gained
  inline tier/points editing. One editor is open at a time; a debounced suite
  save can't wipe an open editor (the table defers its re-render until the editor
  closes). MCP `create_pattern_family` / `update_pattern_family` descriptions and
  the server instructions now note the auto-generated existence guard that
  function-calling families carry.


## [0.4.373] - 2026-06-07

### Added

- **Automatic existence guards for pattern families.** Every function-calling
  pattern family (`boundary_equality`, `approximate_equality`,
  `return_type_check`, `exception_expected`, `performance_threshold`,
  `stdout_equality`, `unordered_equality`) now auto-generates one 0-point
  `… is defined` guard test; its cases `dependsOn` the guard, so a missing or
  non-callable target produces a single clear "`fn` is not defined" failure and
  the cases auto-skip through the runner's dependency gate — instead of N opaque
  `AttributeError` tracebacks. `variable_equality` is unchanged (it already
  self-guards each case). The guard is internal: it collapses into the family
  row in the suite editor and is reserved against the case key `exists`. No
  runner changes — the guard is an ordinary generated test and the gating reuses
  the existing `dependsOn` machinery.

### Fixed

- **0-point test entries now round-trip.** `makeWorkerManifestJSON` only
  serialized `points` when greater than 1, so a 0-point entry decoded back to
  the default of 1 and silently started counting toward the score. Any non-1
  value (including 0) is now written explicitly.


## [0.4.372] - 2026-06-07

### Fixed

- **Student-dashboard assignment table single-line polish.** The staff-only
  status badge now reads "preview" and stays on one line instead of wrapping to
  two, and the Actions cell keeps its icon buttons on a single row (matching the
  tighter instructor assignments view) rather than wrapping.

### Fixed

- **Audit-log "Actor" filter no longer offers credential autofill.** The field
  is now `autocomplete="off"` like the other admin filter inputs. A site-wide
  default was also added (`app.js`): forms that don't opt into autocomplete and
  carry no password field now default to `autocomplete="off"`, so stray
  username/password autofill prompts stop appearing on non-credential forms
  across the app. Login/register/admin-secret forms opt their fields in
  explicitly and are unaffected.

### Changed

- **Assignment editor: "Add Support File" and "Add Input" moved above their
  tables.** Both now sit in a header bar beside a heading ("Files" /
  "Global Inputs"), mirroring the Test Suite section header, instead of being a
  trailing table row — which also frees two rows from the table area. The
  Global Inputs table drops its redundant "Global input" label column so the
  value field gets that horizontal space.


## [0.4.371] - 2026-06-06

### Added

- **Responsive web UI for phones and tablets.** Summary/list pages (student and
  instructor dashboards, submission history) hide non-essential columns on small
  screens; the per-student extension / grade-override flow is usable on a phone;
  dense admin tables (runner, audit) scroll horizontally; and the notebook editor
  is gated to tablet-and-up with an "open on a larger screen" notice on phones.
  Built intrinsic-first (`min()` / `clamp()` containers, viewport breakpoints only
  where needed) so the desktop layout is unchanged. See
  `docs/responsive-design-plan.md`.


## [0.4.370] - 2026-06-06

### Changed

- **Removed the separate "Validate & open" page.** Validation is tied to saving
  an assignment (creating or editing it auto-runs validation), so the
  `/instructor/:id/validate` page and every link to it are gone. The legacy
  "Publish…" action now opens the editor to finalize the draft. On the
  instructor dashboard, a staff-only (preview) assignment now shows the normal
  published-assignment actions (copy link / edit / retest / delete) instead of a
  stray "Validate & open" button, and on the main page it shows a single
  "staff only" pill rather than both "open" and "staff only".


## [0.4.369] - 2026-06-06

### Fixed

- **Assignments now auto-close at their deadline even when a student has an
  active extension.** The deadline sweep was refusing to close the
  assignment-wide window whenever any per-student extension (e.g. an
  AccessAbility accommodation) was still active, so an assignment with any
  extension appeared never to close — it kept reading as "open" on the
  instructor dashboard and in every student's list past its deadline. The
  assignment-wide visibility now always closes at the deadline; per-student
  access is preserved downstream as designed — the submission gate
  (`isAssignmentOpenForUser`) keeps submitting open for a student whose
  extension is still in the future, and the student dashboard re-includes
  setups where the viewer holds an active extension.


## [0.4.368] - 2026-06-06

### Security

- **Browser-runner endpoints gated on assignment visibility, not just
  enrollment.** `GET /api/v1/browser-runner/testsetups/:id/{download,manifest,seed}`
  previously checked only course enrollment, so an enrolled student who supplied
  a `testSetupID` could pull a closed, not-yet-opened, or staff-only (preview)
  assignment's test scripts and — via the seed endpoint — its per-student
  resolved personalization values, which can encode solution-derived expected
  answers. All three now require the assignment to be effectively open for the
  caller (staff bypass), falling back to the enrollment check only when no
  assignment owns the setup. Regression tests cover the closed-student-blocked
  and preview-staff-visible cases.

### Fixed

- **`create_pattern_family` (MCP) advertises `unordered_equality`.** The tool's
  input-schema `kind` enum, its description, and the `initialize` server
  instructions omitted the `unordered_equality` kind, so an agent validating
  against the schema couldn't author one even though the handler accepted it.


## [0.4.367] - 2026-06-06

### Changed

- **Script create/delete CRUD shared across published and draft routes.** The
  per-file create and delete logic — filename sanitization, duplicate-name and
  pattern-family guards, variable inlining, zip write/remove, and manifest
  update — was copy-pasted between `PublishedAssignmentRoutes+ScriptCRUD` and
  `DraftAssignmentRoutes+SuiteEditing`. It now lives in shared cores
  (`createScriptInSetup` / `deleteScriptFromSetup` in `ScriptCRUDHelpers`), with
  a shared `CreateScriptBody`. The published handlers keep their support-file
  re-extraction and `editURL`; the draft handlers, which have neither students
  nor a stable route yet, keep neither. No behaviour change (net ~130 fewer
  lines in the handlers).


## [0.4.366] - 2026-06-06

### Changed

- **Test-suite section CRUD shares one implementation across published and
  draft.** The create / rename / delete / reorder manifest mutations were
  copy-pasted between `PublishedAssignmentRoutes+SuiteSections` and
  `DraftAssignmentRoutes+Sections`; they now call shared cores
  (`createSuiteSectionCore` / `renameSuiteSectionCore` / `deleteSuiteSectionCore`
  / `reorderSuiteSectionsCore`) in `SuiteEditHelpers`. The handlers keep only
  their setup resolution and redirect target. No behaviour change.

### Fixed

- **Draft section variables now support per-student expressions.** The draft
  section-variables endpoint had drifted from its published sibling: it
  hand-rolled validation and silently dropped any `expressions` the editor sent.
  It now routes through the same `SectionInputsService.apply` path, gaining
  expression support plus the shared validation (reserved-`seed` name,
  cross-scope clash). The save-time expression eval correctly no-ops on a draft
  (no assignment seed yet) and first runs when the assignment is published.


## [0.4.365] - 2026-06-06

### Changed

- **MCP tool layer consolidation.** Extracted the assignment-resolution
  prologue (`requireAssignment` / `authorizedAssignment` /
  `authorizedAssignmentAndSetup` on `ToolContext`) and the post-edit finalize
  sequence (`applySuiteEditMapped` / `finalizeContentEdit` in
  `ContentEditClose`) that ~20 MCP content tools had copy-pasted. The
  close→retest→revalidate ordering and the per-tool error strings now live in
  one place each instead of being a copy-paste convention. No behaviour change
  (net ~290 fewer lines).
- **Shared base64url + notebook-shape helpers.** The four hand-rolled base64url
  encoders (SSO/PKCE, OAuth, ES256 JWT, BrightSpace HMAC) now share
  `Data.base64URLEncodedString()` / `String.base64ToBase64URL()`, and the
  notebook `cellCount` / `validateNotebookShape` helpers duplicated across five
  MCP tools are now shared. Identical output.

### Fixed

- **New-assignment publish due date now uses the Waterloo timezone.** The draft
  publish path parsed a no-seconds `datetime-local` value in the server's
  default zone instead of `America/Toronto`, shifting the due date by the UTC
  offset; it now reuses the shared `parseDueDate` parser like the edit form.


## [0.4.364] - 2026-06-05

### Changed

- **MCP authoring steers agents toward native check types.** The server
  `initialize` instructions, the `author_script` tool description, and the
  `create_pattern_family` / `author_notebook_check` descriptions now frame
  hand-written scripts as a last-resort escape hatch and point agents at pattern
  families and notebook checks — which are validated structurally on save,
  personalize per student, and can be read back via `get_suite` — for graded
  tests. Guidance copy only; no behaviour or schema change.


## [0.4.363] - 2026-06-05

### Fixed

- **Personalization / suite edits on a brand-new assignment no longer fail with
  an opaque error.** When a test setup had no files yet — e.g. attaching global
  inputs (a personalized fortune) to a fresh notebook assignment before
  authoring any test — the save threw an internal error. `repackZipFromDirectory`
  shelled out to `zip -r .`, which aborts with "Nothing to do!" (exit 12) on an
  empty directory, and that raw error escaped `update_global_inputs`'s
  error mapping. It now emits a valid empty archive instead, so an empty test
  suite is a legitimate state. (Workaround until now: author one test before
  adding personalization.)


## [0.4.362] - 2026-06-05

### Changed

- **Preview assignment visibility simplified to "Open, but staff-only."** A
  Preview assignment now behaves exactly like an Open one for course
  staff/admins (bundled solution and tests, normal grading, editable notebook,
  normal submissions) while appearing **Closed** to students. Switching an
  already-validated assignment to Preview is a pure visibility change — it no
  longer re-validates, asks for a reference-solution upload, or closes the
  assignment, and it can be set to/from any state. Staff see a subtle
  "staff-only" marker on the dashboard; students see no Preview badge. Removed
  the separate `preview` submission kind (staff submissions behave like any
  other), so no behaviour of Open assignments changed.


## [0.4.361] - 2026-06-05

### Fixed

- **Editing a test suite re-grades existing submissions again.** The live suite
  editor (`PUT /instructor/:id/suite`) stopped re-queuing student submissions
  when suite editing moved off the Save button (the v0.4.93 auto-retest only
  fired on the now-suite-free Save path). It once more automatically re-grades
  every existing student submission against the edited suite — gated on a real
  manifest change — so prior grades no longer silently reflect the old tests.
  The same gated helper backs the new MCP auto-re-grade, so the human and agent
  paths stay in lockstep.
- **MCP: `create_pattern_family` and `delete_suite_item` now close an open
  assignment on edit.** Both change what the suite grades but previously left an
  open (or preview) assignment open during the asynchronous re-validation
  window, letting students submit against a not-yet-revalidated suite. They now
  close the assignment and report `assignmentClosed`, matching every other
  content-edit MCP tool and the web Save button.

### Added

- **MCP course-section management.** New `rename_course_section`,
  `delete_course_section`, and `reorder_course_sections` tools complete the
  course-section CRUD an agent can perform (creation and assignment already
  existed), mirroring the instructor dashboard handlers.
- **MCP `set_grading_mode`.** Directly set an assignment's grading path
  (`worker`/`browser`) by public ID, instead of only as a side-effect of moving
  it into a course section. Changing the path does not re-grade, re-validate, or
  close the assignment.
- **MCP `author_notebook_check`.** Create or replace a notebook check (all ten
  `NotebookCheckKind`s — DataFrame shape/columns/equality, figure count, AST
  structure, …) by id, through the same validated `applySuiteEdit` path the web
  editor uses. Agents could already read, move, and delete checks but not author
  them.
- **MCP content edits auto-re-grade existing submissions.** After an agent edits
  a suite, pattern family, notebook check, or script, every existing student
  submission is automatically re-queued for grading against the new suite — the
  automatic equivalent of the instructor "Retest all" button. Gated on a real
  manifest change (so no-op edits don't fan out) and idempotent against in-flight
  retests. Pure placement edits (`move_suite_item`) and metadata edits
  (`set_grading_mode`, section organization) do not re-grade.

### Changed

- **BREAKING (MCP): suite-section tool names are now explicit.** `create_section`
  / `rename_section` / `delete_section` → `create_suite_section` /
  `rename_suite_section` / `delete_suite_section`, and `set_assignment_section` →
  `set_assignment_course_section`, so the test-suite-section tools and the
  course-section tools are unambiguous at a glance (e.g. `create_suite_section`
  vs `create_course_section`). The MCP authoring surface has no external
  consumers yet, so no migration is provided.

- **MCP grading-mode reporting is consistent.** `set_assignment_course_section` now
  reports a missing manifest `gradingMode` as `"worker"` (matching
  `get_assignment` and `TestProperties`' default) instead of null.
- **MCP docs/instructions refreshed.** The `initialize` instructions now list
  `create_pattern_family`, `delete_suite_item`, `author_notebook_check`,
  `set_grading_mode`, and the course-section tools in the recommended workflow;
  `docs/mcp-authoring-roadmap.md` lists the full thirty-four-tool catalog.


## [0.4.360] - 2026-06-04

### Added

- **MCP pattern families can now set instructor hints.** `create_pattern_family`
  and `update_pattern_family` accept a family-wide `defaultHint` and a per-case
  `hint` (per-case overrides the family default; on update an empty string clears
  a hint and nil leaves it untouched). The hint surfaces to the student as a
  "💡 Hint" only on a failing case via the existing display-time
  `resolvedHint(defaults:)` join — nothing is baked into the generated script.
  `get_suite` already returns these in the `family` spec. Previously the fields
  were manifest-authorable (since v0.4.94) but had no agent surface, so hints
  authored through MCP were silently dropped.


## [0.4.359] - 2026-06-04

### Added

- **MCP section-management tools.** The content-authoring MCP server can now
  organize both tests and assignments. `create_section` / `rename_section` /
  `delete_section` manage an assignment's test-suite display sections, and
  `move_suite_item` places a script, pattern family, or notebook check into a
  section (or ungroups it), reordering the suite so each section stays a
  contiguous block — covering families and checks, which `update_suite` could
  not move. `list_course_sections` / `create_course_section` /
  `set_assignment_section` manage the course-level assignment groups (e.g.
  "Labs"); `set_assignment_section` adopts the section's default grading mode,
  matching the web dashboard. `get_assignment` now reports which course section
  an assignment belongs to.


## [0.4.358] - 2026-06-04

### Added

- **Preview (staff-only) assignment visibility.** Assignments now have a
  three-state visibility — `closed`, `preview`, or `open` — replacing the
  `is_open` boolean. `preview` is a staff-only beta state: students can't see
  it (it behaves exactly like `closed` for them), but course staff can
  test-submit to it to exercise the real grading path before publishing. The
  lifecycle is one-way (closed → preview → open); entering preview requires
  runner validation to have passed, and an already-open assignment can't be
  pulled back into preview. Staff test submissions are recorded as a new
  `preview` submission kind so they grade normally but never count toward
  student stats, grades, or badges. Settable from the instructor dashboard
  status control and over MCP (`update_assignment` `visibility`); course
  bundles round-trip the new field.


## [0.4.357] - 2026-06-04

### Added

- **MCP `get_assignment` now reports `gradingMode`.** Its output includes
  whether an assignment is graded by the native runner (`"worker"`) or
  in-browser via Pyodide (`"browser"`), read from the test setup's manifest
  (`TestProperties.gradingMode`). Previously no MCP tool surfaced the grading
  mode, so an agent had to guess it.


## [0.4.356] - 2026-06-04

### Added

- **MCP `delete_suite_item` tool (issue #461).** Removes one item from an
  assignment's test suite — a hand-written `script`, a pattern `familyID` (with
  its generated cases), or a notebook `check` — through the same
  buildSuitePayload / applySuiteEdit path the editor uses, so the manifest is
  rebuilt (the item is no longer graded) and validation re-runs (rejecting a
  removal that would leave a dangling dependsOn). Completes the MCP authoring
  surface (create / edit / delete) needed to migrate hand-written tests to
  declarative families end-to-end.


## [0.4.355] - 2026-06-04

### Added

- **`unordered_equality` pattern-family kind (issue #461).** A new kind for
  functions that return a list where order isn't part of the contract (e.g.
  "find all patients with diagnosis X"): each element is canonicalised (JSON with
  sorted keys, `str()` fallback) and the two multisets are compared, so a
  correct-but-reordered result passes where `boundary_equality` would false-fail.
  Supports per-student `argVarRefs` / `expectedVarRef`. Available in the
  assignment editor's family-kind dropdown, the New-Family modal, and via
  `create_pattern_family` / `update_pattern_family`.


## [0.4.354] - 2026-06-04

### Added

- **Per-student pattern families now support `approximate_equality` (issue #461).**
  A float-tolerance family case may reference per-student inputs via `$name` arg
  refs and `expectedVarRef` (e.g. `args: ["$patients"]`,
  `expectedVarRef: "avg_expected"`), resolved per student at grading time — the
  same `_ck_inputs` preamble `boundary_equality` already emitted. The supported
  set is now boundary + approximate (gated by one allowlist in the validator);
  non-personalized cases render byte-for-byte unchanged, so existing families'
  `spec_hash` is stable.


## [0.4.353] - 2026-06-04

### Added

- **MCP `create_pattern_family` tool (issue #461).** Agents can now create a
  brand-new pattern family on an assignment over MCP — previously families could
  only be *created* in the browser editor (`update_pattern_family` only edits an
  existing one). Takes the family `id` / `name` / `kind` / `function` /
  `paramNames` and a `cases` list (with raw-JSON `args`/`expected` and optional
  per-student `argVarRefs` / `expectedVarRef`); it inserts the family
  contiguously within its section and runs the same synchronous structural +
  per-kind validation as the editor, rejecting a duplicate id, wrong arg count,
  or an expected of the wrong shape for the kind.


## [0.4.352] - 2026-06-04

### Changed

- **Per-student pattern families: section expressions are now stripped from the
  runner-facing manifest.** `TestProperties.runnerSanitized()` already dropped
  `globalExpressions` (a server-side authoring concern — only the resolved
  values reach grading via `Job.personalizedInputs` / the browser seed
  endpoint), but it kept each section's identical `PersonalizationExpression`
  rows. Section expressions are now stripped too, so reference-solution source
  (e.g. `= solution.countAdults(...)`) never travels in the worker job payload.
  No grading-behaviour change — the runner reads neither field; per-student
  values continue to arrive resolved.

### Fixed

- **Stale personalization docs/comments.** `docs/inputs.md` and two
  `TestProperties` doc-comments still stated that pattern-family `$name`
  references "can NOT target an expression row" and that test-script
  personalization "remains a future slice" — both lifted by the per-student
  pattern-family work. Updated to point at
  `docs/personalization-pattern-families.md`. Added a runtime regression test
  that executes a generated per-student case against a real `_ck_inputs.py`
  (passes when correct, fails closed when the seed is absent), complementing the
  existing syntax-only check.


## [0.4.351] - 2026-06-04

### Changed

- **MCP content edits now close an open assignment.** Editing an assignment's
  suite, pattern family, hand-written script (`author_script`), starter notebook,
  or reference solution through the MCP server now closes a currently-open
  assignment and re-runs validation — matching the web "Save" button — so
  students can't submit against a not-yet-revalidated suite. Each write tool's
  response reports it as `assignmentClosed`; the instructor re-opens with
  `update_assignment(isOpen: true)` once validation passes. The agent-facing
  `initialize` instructions and tool descriptions document the behavior, and now
  also name the `validate_assignment` and `create_assignment` tools.

### Fixed

- **Per-student grading inputs (`_ck_inputs.py`).** The native worker now emits
  the personalization dict keys as escaped Python string literals (matching the
  browser runner's `JSON.stringify` and the script renderer), keeping the three
  materialization paths byte-for-byte consistent.


## [0.4.350] - 2026-06-04

### Added

- **Grade override on the per-assignment roster.** The instructor's
  `/instructor/:assignmentID/submissions` page now carries the same set/clear
  grade-override control that the per-student page already had — an inline
  pencil-icon form per student row (override percent + optional note, with a
  Clear button once one is set). The roster already displayed overrides and
  folded them into the median; it can now edit them too. Both sites resolve to
  the same `(test_setup, user)` row through shared `applyGradeOverride` /
  `clearGradeOverride` helpers, so an override set from either page is identical
  and continues to replace the runner-computed grade everywhere (roster median,
  grades CSV, BrightSpace sync, submission view).


## [0.4.349] - 2026-06-04

### Fixed

- **Dashboard and submission-page grades now agree.** The submission page used
  to headline a tier-filtered grade (e.g. 100% from public tests only before a
  deadline) while the dashboard showed the all-tier grade — two different
  numbers for the same student. Both now report the same all-tier grade, so the
  number no longer jumps when the deadline passes.

### Changed

- **Release/secret tests are presented more deliberately to students.** The
  grade is always computed over every tier (public + release + secret), so it
  is stable across the deadline. Release tests are now listed by name (with
  their instructor hint on failures) even before the deadline — only their
  detailed output is withheld until the deadline. Secret tests are never
  itemized but their aggregate pass/fail counts are shown and count toward the
  grade. First-Try Perfect now rides the all-tier grade, so it can't be earned
  while a hidden test is still failing.


## [0.4.348] - 2026-06-03

### Changed

- **`preview_personalization` audit now covers test scripts (issue #461).** Its
  `{{placeholder}}` audit also reports the per-student inputs that a pattern
  family's test-script cases reference (`$name` `argVarRefs` + `expectedVarRef`),
  not just notebook `{{markers}}` — so `placeholders.used` / `unresolved` reflect
  grading too. (`get_suite` already surfaces `expectedVarRef` / `argVarRefs` via
  the Codable family spec, so the read-side round-trip was already complete.)


## [0.4.347] - 2026-06-03

### Added

- **Author per-student pattern families in the editor (issue #461, slice D).**
  The in-browser pattern-family editor now supports per-student cases: type
  `$name` in the Expected cell (or an arg cell) to reference a global/section
  `=` expression, resolved per student at grading time. The editor learns the
  Global Input / expression names (so per-student refs validate + highlight
  instead of being red-flagged), serializes the Expected ref as `expectedVarRef`,
  and skips Pyodide auto-compute for per-student rows. Personalized families
  (#816/#817/#818) are now authorable in the browser, completing the A–D arc of
  `docs/personalization-pattern-families.md`.


## [0.4.346] - 2026-06-03

### Added

- **Author per-student pattern families via MCP (issue #461).** The
  `update_pattern_family` tool now accepts a per-case `expectedVarRef` — the name
  of a global/section `=` expression whose value, resolved for each student's
  seed at grading time, becomes the expected return (instead of the literal
  `expected`). With the existing `$name` `argVarRefs`, this completes the JSON
  authoring path for personalized `boundary_equality` families. Slice C of the
  design ("auto-derive expected from the solution") is folded in: an instructor
  writes the case's expected as a `= solution.<fn>(...)` expression and points
  `expectedVarRef` at it. See `docs/personalization-pattern-families.md`.


## [0.4.345] - 2026-06-03

### Added

- **Per-student pattern families — browser grading (issue #461, slice B).**
  Browser-graded (Pyodide) submissions now resolve per-student pattern-family
  values too: the browser-runner seed endpoint returns the assignment's `=`
  expression values (`personalizedInputs`) alongside the seed, and the browser
  runner writes them to `_ck_inputs.py` in the grading workspace — mirroring the
  native worker. A shared `PersonalizationSubstitution.gradingInputs` helper
  backs both grading paths so they resolve identically.


## [0.4.344] - 2026-06-03

### Added

- **Per-student pattern families — grading path (issue #461, slice A).** A
  `.boundaryEquality` pattern-family case may now resolve per-student values at
  grading time: its expected value (`PatternCase.expectedVarRef`) and `$name`
  arg references can point at global/section `=` expression inputs. The server
  resolves them per submission seed (reusing `PersonalizationEvaluator`) into a
  new `Job.personalizedInputs`; the worker materializes them as `_ck_inputs.py`
  in the grading workspace, and generated scripts load them by path and fail
  closed when a value is missing. This is the foundation (native worker path) —
  the browser runner and editor UI follow in later slices. Design:
  `docs/personalization-pattern-families.md`.


## [0.4.343] - 2026-06-03

### Fixed

- **Style checks no longer fail just because one cell isn't valid Python.**
  The structural / style-check template parsed the entire notebook source in a
  single `ast.parse`, so one non-Python code cell (e.g. a Markdown cell saved as
  a code cell, or a half-written cell) made the whole check `error` out — even
  when the function under test was perfectly correct. `student_source()` is now
  best-effort *parseable*: it drops only the cell(s) that don't parse on their
  own (returning the raw source verbatim when nothing needs dropping), so every
  existing saved style check that does `ast.parse(student_source())` becomes
  resilient site-wide on the next regrade — no per-assignment changes. A new
  `student_ast()` helper exposes the same per-cell parse for new checks and
  records which cells were skipped, and `student_source_raw()` keeps the
  unfiltered text available. When the target function can't be found and a cell
  was skipped, the failure message now points the student at the broken cell.
  This mirrors the per-cell resilience the executable module and
  `NotebookCheckRenderer` already had.


## [0.4.342] - 2026-06-03

### Fixed

- **`preview_personalization` placeholder audit reads the student notebook.**
  The MCP preview tool's `{{placeholder}}` audit read the test-setup zip's
  starter entry, so markers added through `update_notebook` — which writes the
  standalone notebook blob, not the zip — were absent from `placeholders.used`
  even though substitution worked at student first-open. The audit now uses the
  same `notebookData(for:)` resolver as the first-open path (notebook blob with
  precedence, zip as fallback), so it reflects what students actually see.


## [0.4.341] - 2026-06-03

### Added

- **`get_suite` now exposes script filenames.** Each test item carries `filename` (the editable on-disk name to pass to `author_script` / `update_suite`, for hand-written scripts) and `generatedFilenames` (the read-only file(s) a pattern-family or notebook-check row produces). Previously the filename was only inferable from the overloaded `name` field for hand-written scripts and was absent entirely for generated rows.


## [0.4.340] - 2026-06-03

### Fixed

- **Browser grading now injects the per-student personalization seed.** The
  in-browser Pyodide runner previously never set `CHICKADEE_ASSIGNMENT_SEED`,
  so a test reading the seed graded differently in the browser than on the
  native worker (which sets it in the test subprocess). The browser runner now
  fetches the seed from a new session-authenticated endpoint
  (`GET /api/v1/browser-runner/testsetups/:id/seed`) that resolves it with the
  same `AssignmentSeedStore.ensureSeed` the worker and notebook substitution
  use, and injects it into Pyodide's `os.environ` before tests run — so
  personalized assignments grade identically in both modes.

### Added

- **MCP `get_solution` / `update_solution` tools.** The MCP authoring surface
  can now read and replace an assignment's reference *solution* notebook (the
  instructor's answer key), not just the starter notebook. `get_solution`
  returns the solution resolved from the assignment's validation submission;
  `update_solution` stores a new solution as a `kind=validation` submission and
  re-runs validation against the current suite (watch it with
  `validate_assignment`). Both are instructor-content-only — they resolve the
  validation/solution submission and never expose or touch a student submission.


## [0.4.339] - 2026-06-03

### Fixed

- **WorkerTests is more reliable under parallel CI load.** The suite spawns
  real `/bin/sh` and `python3` subprocesses, which Swift Testing runs in
  parallel, so a cold-cache nightly could fork enough at once to trip a
  transient `posix_spawn` failure or starve a daemon polling task. A shared
  `withSubprocessSlot` throttle now bounds concurrent real-process launches
  process-wide, and every `ScriptRunner` call routes through `runScriptRobustly`
  — generalizing the #787 launch-failure retry (previously on just two tests)
  to the whole suite. The retry fires only on the empty "never launched"
  sentinel, so a genuine regression is never masked. The three hand-rolled
  `python3 http.server` helpers in `WorkerDaemonTests` are unified into one
  `LocalHTTPTestServer` that reads the child's port with a read-until-newline
  loop (fixing a single-`availableData` truncation race) and tears down with a
  prompt `SIGKILL` (a `SIGTERM` doesn't reliably stop a `socketserver` with the
  daemon's connection still open) followed by `waitUntilExit()`. CI now
  installs `python3` explicitly for the worker-tests job.


## [0.4.338] - 2026-06-03

### Changed

- **Browser-graded results are grouped by section.** The in-browser results
  shown after a student submits a notebook (`notebook.js`) and after an
  instructor validates a solution (`assignment-validate.js`) now render one
  table per test-suite section with an `<h3>` heading, matching the
  server-rendered submission view. The browser runner stamps each outcome with
  its manifest entry's `sectionID` (index correlation, mirroring the server's
  `groupOutcomesBySection`) and exposes a shared `BrowserRunner.groupBySection`
  helper; outcomes with no/unknown section fall into a trailing "Ungrouped"
  block, and assignments without sections render as a single flat table exactly
  as before. The `.submission-section-block` / `.submission-section-heading`
  styles moved into the global stylesheet so all three views share them.


## [0.4.337] - 2026-06-03

### Changed

- **Instructor student-submissions view: Reset button separated from Re-test.**
  On the per-student course submissions page the destructive "Reset working
  notebook" action sat directly beside "Re-test" with identical styling, an
  easy mis-click. Reset now renders with the `action-danger` treatment used for
  Delete/Remove elsewhere and moves to the rightmost position in the row, with
  the Extension and Grade-override controls between it and Re-test.


## [0.4.336] - 2026-06-03

### Added

- **MCP `get_server_info` tool.** A read-only tool that reports the deployed
  Chickadee version, the active MCP mode (`read_only` / `read_write`), the
  advertised content scopes, and whether writes are honored. Because a tool
  *call* round-trips to the running process, it answers "is this deploy live
  yet?" unambiguously even when a client has cached the `initialize` result or
  `tools/list` catalog — and doubles as a capability probe so an agent can tell
  whether write tools will work before calling one. DB-free, so it stays a
  useful liveness check even if the database is unavailable.


## [0.4.335] - 2026-06-03

### Added

- **CI auto-vendors the browser wasm runner.** The shared `RunnerCore` grading
  core is compiled to WebAssembly and checked in under `Public/runner-wasm/`;
  previously a `RunnerCore` change reached the native worker but the in-browser
  grader kept running the stale vendored artifact until someone rebuilt it by
  hand (the gap behind the #801 notebook-extraction fix). A new
  `runner-wasm-vendor` workflow rebuilds and re-vendors the artifact on `main`
  whenever the wasm build inputs change — gated by a source hash
  (`scripts/runnercore-source-hash.sh` vs `Public/runner-wasm/source.sha`) so it
  only runs when needed, with the Embedded-Swift wasm SDK pinned in
  `wasm/wasm-sdk.pin`. The vendored artifact can no longer silently drift from
  `RunnerCore` source.


## [0.4.334] - 2026-06-03

### Fixed

- **Notebook extraction now tracks triple-quoted strings.** The per-cell
  module/`__main__` classifier (`sanitizeCellForModule` in `RunnerCore`) scanned
  lines without any notion of triple-quoted (`"""…"""` / `'''…'''`) strings, so a
  cell that parked a multi-line block — prose or a parked alternate solution —
  at module level had its interior lines re-classified as new top-level
  statements and ripped into the `if __name__` quarantine. That split the string
  into invalid Python, which the resilient per-cell loader then silently dropped,
  wiping out **every definition and variable in the cell** (e.g. a correct
  `beats = 103680` reported as "Variable `beats` is not defined", a defined `tax`
  reported as missing). The scanner now carries triple-quote and string/comment
  state across lines, so such cells grade correctly. Shared by the native worker
  and the browser (wasm) runner. *(The vendored `Public/runner-wasm` artifact
  must be regenerated with `scripts/build-runner-wasm.sh` for the browser path to
  pick this up.)*


## [0.4.333] - 2026-06-03

### Added

- **MCP `author_script` tool.** The content-authoring MCP server can now create
  or replace a single hand-written test or support file in an assignment's test
  setup. A test tier (`public`/`release`/`secret`/`student`) upserts the file
  and its suite entry — with `points`/`displayName`/`dependsOn`/`sectionID` — and
  re-runs validation; the `support` pseudo-tier writes a non-graded helper file
  (e.g. a per-assignment data generator) that test scripts and personalization
  expressions can import. Generated pattern-family / notebook-check scripts stay
  read-only (edit the family/check instead). This closes the gap that previously
  forced raw-script edits through the web editor, and unlocks seed-aware secret
  tests for per-student personalized answers.


## [0.4.332] - 2026-06-02

### Added

- **Flag dropped students against the LEARN classlist.** A "Check against
  LEARN" button on the instructor Students tab fetches the course's D2L
  classlist and badges enrolled students (and pending "awaiting first login"
  rows) who are no longer registered on LEARN, so the instructor can remove
  stale accounts with the existing per-row delete action. Conservative
  matching — students with no resolvable student ID are reported as
  unverifiable rather than flagged for removal, and only `student` rows are
  checked. The button is hidden unless BrightSpace is configured on the server
  and the course is linked to a LEARN org unit, so it's inert until D2L
  credentials are provisioned.


## [0.4.331] - 2026-06-02

### Added

- **MCP `get_suite` returns full test definitions.** The `get_suite` tool now
  surfaces each item's source of truth alongside its metadata: hand-written
  scripts include their raw body (`content`) and `hint`, pattern families
  include the full spec with every case's `args`/`expected` (`family`), and
  notebook checks include their spec (`check`). This lets an authoring agent
  read exactly what a test checks — e.g. to explain why a submission lost
  points — without leaving the read-only `content:read` scope. Exposes only
  authoring content the instructor already sees in the browser suite editor; no
  student, grade, or submission data is involved.


## [0.4.330] - 2026-06-02

### Fixed

- **Deleting a test no longer wipes all sections.** The manifest-rebuild
  helpers used by the add-script and delete-script endpoints
  (`updateManifestAddingScript` / `updateManifestRemovingScript`) only
  forwarded the test list and pattern families to the manifest builder, so
  every other field — the `sections` list, each surviving entry's
  `sectionID` membership, notebook checks, `generatedByCheck`/`hint`, and the
  assignment-scope global variables/expressions — was silently dropped on
  every single-script add or delete. Deleting one test therefore deleted all
  of an assignment's sections. The helpers now carry the full manifest
  through the rebuild.

### Fixed

- **Suite editor: drag whole test blocks into new sections, and auto-scroll
  while dragging.** Dropping a test onto a freshly created (empty) section's
  drop row now moves the entire connected dependency group into that section
  with its prerequisites/dependents intact, instead of stranding the children
  and silently wiping the parent's dependencies. The drop row in an empty
  section is now labelled "Drop tests here" (it keeps the "remove dependency"
  meaning only inside a populated section). The suite list also auto-scrolls
  the page when a drag nears the top or bottom of the viewport, so long suites
  taller than one screen can be reorganised without manually scrolling.


## [0.4.329] - 2026-06-02

### Added

- **Audit log now covers SSO logins and the full MCP OAuth flow.** The admin
  audit log previously recorded only local username/password logins and a
  handful of admin actions, so deployments using SSO (and the MCP "authorize an
  agent" flow) saw an empty log. New events: SSO login success, SSO account
  provisioning, SSO allowlist role grants, logout, local self-registration,
  MCP consent granted, MCP token issued, MCP refresh-token reuse (theft)
  detection, MCP grant revoke-on-downgrade, MCP dynamic client registration,
  course create/delete, course bundle import/export, bulk enrollment, and
  unenrollment. The previously-defined-but-unwritten `submission.retention_purged`
  action is now emitted when a course deletion purges submissions.

### Changed

- **`/admin/audit` is filterable and human-readable.** Entries now show a
  Category and a plain-language action label alongside the raw identifier, with
  filters for action and actor and a match count, so high-volume events
  (MCP tool calls, logins) no longer crowd out the 200-row view. Timestamps use
  the America/Toronto formatter, matching the rest of the admin UI.


## [0.4.328] - 2026-06-02

### Fixed

- **Suite editor: drag whole test blocks into new sections, and auto-scroll
  while dragging.** Dropping a test onto a freshly created (empty) section's
  drop row now moves the entire connected dependency group into that section
  with its prerequisites/dependents intact, instead of stranding the children
  and silently wiping the parent's dependencies. The drop row in an empty
  section is now labelled "Drop tests here" (it keeps the "remove dependency"
  meaning only inside a populated section). The suite list also auto-scrolls
  the page when a drag nears the top or bottom of the viewport, so long suites
  taller than one screen can be reorganised without manually scrolling.


## [0.4.327] - 2026-06-02

### Added

- **Notebook reset on the course-student submissions page.** The existing
  "reset working-copy notebook to starter" action is now surfaced on the
  per-student course submissions page alongside the per-row retest and
  extension controls, via a course-scoped
  `POST /:courseCode/students/:urlToken/assignments/:assignmentID/reset-notebook`
  handler that redirects back to the same page.

### Fixed

- **Suite editor preserves dependencies when moving a test across sections.**
  Dragging a test into a different section previously cleared its `dependsOn`
  and stranded any tests depending on it in the old section, breaking the
  dependency graph. Cross-section drops now move the whole connected
  dependency cluster (transitive dependents + prerequisites) as a contiguous
  block into the target section, preserving each member's `dependsOn` and
  their topologically valid relative order. Same-section reorder is unchanged.

### Added

- **Per-student grade override with BrightSpace sync.** Instructors can set a
  whole-number percent override on the grouped per-student submissions page
  (`/:courseCode/students/:urlToken/submissions`), keyed on
  (test setup, user). The override takes precedence over the runner-assigned
  best grade both in the page and in the BrightSpace grade sweep, where it is
  converted to points against the suite's total possible points. Setting or
  clearing an override re-flags the student's results as sync-pending so
  BrightSpace re-pushes.


## [0.4.326] - 2026-06-01

### Added

- **MCP personalization tools — preview.** New read-only `preview_personalization`
  tool resolves what a student would see for an assignment: the `name → value`
  map (global + section literals, plus per-student expressions evaluated against
  a seed — supply `seedHex` for a specific student or use your own) and a
  starter-notebook `{{placeholder}}` audit (which resolve, which don't). It drives
  the same `PersonalizationSubstitution` resolver the student first-open path now
  uses, so the preview matches reality. Completes the four-part series exposing
  per-student personalization authoring over MCP.


## [0.4.325] - 2026-06-01

### Added

- **MCP personalization tools — pattern-family case editing.** `update_pattern_family`
  can now edit a generated case's test logic — its `args` and `expected` (plus the
  parallel `argVarRefs` / `argsProvided`) — not just the family defaults and which
  cases are enabled. Edits re-save through the same `applySuiteEdit` →
  `applyPatternFamilies` path the web editor uses, so the structural and per-kind
  validation (arg count vs. parameters, the kind-specific `expected` shape, `$var`
  resolution) runs synchronously and rejects bad edits at call time. Values are
  sent as raw JSON, so types stay faithful (no client-side coercion).


## [0.4.324] - 2026-06-01

### Fixed

- **Worker env-passthrough tests no longer flake on transient subprocess
  launch failures.** `scriptReceivesEnvVarFromRunner` and
  `scriptEnvVarUnsetWhenNoOverride` now retry only the narrow "subprocess never
  launched" outcome (the `-1` exit sentinel with no output and no timeout — a
  fork/posix_spawn flake under parallel CI load), so the behavioural env-leak
  assertion runs against a real execution. A genuine env-handling regression
  produces output rather than the empty sentinel, so it is never masked.


## [0.4.323] - 2026-06-01

### Added

- **MCP personalization tools — section variables.** The content-authoring MCP
  server now exposes `update_section_variables` (and `get_suite` now returns each
  section's `variables` and `expressions`), letting an authorized agent read and
  replace a test-suite section's scoped personalization inputs. The write path
  drives the same `SectionInputsService` the web editor uses, so name/`seed`/
  cross-scope-uniqueness validation and the save-time expression eval run
  identically across surfaces.


## [0.4.322] - 2026-06-01

### Added

- **MCP personalization tools — global inputs.** The content-authoring MCP
  server now exposes `get_global_inputs` and `update_global_inputs`, letting an
  authorized agent read and replace an assignment's personalization variables
  and per-student expressions. Both drive the same `GlobalInputsService` the web
  editor uses, so identifier/`seed`/uniqueness/placeholder validation and the
  save-time expression eval run identically across surfaces.


## [0.4.321] - 2026-06-01

### Added

- **Students can reset their own notebook to the starter.** The student
  dashboard gains a per-assignment reset action (`POST
  /testsetups/:id/reset-notebook`) that restores the canonical starter
  notebook over their working copy. It is gated on course enrollment and the
  assignment being open to that student, and never touches past submissions.

### Changed

- **Instructor "reset notebook" icon no longer looks like a delete button.**
  The per-student reset control on the submissions page now uses a
  counterclockwise "restore" glyph instead of a trash can, so it reads as
  "restore the starter" rather than "delete submissions" (which it never did).


## [0.4.320] - 2026-06-01

### Fixed

- **MCP OAuth "Authorize" button silently did nothing.** Clicking *Authorize*
  on the connector consent screen consumed the single-use token but never
  navigated back to the connector, so a second click reported "this
  authorization request has expired or already been used." The consent POST
  303-redirects to the OAuth client's `redirect_uri`, and browsers enforce the
  CSP `form-action` directive across that redirect — the default `form-action
  'self'` blocked the hop to the connector's origin. `GET /oauth/authorize` now
  adds the validated `redirect_uri` origin to `form-action` (mirroring the
  existing SSO-logout fix) and relaxes `Cross-Origin-Opener-Policy` to
  `same-origin-allow-popups` so a popup-driven connector keeps its
  `window.opener` handshake. Both are scoped to the consent response only.


## [0.4.319] - 2026-06-01

### Fixed

- **Browser-graded results now record the true attempt number.** The browser
  runner builds its result before it knows the server-side attempt number, so it
  always stamped `attemptNumber: 1` (and therefore `isFirstPassSuccess` for every
  pass). The server now reconciles the stored collection — submission ID, attempt
  number, and each outcome's `isFirstPassSuccess` — against the value it derived
  for the submission, so the First-Try-Perfect badge and per-attempt analytics
  are correct for browser-graded assignments.

### Security

- **MCP OAuth single-use tokens are now burned atomically.** The authorization
  code, the consent token, and refresh-token rotation each consumed their
  single-use record with a read-check-then-save, leaving a small TOCTOU window
  where two concurrent `POST /oauth/token` (or `/oauth/authorize`) requests for
  the same code could both succeed and mint two token pairs. Consumption is now
  a single conditional `UPDATE … WHERE consumed = false RETURNING` (atomic on
  both SQLite-WAL and Postgres), so only one caller can ever win.

### Fixed

- **MCP OAuth hardening.** Token-endpoint error and dynamic-registration error
  responses (and the consent page) now send `Cache-Control: no-store`; the
  hourly OAuth reaper now also drops consumed-but-unexpired authorization codes
  and consent requests; and a new index on
  `oauth_grants.previous_refresh_token_hash` keeps refresh-token theft detection
  and `POST /oauth/revoke` off a full table scan as long-lived grants accumulate.

### Security

- **Per-student personalization expressions no longer see the server's
  environment.** The subprocess that evaluates instructor-authored
  personalization expressions inherited the full server environment, so an
  expression such as `__import__('os').environ['RUNNER_SHARED_SECRET']` could
  read the worker secret, database credentials, the OIDC client secret, or
  BrightSpace keys and surface them through a substituted notebook value. The
  subprocess now receives only an explicit allowlist (`PATH`, `HOME`, locale,
  `PYTHONHOME`) plus the assignment seed and an optional support-files
  `PYTHONPATH` — never the inherited secrets.

### Fixed

- **Pattern-family arg cells can reference assignment-scope global inputs.** A
  `$name` reference to a Global Input (the worked example in `docs/inputs.md`)
  was rejected by the pattern-family validator with "references unknown
  variable", even though the renderer puts global inputs in scope alongside
  section and family variables. The validator now accepts `$global` references,
  matching what actually renders.


## [0.4.318] - 2026-05-28

### Fixed

- **MCP connector authorization now works in Safari (and any browser that
  blocks cross-site cookies).** The OAuth consent submit (`POST /oauth/authorize`)
  no longer depends on the session cookie surviving the cross-site hop — which
  Safari/ITP drops, causing a "CSRF token" 403 on Authorize. The consent screen
  now mints a single-use, server-stored consent token (carrying the consenting
  user's identity and standing in for CSRF) that the form submits instead. The
  `SameSite=None` session cookie alone could not fix this, because Safari gates
  cross-site cookies independently of `SameSite`.


## [0.4.317] - 2026-05-28

### Fixed

- **Nightly clean-build canary no longer flakes on connection-pool exhaustion.**
  `test-coverage.yml` ran the entire test suite in one process with code
  coverage but, unlike the per-PR `swift-tests.yml` jobs, never capped Swift
  Testing's parallelism — so at unbounded width the combined connection pool
  timed out, surfacing as spurious test failures and an "Index out of range"
  crash. The nightly now sets `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=4`
  to match the existing per-PR guard. Also fixed the `report-failure` job's
  `gh label create` (missing `--repo`), which silently failed in that
  checkout-less job and broke the failure-tracking issue creation.


## [0.4.316] - 2026-05-28

### Fixed

- **MCP connector OAuth login over HTTPS.** The session cookie now uses
  `SameSite=None; Secure` when served over HTTPS (falling back to `Lax` on
  plain-HTTP dev). The Claude MCP connector runs the browser OAuth flow in a
  popup opened by `claude.ai`, so the login POST that resumes
  `/oauth/authorize` is treated as cross-site; the previous `SameSite=Lax`
  cookie was dropped on that POST, which both failed CSRF validation and lost
  the stashed authorize request, so no authorization code was ever delivered
  to the connector.


## [0.4.315] - 2026-05-28

### Changed

- **Browser wasm runner: optimized, immutably cached, size-guarded.** The build
  now runs `wasm-opt -Oz` and content-hashes the artifact
  (`RunnerWasm.<hash>.wasm`), cutting the on-the-wire size to ~394 KB brotli
  (from ~636 KB gzip). A new `RunnerWasmCacheMiddleware` serves the hashed wasm
  `Cache-Control: public, max-age=31536000, immutable` with
  `Content-Type: application/wasm` (so it downloads once and streaming
  compilation works), and the loader `no-cache` so it always resolves to the
  current hash. A CI size-budget check (`scripts/check-runner-wasm-size.sh`,
  with a checked-in baseline) fails the build if the runner balloons past the
  ceiling — guarding against Embedded-Swift generic-specialization explosion.
  Details: `docs/runner-wasm-serving.md`.


## [0.4.314] - 2026-05-28

### Changed

- **Both runners now produce richer, identical result strings ("level up, not
  down").** When the browser runner was unified onto the shared Swift
  `interpretScriptOutput` (Stage 4), it dropped two bits of presentation polish
  it used to do in JS. Those are now restored *in the shared interpreter*, so
  the native worker gains them too: (1) the redundant `"<test>: "` label prefix
  is stripped from the one-line `shortResult` (the test name is already the row
  heading), and (2) a footer `traceback` field (from `test_runtime`'s
  `errored(err=…)`) is surfaced as the `longResult`. Pinned for both runners by
  the shared `output-contract.json` fixture (`OutputContractTests` for native;
  the wasm-backed `output-contract.test.mjs` for the browser).


## [0.4.313] - 2026-05-28

### Changed

- **Runner WASM migration — Stage 5 review.** Ran the Swift→Wasm PR Review
  Checklist over the migration (report: `docs/runner-wasm-review.md`): no
  blocking findings; documented concerns are design trade-offs/follow-ups
  (dynamic JS interop is forced by Embedded Swift, `wasm-opt` not yet run, the
  wasm artifact is vendored rather than rebuilt in CI, tests run via Node +
  browser rather than WasmKit). Fixed the bridge's `JSFunction`-deprecation
  warning by moving to the unified `JSObject`, so the release wasm build is
  warning-clean.


## [0.4.312] - 2026-05-28

### Changed

- **Browser runner now drives the shared Swift grading loop (Runner WASM
  migration, Stage 4).** `browser-runner.js` no longer contains a hand-written
  copy of the suite-execution loop or output interpretation. It calls
  `runnerExecuteSuites` in the RunnerCore wasm bridge — the SAME
  `executeSuites` + `interpretScriptOutput` the native worker runs — supplying
  only the browser substrate: a callback that executes a script in Pyodide and
  returns raw output (exit code + stdout/stderr). Dependency gating, the
  "Skipped: prerequisite…" message, missing-script handling, and result
  interpretation are now shared, so browser-graded and worker-graded
  submissions produce byte-identical `TestOutcome`s and can no longer drift.
  The async boundary uses JavaScriptEventLoop + `JSPromise`; verified by a
  wasm-backed cross-runner contract test (`output-contract.test.mjs` now drives
  the real wasm against the shared fixture) and an in-browser smoke run.


## [0.4.311] - 2026-05-28

### Fixed

- **RunnerCore JSON parser is now Embedded-Swift safe.** Its hand-rolled JSON
  number parser used `Double(String)`, which lowers to
  `_swift_stdlib_strtod_clocale` — a symbol the Embedded Swift wasm runtime does
  not provide. It linked only because the path was dead code in the browser
  build; the moment the shared `executeSuites` loop reaches it (output
  interpretation), the wasm build fails to link. Replaced with a small,
  dependency-free literal parser (no `strtod`, no `pow`/libm), shared by the
  native and embedded builds. Behaviour is unchanged for output interpretation
  (the parsed `score` is reserved and unread); pinned by new tests across many
  numeric forms.


## [0.4.310] - 2026-05-28

### Changed

- **Shared suite-execution loop (RunnerCore).** The grading loop that had
  repeatedly drifted between the native worker and the browser runner —
  dependency gating, "Skipped: prerequisite …" messages, missing-script
  handling, and `TestOutcome` shaping — now lives once in `RunnerCore` as the
  async `executeSuites`, driven through a narrow `ScriptExecutor` protocol
  (`scriptExists` + `run`). The native worker is the first conformance
  (`NativeScriptExecutor`, subprocess + sandbox) and maps the loop's events
  onto its structured log stream; the browser runner becomes the second
  conformance in a later stage. No behaviour change — byte-for-byte the same
  outcomes and log events. (Runner WASM migration, Stage 3 — worker half.)


## [0.4.309] - 2026-05-28

### Changed

- **`TestOutcome` and `TestTier` hoisted into `RunnerCore`.** The canonical
  grading-result types now live in the wasm-safe leaf (re-exported by `Core` via
  `@_exported import`, so call sites are unchanged). Their `Codable`
  conformances are gated `#if !hasFeature(Embedded)` — only native targets
  serialize them. Prepares the shared `executeSuites` orchestration. No
  behaviour change (Codable round-trips + core tests pass; native + embedded
  builds green).


## [0.4.308] - 2026-05-28

### Changed

- **Browser runner dispatches scripts via the shared RunnerCore classifier.**
  `browser-runner.js` now calls `classifyScriptInterpreter` through the wasm
  bridge (`runnerClassifyScript`) instead of its own JS copy, so it picks the
  same interpreter as the native worker. The duplicated JS classification
  (`classifyScript` / shebang / content-sniff) and the now-redundant JS
  dispatch-contract test are deleted — the single Swift implementation is pinned
  by `ScriptDispatchContractTests`. Verified in a real browser via the Preview MCP.


## [0.4.307] - 2026-05-28

### Changed

- **Output interpretation + runtime-model types hoisted into `RunnerCore`.**
  `interpretScriptOutput` (exit code + stdout/stderr → status + display strings)
  and the `TestStatus` / `ScriptOutput` types now live in the wasm-safe
  `RunnerCore` leaf; `Core` re-exports them (`@_exported import RunnerCore`) so
  existing call sites are unchanged. The JSON result-footer is parsed by a
  dependency-free `JSONLite` (Foundation's `JSONDecoder` is unavailable in
  Embedded Swift). Behaviour is identical (output-contract corpus passes); this
  is the single source of truth the browser runner adopts next.


## [0.4.306] - 2026-05-28

### Changed

- **Script-interpreter classification hoisted into `RunnerCore`.** The
  drift-prone "which interpreter runs this script?" decision (recognised
  extension → shebang → Python content-sniff) now lives in
  `RunnerCore.classifyScriptInterpreter` (embedded-safe, shared). The native
  worker's `scriptInvocation` delegates to it and maps the result to a
  subprocess command; behaviour is unchanged (dispatch contract + classify tests
  pass). The browser runner adopts it via wasm in a follow-up, retiring the JS copy.


## [0.4.305] - 2026-05-27

### Fixed

- **Structural-property NotebookChecks work again on both runners.** They read
  student source via AST, which broke because both runners wrap notebook cells in
  `exec(compile(...))` — so `inspect.getsource` saw no real `def`s. The shared
  RunnerCore extractor now also emits an *introspectable source* (real
  module-level defs, side-effects quarantined into `if __name__`) as a sidecar;
  a new `student_source()` runtime helper reads it, and the structural-check
  template uses it instead of `inspect.getsource`. Both the browser runner and
  the native worker write the sidecar. Fixes the HLTH-230 validation failure.


## [0.4.304] - 2026-05-27

### Added

- **Vendored the Embedded-Swift `RunnerCore` wasm bridge.** The `wasm/`
  sub-package now builds with the Embedded Swift SDK (manual JavaScriptKit
  interop, no Foundation/BridgeJS), and `scripts/build-runner-wasm.sh`
  esbuild-bundles a self-contained, no-CDN browser ESM. Checked in under
  `Public/runner-wasm/` (`runner-core.js` ≈83 KB + `RunnerWasm.wasm` ≈1.1 MB,
  ≈390 KB gzipped total) so CI/contributors need no wasm SDK. Exposes
  `runnerExtractPython(cells, filename)`; wiring it into `browser-runner.js` is
  the next step.


## [0.4.303] - 2026-05-27

### Changed

- **`RunnerCore` is now Embedded-Swift compatible.** Two behaviour-preserving
  tweaks (line-based `from __future__` detection instead of
  `String.contains(_:String)`, and an explicit `Character` split separator) let
  the shared extractor compile under the Embedded Swift wasm SDK — a ~60× smaller
  browser artifact (≈350 KB gzipped vs ≈20 MB) than the standard wasm build.
  No change to native worker output.


## [0.4.302] - 2026-05-27

### Added

- **wasm bridge build for `RunnerCore` (`wasm/` sub-package + `scripts/build-runner-wasm.sh`).**
  A separate SwiftPM package compiles the shared, substrate-free `RunnerCore`
  extraction logic to WebAssembly via JavaScriptKit/BridgeJS, exposing
  `extractPythonJSON(cellsJSON, filename)` to JS. Kept out of the main package's
  native build (JavaScriptKit is wasm-only); it depends on the new `RunnerCore`
  library product by path. This is the foundation for the browser runner calling
  the same extractor as the native worker (verified end-to-end in Node). Wiring
  it into `browser-runner.js` and vendoring the bundled artifact is the next step.


## [0.4.301] - 2026-05-27

### Changed

- **Introduced `RunnerCore`, a shared substrate-free module for runner logic.**
  Its first occupant is the notebook→Python extractor: the native worker now
  extracts notebooks through this single, dependency-free (stdlib-only,
  wasm-ready) module instead of its own copy of the logic. Output
  is byte-identical to before. The core additionally computes an *introspectable
  source* view (real module-level `def`s, side-effects quarantined into
  `if __name__`) alongside the resilient `exec(compile())` executable module —
  the foundation for fixing source/AST-based NotebookChecks and for sharing one
  extractor with the browser runner (eliminating the worker/browser drift behind
  the recent validation failures).


## [0.4.300] - 2026-05-27

### Changed

- **Instructor UI cleanup.** Renamed the instructor "BrightSpace" tab to "LEARN" (page title and heading too) and dropped the "grade sync is not configured" notice, leaving just the CSV export. The navbar instructor link now shows the active course code instead of the word "Instructor". Removed the open-date help text on the create/edit assignment pages.


## [0.4.299] - 2026-05-27

### Added

- **Broadened browser/worker parity tests.** The shared output-interpretation
  corpus (`Tests/Fixtures/output-contract.json`) gained cases for partial-credit
  `score`, JSON footers trailed by blank lines, and footer-stripping on the pass
  path. The dependency-skip result wording is now pinned by a shared fixture
  (`Tests/Fixtures/dependency-skip-message.json`): both producers (the worker's
  new `skippedPrerequisiteMessage` Core helper and `Public/browser-runner.js`)
  and the server-side `parseSkip` parser assert against it, so the string can no
  longer drift between the two runners or their consumers.


## [0.4.298] - 2026-05-27

### Added

- **Cross-runner script-dispatch contract test.** A shared fixture
  (`Tests/Fixtures/script-dispatch-cases.json`) is now asserted from both the
  native worker (`ScriptInvocation`) and the browser runner (`classifyScript`),
  so the two independent implementations of "how do I run this test script?"
  can no longer drift. Covers `.py` / extensionless+shebang / content-sniffed
  Python, shell, and R cases — the class of bug behind #754.


## [0.4.297] - 2026-05-27

### Fixed

- **Browser runner dispatches extensionless Python test scripts.** A generated
  test script with no file extension (e.g. `beats`) but a `#!/usr/bin/env python3`
  shebang was reported as `Unsupported test script type: .beats` during browser
  grading/validation, because the extension was derived as the whole filename.
  The browser runner now classifies scripts by shebang and content when there is
  no recognised extension, mirroring the worker's `ScriptInvocation` logic.


## [0.4.296] - 2026-05-27

### Fixed

- **`MCP_MODE` now drives the advertised OAuth scopes.** The two `.well-known`
  discovery documents (`oauth-protected-resource`, `oauth-authorization-server`)
  previously advertised `content:read content:write` unconditionally, even under
  `MCP_MODE=read_only` where DCR grants only `content:read`. The mismatch made
  Claude Desktop request `content:write` at `/oauth/authorize`, get refused, and
  leave the connect flow stuck on a `claude.ai` error page. `MCPMode.advertisedScopes`
  is now the single source of truth — the discovery metadata, DCR's granted
  `scope`, and the per-request scope ceiling all derive from it, so `read_only`
  advertises and grants only `content:read` and the custom-connector handshake
  completes in both modes.


## [0.4.295] - 2026-05-27

### Fixed

- **Editing an existing test in the unified Test Editor modal now opens the right editor.** The shell resolved which renderer to show from the (hidden) type dropdown's leftover value instead of the edit payload, so editing a notebook check or a custom script silently fell through to a blank pattern-family form. Imported Marmoset suites — which are entirely raw scripts — were therefore uneditable. The modal now takes the mechanism and kind from the item being edited.


## [0.4.294] - 2026-05-27

### Changed

- **CI now fails if the in-browser editor kernel would need an external fetch at
  boot.** `scripts/check-kernel-deps-vendored.py` (run in the JupyterLite job)
  scans the kernel wheels' startup imports and asserts every one is provided by
  the locally-vended Pyodide. A missing package would fall through to
  `piplite.install(...)` → CDN/PyPI, which FIPPA blocks — the class of regression
  behind the `comm` and mypy-deps editor outages. The kernel wheels declare no
  dependencies, so this scans imports rather than metadata; it catches a gap in
  CI instead of on a student's screen.


## [0.4.293] - 2026-05-27

### Fixed

- **In-browser notebook editor kernel failed with `Can't find a pure Python 3
  wheel for: 'comm'`.** `pyodide_kernel` imports `comm` at startup (its comm
  manager), but `comm` was in neither the vendored Pyodide lock nor the kernel's
  piplite index, so the notebooks editor — which eagerly initializes the comm
  manager — hit `piplite.install('comm')`, which can't reach PyPI
  (`disablePyPIFallback`) and raised. `comm` is now vendored into the canonical
  Pyodide so micropip resolves it locally. (An import-closure audit of the kernel
  confirms `comm` was the only missing dependency.)


## [0.4.292] - 2026-05-27

### Fixed

- **A failed nb_mypy load no longer bricks the in-browser editor.** nb_mypy was
  preloaded on the kernel-boot critical path (`loadPyodideOptions.packages`), so
  any failure loading it — a bad PEP 503 lock key, a future Pyodide bump dropping
  the wheel, an ABI mismatch — took down the entire editor kernel
  (`kernel-unhealthy` / `watchdog_timeout`), even though type-checking is only an
  optional nicety. nb_mypy is now loaded lazily in a background task after the
  kernel is healthy, wrapped so any failure degrades to "no type warnings" while
  the editor stays usable. Type-checking still works on the happy path.


## [0.4.291] - 2026-05-27

### Fixed

- **In-browser notebook editor crashed at runtime with an unhandled promise
  rejection once the kernel booted.** The vendored Pyodide `mypy` package
  declares no dependencies, so neither `typing_extensions` nor `mypy_extensions`
  (both required by `mypy` at runtime) were loaded. When nb_mypy ran mypy on a
  cell it raised `ModuleNotFoundError`, surfacing as a kernel error. `mypy_extensions`
  is now vendored as an extra and `nb_mypy` depends on `typing-extensions` +
  `mypy-extensions` so they load with it. Verified end-to-end: the editor kernel
  now type-checks cells inline (e.g. "Incompatible types in assignment") instead
  of failing.


## [0.4.290] - 2026-05-27

### Fixed

- **In-browser notebook editor kernel failed to start (`kernel-unhealthy` /
  `watchdog_timeout`).** `scripts/add-pyodide-extras.py` keyed the injected
  `nb_mypy` wheel in `pyodide-lock.json` under its raw project name, but Pyodide
  resolves packages by their PEP 503 canonical name (`nb-mypy`). Since the
  editor kernel loads `nb_mypy` eagerly at boot, `loadPackage` raised "No known
  package with name 'nb_mypy'" and the whole kernel died. The injector now
  normalizes the lock key, the vendored lock is corrected, and
  `scripts/check-pyodide-parity.sh` now fails CI if any package the kernel loads
  at boot can't be resolved in the lock under its canonical name.


## [0.4.289] - 2026-05-27

### Security

- **Drop the Windows `python.exe` bundled in the Pyodide 0.29.x distribution.**
  The upstream Pyodide tarball ships a native Windows executable at the dist
  root that nothing in Chickadee runs — the server, runner, and browser all
  serve `Public/pyodide/` as static WASM assets. It was built with a Go stdlib
  carrying CVE-2025-68121, which tripped the release-build Trivy scan. The file
  is removed and `scripts/setup-vendor.sh` now strips any `*.exe` after
  vendoring so a future Pyodide bump can't reintroduce it.


## [0.4.288] - 2026-05-26

### Added

- **Type-checking in the in-browser notebook editor (nb_mypy), on by default.**
  Every cell is now type-checked by mypy as it runs, surfacing type warnings
  inline — no setup cell, across every assignment. Built on the unified
  canonical Pyodide: `nb_mypy` (+ `astor`) are vendored into the one
  `Public/pyodide` lock via a declarative extras manifest
  (`Tools/vendor/pyodide-extra-packages.json`), preloaded through
  `loadPyodideOptions`, and activated at kernel startup
  (`%load_ext nb_mypy; %nb_mypy On`). Activation is **fail-safe**: if nb_mypy
  is ever unavailable or incompatible, the kernel still starts and type-checking
  is simply absent — it can never block the editor. nb_mypy 1.0.6 targets
  IPython 9 / mypy 1.x / Python ≥3.11, matching the Pyodide 0.29.3 runtime.


## [0.4.287] - 2026-05-26

### Fixed

- **In-browser notebook editor could not start its Pyodide kernel.** The
  JupyterLite editor kernel loaded Pyodide from `cdn.jsdelivr.net`, but the
  #574 CSP cleanup dropped that origin from `script-src`/`connect-src`/
  `worker-src` — so as students' cached assets expired the kernel began
  failing with CSP-refused errors.

### Changed

- **Unified on a single canonical Pyodide.** The editor kernel is now served
  the same vendored Pyodide (`/pyodide`) as Chickadee's own browser paths
  (browser-runner grading, `/validate`, setup-edit) via `pyodideUrl` in
  `Tools/jupyterlite/jupyter-lite.json`, instead of fetching a second copy
  from the CDN. The vended version is **derived from the JupyterLite kernel**
  (`scripts/setup-vendor.sh` no longer hardcodes it), so there is one pin, one
  version, and the editor and grader are guaranteed to run the identical
  Python environment. The `cdn.jsdelivr.net` CSP allowance is removed.

### Security

- **Regression guards so this can't recur.** `scripts/check-pyodide-parity.sh`
  fails the build if the vended Pyodide drifts from the kernel's pinned
  version; `scripts/verify-jupyterlite.sh` asserts `pyodideUrl` is same-origin;
  and `cSPHasNoExternalScriptConnectOrWorkerOrigins` asserts the CSP carries no
  third-party script/connect/worker origins. Together they make "editor depends
  on a CDN while the CSP silently drifts" a hard failure.


## [0.4.286] - 2026-05-26

### Added

- **BrightSpace tab build-out (grade-sync console).** The instructor BrightSpace
  tab is now a working console for the D2L grade sync: a connection test
  (`whoami`), an assignment→grade-item mapping table with a dropdown sourced
  from the course's D2L grade book (free-text fallback), a sync-activity log,
  summary counts (synced / pending / errored / unmapped), an "unmapped students"
  diagnostic, and manual **Sync now** / **Retry failed** / per-assignment
  **Push all** actions. Grade pushes now write an append-only
  `brightspace_sync_log` audit trail (success / error / skipped-no-account).
  Course→org-unit binding stays an admin action and is now **verified against
  D2L on save** — the org-unit name is looked up and cached so the binding is
  confirmable at a glance. New D2L client calls: `whoami`, `getOrgUnit`,
  `listGradeObjects`. See [docs/architecture.md](../docs/architecture.md)
  → "BrightSpace grade sync".


## [0.4.285] - 2026-05-26

### Changed

- **Admin MCP tab tidied.** Removed the explanatory "MCP agents" and
  "Connected agents" prose blurbs from the admin MCP tab. The Connected
  agents table now shows a centred "No agents have connected yet."
  placeholder when empty, which disappears once an agent connects.


## [0.4.284] - 2026-05-26

### Changed

- **Instructor view split into tabs.** The instructor dashboard now uses the
  same tabbed layout as the admin view. **Overview** keeps the dashboard
  metrics and the assignment/section listing; **Students** moves the enrolled-
  students roster to its own panel that self-updates every few seconds (like
  the admin Users panel) via a new `GET /instructor/students-data` poll
  endpoint; and a new **BrightSpace** tab hosts the "Export Grades CSV" button
  (moved off the Overview header) alongside the automatic grade-sync status.


## [0.4.283] - 2026-05-26

### Changed

- **Admin Retention tab reworked around Restore + Delete.** Archived courses now live only on the Retention tab (they no longer appear on the Overview). Each row has icon actions to Restore (unarchive) and Export a course bundle at any time, plus a permanent Delete once the course is past its retention window. The table is sortable by column.
- **Overview courses table shows a Submissions count** in place of the always-"active" Status column.

### Removed

- **Submission "Purge" action**, folded into the retention lifecycle (restore any time; permanently delete course + data once the retention window elapses).
- **"Auto-start local" runner checkbox** from the admin Overview (the worker-secret control is unchanged).
- **Redundant page-title headers** on the admin Storage and Users tabs.

### Changed

- **Dropped the "scheduled" assignment status badge.** A future open date no
  longer renders a distinct `scheduled` status on the dashboard — every
  assignment is scheduled, so the badge added no signal. The "Opens …" hint in
  the Due column is unchanged.


## [0.4.282] - 2026-05-26

### Added

- **Assignment open dates (auto-open).** Instructors can set an optional open
  date on an assignment (new + edit pages, next to the due date). The
  assignment opens to students automatically once that time arrives — a
  periodic sweep mirrors the deadline auto-close, flipping the assignment open
  and consuming the date (a later manual close is never undone). Auto-open is
  held until runner validation passes. Manually opening an assignment early
  clears any pending open date. Existing assignments have no open date and are
  unaffected; the field round-trips through course bundle export/import.
- **MCP open-date support.** `update_assignment` accepts a `startsAt` argument
  (ISO 8601, or empty string to clear); `get_assignment` and `list_assignments`
  report it.


## [0.4.281] - 2026-05-26

### Changed

- **Runner-offline alert no longer depends on the queue.** The runner-offline
  health rule now fires whenever a runner we've seen this session stops checking
  in for `ALERT_RUNNER_OFFLINE_SECONDS` (default 300s), regardless of whether
  any submissions are pending. It still stays quiet on a runner-less deployment
  and auto-resolves once a long-dead runner ages out of the dashboard window.
  This collapses the previous two-mode (urgent-while-queued vs. proactive-while-
  empty) design and removes the now-unused `ALERT_RUNNER_ABSENT_SECONDS` setting.
  The admin Health Alerts page reflects the new threshold wording.


## [0.4.280] - 2026-05-26

### Changed

- **Bigger Chickadee logo on the login page** — bumped from 128px to 200px
  (capped at 80% width on narrow screens). The source PNG is 1024px so it stays
  crisp.


## [0.4.279] - 2026-05-26

### Changed

- **The login page now shows the Chickadee mascot.** Added the (transparent)
  `chickadee-icon-alt.png` logo centered above the "Log in to Chickadee"
  heading. (`login.leaf` + `.auth-logo` in `styles.css`.)


## [0.4.278] - 2026-05-25

### Changed

- **MCP server gate is now three-state (`MCP_MODE`).** The content-authoring MCP
  server replaces the binary `MCP_ENABLED` flag with `MCP_MODE`, which takes
  `off` (not mounted — the default), `read_only` (mounted and authenticated, but
  `content:write` is never honored), or `read_write` (full authoring). Read-only
  is enforced as a server-wide scope ceiling clamped per request in the bearer
  middleware, so a `content:write` token issued while the server was `read_write`
  loses write the instant an operator flips to `read_only`, with no token
  revocation. `tools/list` now advertises only the tools the caller's scopes
  cover (write tools drop out in read-only mode), and both admin token minting
  and the browser OAuth consent flow cap the granted scope to the mode's ceiling.
  Operators must switch `MCP_ENABLED=true` to `MCP_MODE=read_write` (or
  `read_only`); `MCP_ENABLED` is no longer read.


## [0.4.277] - 2026-05-25

### Added

- **Submission retention policy (FIPPA / TL55).** Student submissions are now
  governed by a one-year-after-end-of-term retention policy. Archiving a course
  stamps a new `archived_at` timestamp (the "end of term" signal), and a new
  admin **Retention** tab (`/admin/retention`) reports every archived course
  with its archival date, submission count, and the date its submissions become
  purgeable (`SUBMISSION_RETENTION_DAYS`, default 365). The policy is
  report-first: an admin manually triggers a purge from the report, and the
  server only honours it once the retention window has elapsed. Purging removes
  submission files, their results, and diagnostics for that course while leaving
  the course, assignments, test suites, and user accounts intact; grades
  continue to flow to LEARN for TL60 retention. Each archive/unarchive and purge
  is written to the audit log.


## [0.4.276] - 2026-05-25

### Changed

- **Closed assignments are gated on a durable participation record.** A
  student only reaches a closed assignment's notebook or upload form if they
  previously engaged with it; everyone else is sent to their dashboard, so
  assignment links can be posted in advance without spoiling not-yet-opened
  labs. "Engaged" is now recorded in a new `assignment_participations` table
  (one row per student per assignment, written the first time they open it
  while it's open), which survives redeploys — rather than being inferred from
  the on-disk notebook working copy. Existing student submissions still count,
  so anyone who has submitted keeps access. Previously-opened closed
  assignments also stay on the dashboard with their Edit link.


## [0.4.275] - 2026-05-25

### Fixed

- **Timeout logout no longer 403s on a stale CSRF token.** `POST /logout` is now
  exempt from CSRF validation. When the inactivity watchdog posts
  `/logout?reason=timeout` from a long-idle tab, the server-side session (and its
  CSRF secret) is often already gone, so the page's stale token failed validation
  and the user hit a `403 Invalid CSRF token` instead of landing on the
  timeout-notice login page. Login and register stay CSRF-protected; the logout
  handler is idempotent and logout-CSRF is low risk (worst case: an unwanted sign-out).


## [0.4.274] - 2026-05-25

### Added

- **MCP resources: assignment test-suite manifests.** The MCP server now
  advertises the `resources` capability and implements `resources/list` /
  `resources/read`, exposing each accessible assignment's raw
  `test.properties.json` manifest at `chickadee://assignment/<publicID>/manifest`
  (`application/json`). `get_suite` remains the structured view; the resource is
  the verbatim canonical authoring spec (suites, pattern families, sections,
  required files), which an agent can read straight into context. Listing is
  confined to courses the subject can act on (admins: all non-archived; everyone
  else: their enrolments) and reads re-check course access — an inaccessible or
  unknown URI is reported identically so the URI space can't be enumerated.
  Requires the `content:read` scope. Replaces the previous placeholder that
  returned an empty list and a "no resources registered" error.


## [0.4.273] - 2026-05-25

### Added

- **MCP authoring: `validate_assignment` tool with live SSE progress.** Watches an
  assignment's runner validation to completion and returns the outcome
  (`passed`/`failed`/`no-runner`, or `timedOut` while still pending), by
  assignment public ID — so an agent that edited the suite/notebook can wait for
  the auto-queued validation instead of hand-rolling a poll loop. When the call
  arrives over an SSE connection carrying a `progressToken`, the transport streams
  live `notifications/progress` events (queued → running → done) before the final
  result; over plain JSON (or SSE without a token) it simply bounded-waits and
  returns the outcome. This is the worker→stream bridge from the SSE roadmap: the
  watch polls the request-independent `application.db`, so it runs safely inside
  the `@Sendable` streamed-response body without touching the non-`Sendable`
  `Request`. `content:read`, course-scoped.


## [0.4.272] - 2026-05-25

### Changed

- **The login page no longer auto-initiates SSO — it shows the "Login with
  UWaterloo" button.** In SSO-only mode `/login` used to redirect straight into
  `/auth/sso/start`, which made logout look broken: opening the app after
  logging out silently re-authenticated against the IdP's still-live SSO session
  instead of showing a logged-out page (IRA-PIA finding). Signing in now takes
  an explicit click, so logout visibly takes effect. The button still runs the
  full SSO flow (including `prompt=login` after a logout). One extra click per
  sign-in is the trade-off. (`AuthRoutes.loginForm`.)


## [0.4.271] - 2026-05-25

### Security

- **Rotate the session ID on login (session-fixation defense).** All three
  authentication entry points — local login, registration, and the SSO callback
  — now issue a fresh session id when the user authenticates, instead of
  authenticating onto the pre-login session id. A session cookie fixed onto a
  victim before they log in can no longer be used to ride the resulting
  authenticated session. (`Session.rotateID()`; modelled on the UWaterloo FAST
  OIDC reference, which regenerates the session post-authentication.)


## [0.4.270] - 2026-05-25

### Added

- **MCP Streamable HTTP: SSE response mode.** The `/mcp` POST now honours
  `Accept: text/event-stream` and returns the JSON-RPC response as a Server-Sent
  Events stream (one `event: message` framing the result), instead of plain
  JSON, which is what the Claude connector speaks. Content negotiation is the
  only change — the dispatched result is identical, and clients that don't ask
  for SSE still get `application/json`. The shape is forward-compatible:
  `notifications/progress` events can later precede the response without
  changing the tool contract. The transport stays stateless (no
  `Mcp-Session-Id` / `Last-Event-ID` resumability), and security-status
  responses (insufficient-scope 403, parse-error 400) are never masked behind a
  200 SSE body. Ships with `X-Accel-Buffering: no` on the stream plus a dedicated
  `location /mcp` block (`proxy_buffering off`) in both bundled nginx configs so
  events aren't held back by reverse-proxy buffering.


## [0.4.269] - 2026-05-25

### Security

- **Hardened MCP server test coverage.** Added regression tests pinning the MCP
  security guarantees surfaced in the audit: `/agents` cross-tenant authorization
  (instructors list/revoke only their own grants, admins all — no IDOR),
  OAuth authorization codes are single-use, the bearer gate rejects wrong-issuer
  and bad-signature tokens, the `/mcp` Host allowlist rejects a disallowed Host,
  Dynamic Client Registration honors its client cap, and no MCP/OAuth/discovery
  routes are mounted when `MCP_ENABLED` is false.


## [0.4.268] - 2026-05-25

### Added

- **MCP authoring (write): `create_assignment` tool.** Lets an authorized agent
  create a brand-new browser-graded, notebook-based assignment from scratch in a
  course, by course code + title + starter notebook (.ipynb JSON). Assembles a
  minimal empty-suite manifest + an empty runner zip + the notebook through the
  shared authoring service (the same per-setup work the web new-assignment
  publish does, minus the draft scaffolding), then a fresh assignment row that
  lands closed, unvalidated, and with no due date. The agent fills in tests with
  `update_suite` / `update_pattern_family` and refines the notebook with
  `update_notebook`, then opens it. Completes the assignment-authoring tool set
  alongside `clone_assignment`. `content:write`, course-scoped.


## [0.4.267] - 2026-05-25

### Added

- **MCP authoring (write): `create_assignment` tool.** Lets an authorized agent
  create a brand-new browser-graded, notebook-based assignment from scratch in a
  course, by course code + title + starter notebook (.ipynb JSON). Assembles a
  minimal empty-suite manifest + an empty runner zip + the notebook through the
  shared authoring service (the same per-setup work the web new-assignment
  publish does, minus the draft scaffolding), then a fresh assignment row that
  lands closed, unvalidated, and with no due date. The agent fills in tests with
  `update_suite` / `update_pattern_family` and refines the notebook with
  `update_notebook`, then opens it. Completes the assignment-authoring tool set
  alongside `clone_assignment`. `content:write`, course-scoped.

### Security

- **Send `max_age=0` alongside `prompt=login` when forcing re-authentication
  after logout.** Some IdPs (and federating IdPs like Duo→ADFS) honour
  `max_age` even when they ignore `prompt`, so sending both gives the post-logout
  re-auth the best chance of propagating to the upstream IdP as a real
  re-authentication. (`SSOAuthRoutes.ssoStart`.)


## [0.4.266] - 2026-05-25

### Added

- **MCP server now orients connecting agents.** The `initialize` result carries
  server-level `instructions` (the domain model, the read-before-write workflow,
  and the validation/scope/safety rules), and every content tool now advertises
  an `outputSchema` for its structured result plus behavioural `annotations`
  (read-only / destructive / idempotent hints). The server also reports a
  human-friendly `title`.

### Changed

- **MCP `initialize` no longer advertises an unimplemented `resources`
  capability.** v1 announces tools only; the dormant resources endpoints remain
  as scaffolding for a later release but are no longer claimed in the handshake.


## [0.4.265] - 2026-05-24

### Added

- **MCP authoring (write): `update_notebook` tool.** Lets an authorized agent
  replace an assignment's starter notebook (the notebook students open) with new
  `.ipynb` JSON, by assignment public ID. The agent supplies the full notebook
  (a JSON object with a `cells` array); the server applies the same JupyterLite
  kernel normalization + flat-file write the web editor's Save uses and re-runs
  validation, so the two paths can't drift. Narrow blast radius: only the flat
  notebook is written (the setup zip stays archival), and existing student
  working copies are left untouched so an edit never clobbers in-progress work —
  students pick up the new notebook when their copy is next reset. `content:write`,
  course-scoped.


## [0.4.264] - 2026-05-24

### Added

- **MCP authoring (read): `get_notebook` tool.** Returns an assignment's
  notebook (the starter notebook students open) as structured `.ipynb` JSON,
  plus a cell count, by assignment public ID. The first, read-only slice of
  notebook authoring (roadmap Phase 5): an agent can now inspect a notebook
  before reasoning about the suite or (later) editing the notebook. Loading
  reuses the canonical `notebookData(for:)` resolution + JupyterLite
  normalization the web notebook routes use. `content:read`, course-scoped.


## [0.4.263] - 2026-05-24

### Added

- **MCP authoring (write): `clone_assignment` tool.** Lets an authorized agent
  duplicate an existing assignment — its test setup (scripts, manifest, pattern
  families) and notebook copied verbatim — into a new assignment by source
  public ID + new title, optionally into another course the account is enrolled
  in. The safe first cut at assignment creation (roadmap Phase 4a): the clone
  lands closed, unvalidated, and with no due date, then the agent tweaks it with
  `update_suite` / `update_pattern_family` / `update_assignment`. Backed by the
  same per-assignment copy the admin "copy course" flow uses, so the two paths
  can't drift; nothing is re-graded.


## [0.4.262] - 2026-05-24

### Added

- **MCP authoring (write): `update_pattern_family` tool.** Lets an authorized
  agent edit a pattern family's metadata for an assignment — its default tier
  and points, and which cases are enabled — by assignment public ID + family id.
  A targeted read-modify-write through the same suite-edit path the web editor
  uses: every other field (function, params, case args/expected/variables) is
  preserved verbatim, and saving regenerates the family's scripts and re-runs
  validation. It does **not** author case args or expected values (the test
  logic itself).


## [0.4.261] - 2026-05-24

### Changed

- **MCP actions are audited as `<username>-MCP`.** Every MCP tool call is now
  recorded in the admin audit log under the subject's username suffixed with
  `-MCP` (e.g. `jsmith-MCP`), so agent-made changes are tracked separately from
  the instructor's own web actions. The token subject itself is unchanged for
  authorization / course-scoping.
- **MCP service-account UI is tied to the auth mode.** When SSO is active
  (`AUTH_MODE` ≠ `local`), the admin MCP panel hides manual service-account
  creation — instructors authorize agents through the SSO browser flow, and the
  Connected Agents table + audit log are the tracking surface. Local-auth
  deployments keep service-account creation.


## [0.4.260] - 2026-05-24

### Added

- **MCP `update_suite` tool (authoring Phase 3a, write half).** Edits test-suite
  *script* metadata for an assignment by public ID — tier, points, display name,
  prerequisites (`dependsOn`), and section — through the same `applySuiteEdit`
  path the web editor uses, so raw script bodies are preserved from the zip and
  never sent by the agent. `content:write`, course-scoped; the edit re-runs the
  assignment's validation. Pattern-family / notebook-check metadata and
  reordering are later phases.


## [0.4.259] - 2026-05-24

### Changed

- **Admin "MCP" tab is hidden when `MCP_ENABLED=false`.** The MCP nav tab no
  longer appears in the admin panel unless the endpoint is enabled (new
  `#mcpEnabled()` Leaf tag reads the boot-time flag).

### Security

- **Students are excluded from the MCP interface at the tool layer.** MCP tool
  calls now require the token subject to be an instructor, admin, or `mcp`
  service account — never a student. Students already can't complete the
  `/oauth/authorize` consent flow (it requires instructor), so this is
  defence-in-depth: the guarantee no longer rests solely on token issuance.


## [0.4.258] - 2026-05-24

### Added

- **MCP `get_suite` tool (authoring Phase 3a, read half).** Returns an
  assignment's test-suite structure by public ID — the ordered items
  (hand-written scripts, generated pattern families, notebook checks) with each
  one's tier, points, display name, dependencies, and section, plus the section
  list. `content:read`, course-scoped, read-only (suite editing follows). Reuses
  the author-facing `buildSuitePayload` without raw script bodies.


## [0.4.257] - 2026-05-24

### Security

- **Logout now forces IdP re-authentication on the next sign-in (SSO
  single-logout).** Follow-on to v0.4.240, surfaced by the IRA-PIA review:
  after logging out, clicking any protected link silently logged the user
  straight back in, because Duo keeps its own SSO session alive and the
  authorization request carried no `prompt`. Logout (and the idle timeout) now
  set a short-lived, session-scoped marker cookie (`chickadee_reauth`);
  `/auth/sso/start` consumes it and appends `prompt=login`, forcing Duo to
  re-authenticate, then clears it — so normal day-to-day SSO stays one-click
  and only an explicit logout/timeout re-prompts.


## [0.4.256] - 2026-05-24

### Changed

- **Versions are now assigned at merge time, not in PRs.** PRs add a fragment
  under `changelog.d/` instead of editing `VERSION`, `ChickadeeVersion`, or
  `CHANGELOG.md` — which removes the guaranteed text conflict that made
  concurrent PRs thrash. A new `auto-release` workflow folds the fragments into
  a versioned `CHANGELOG` section on merge to `main`, bumps the version, and
  tags the release (`scripts/assemble-release.sh`). CI workflows gained a
  `merge_group:` trigger so an optional GitHub merge queue can re-test PRs
  against the real pre-merge `main`. See `docs/release-process.md`.


## [0.4.255] - 2026-05-24

### Changed

- **Admin MCP panel UI cleanup (#709).**
  - Removed the descriptive blurb / "View connected agents" link above the
    service-accounts table.
  - **Connected agents (browser-flow OAuth grants) now appear on the admin MCP
    panel** as a second table (admin sees all grants, with revoke). The
    standalone `/agents` page is unchanged for instructor self-service; the
    grant-row builder is now shared (`MCPAgentsRoutes.grantRows`) so the two
    views can't drift. (Instructor-facing UI consolidation is a follow-up.)
  - Both tables are now column-sortable via the shared `sortable-table.js`,
    matching the runner/storage tables.

### Fixed

- **"No MCP accounts yet." persisted after creating an account (#709).** The
  empty-state used `#if(!accounts.count)`, but `.count` doesn't resolve in this
  LeafKit; switched to `.isEmpty` (the idiom the other tables use). Fixed the
  same latent bug in the per-account "no courses" check and on the
  `/agents` page.
- **Safari mis-identified the "Create account" username field as a password
  field (#709).** Added `autocomplete="new-password"` (the project's existing
  Safari-autofill bypass).

## [0.4.254] - 2026-05-24

### Changed

- **MCP authoring Phase 2 — `update_assignment` now edits title + due date (#707).**
  The `update_assignment` tool gains optional `title` and `dueAt` fields
  alongside `isOpen` (provide only what you want to change; at least one
  required). A due-date change re-normalises `deadlineOverrideActive` and an
  empty `dueAt` string clears the due date — matching the instructor editor via
  the shared `AssignmentAuthoringService.updateMetadata`. Still metadata-only
  (no manifest change → no regrade) and course-scoped.
- **Removed the `update_assignment_title` MCP tool**, now fully subsumed by
  `update_assignment` (title editing). One assignment-metadata editor instead of
  two overlapping write tools.

## [0.4.253] - 2026-05-24

### Added

- **MCP authoring — Phase 0 + 1, plus open/close (#706).** First slice of the
  assignment-authoring buildout (see `docs/mcp-authoring-roadmap.md`).
  - **`AssignmentAuthoringService`** — the seed of the shared authoring service
    layer (`Sources/APIServer/Services/`). `setOpenState(_:open:on:)` holds the
    canonical open/close semantics (validation-passed guard; sets
    `deadlineOverrideActive` when past due so the auto-close sweep won't
    immediately re-close); the instructor dashboard handlers
    (`openAssignment` / `updateStatus` / `closeAssignment`) now call it instead
    of duplicating the logic. No behaviour change.
  - **`get_assignment`** (`content:read`) — assignment detail by public ID
    (title, course code, slug, open/closed, due date, validation status).
  - **`list_courses`** (`content:read`) — the courses an agent may act on
    (its enrolled courses; all for an admin account).
  - **`update_assignment`** (`content:write`) — **open or close an assignment
    for submissions** by public ID. Metadata-only (no manifest change → no
    regrade); routes through `AssignmentAuthoringService` so it matches the
    dashboard exactly, including refusing to open until validation passes.
  - All new tools are course-scoped via `authorizeCourseAccess`.

## [0.4.252] - 2026-05-23

### Added

- **MCP course-scoping — agents are confined to enrolled courses (#704).**
  An access token's subject (the consenting instructor, or an admin-minted
  service account) may now only read or edit courses it is **enrolled in**;
  admins remain global. Enforced in `ToolContext.authorizeCourseAccess` and
  applied to both content tools (`list_assignments`, `update_assignment_title`),
  which now return a `not authorized … not enrolled` tool result for any
  course outside the subject's enrollment.
  - **Admin MCP tab course picker** — each service account row shows its
    enrolled-course chips (with remove) plus a dropdown to enroll; new
    `enroll`/`unenroll` endpoints, audited (`mcp.account_enrolled` /
    `mcp.account_unenrolled`). An account with no enrollments can do nothing.
  - `mcp`-role service accounts are excluded from the instructor and admin
    **course roster views** (they're enrolled to scope an agent, not as roster
    members), so existing rosters/counts are unaffected.

### Changed / Hardened

- **OAuth back-channel rate limiting + DCR caps (#704).** `MCPOAuthRateLimitMiddleware`
  applies a per-IP sliding-window limit to `/oauth/{token,revoke,register}`;
  `/oauth/register` additionally caps redirect-URIs per client and total
  registered clients. Tunable via `MCP_OAUTH_RATE_LIMIT_PER_MIN` (30),
  `MCP_MAX_REGISTERED_CLIENTS` (1000), `MCP_MAX_REDIRECT_URIS` (5).
- **Consent-screen anti-phishing (#704).** `/oauth/authorize` now shows the
  redirect destination host and a "you have not approved this app before"
  warning on first approval, since DCR client names are self-asserted.
- **Refresh-time re-authorization (#704).** `/oauth/token` refresh now re-checks
  that the grant's subject is still an instructor/admin; a downgraded account's
  grant is revoked, closing the long-lived-grant gap.
- **Origin guard fix (#704).** An empty `MCP_ALLOWED_ORIGINS` allowlist now
  means "allow any" (matching the Host guard and the documented default),
  instead of rejecting every request that carries an `Origin` header.
- **OAuth-table reaper (#704).** A periodic sweep (`MCPOAuthReaperService`,
  registered only when MCP is enabled) deletes expired authorization codes and
  revoked/expired grants so those tables don't grow without bound.

## [0.4.251] - 2026-05-23

### Added

- **MCP Dynamic Client Registration — completes the browser OAuth arc (#703).**
  An MCP client (the Claude connector, the Inspector's OAuth mode, etc.) can now
  self-register, so no manual client setup is required.
  - **`POST /oauth/register`** (RFC 7591) — creates a public OAuth client from
    `client_name` + `redirect_uris` and returns a generated `client_id`
    (`token_endpoint_auth_method: none`). Redirect URIs must be HTTPS absolute
    URLs, or `http` on a loopback host (`localhost` / `127.0.0.1` / `[::1]`) for
    local clients. Open registration is safe: a registered client can do nothing
    until an instructor/admin consents at `/authorize`.
  - **`registration_endpoint`** is advertised in the authorization-server
    metadata.
  - **README** updated with the full browser-OAuth path (self-register →
    instructor consent → token), alongside the existing admin-minted-token flow
    for headless use.

  This closes out the MCP Phase 2 work: an end-to-end OAuth 2.1 authorization
  server (discovery → DCR → PKCE authorize → token + rotating refresh →
  revoke), with all agent activity auditable as "human, via agent".

## [0.4.250] - 2026-05-23

### Added

- **MCP OAuth revocation + Connected Agents UI (#702).** Completes grant
  lifecycle management for the Phase-2 browser flow.
  - **`POST /oauth/revoke`** (RFC 7009) — revokes the grant behind a presented
    refresh token; always responds 200 (an unknown/opaque token is a no-op).
  - **Refresh-token reuse detection.** `oauth_grants` now records the
    just-rotated-away refresh-token hash; replaying a spent refresh token is
    treated as theft and **revokes the whole grant** (both the replayed and the
    current token stop working).
  - **"Connected agents" page** (`GET /agents`, instructor/admin): lists the
    agents authorized on a user's behalf — agent name, scopes, authorized/last-
    used/expiry — with a **Revoke** button. An instructor sees their own grants;
    an admin sees every grant. Revocations are audit-logged (`mcp.grant_revoked`).
    Linked from the Admin → MCP tab.

## [0.4.249] - 2026-05-23

### Added

- **MCP browser OAuth flow — live `/authorize` + `/token` (#701).** Chickadee
  now acts as its own OAuth 2.1 authorization server so an agent can obtain a
  token through a browser consent screen instead of an admin pasting one
  (Phase 2). Mounted when `MCP_ENABLED`.
  - **`GET/POST /oauth/authorize`** — validates the client, exact redirect-URI,
    PKCE (`S256`), and requested scopes, requires a logged-in **instructor or
    admin** (unauthenticated users round-trip through `/login` via a
    session-stored, same-origin `returnTo`), shows a consent screen, and issues
    a single-use 60-second authorization code.
  - **`POST /oauth/token`** — `authorization_code` exchanges the PKCE code for a
    short access token + a long rotating refresh token; `refresh_token` rotates
    to a fresh pair. Codes/refresh tokens are stored only as SHA-256 hashes;
    token responses are `Cache-Control: no-store`.
  - **RFC 8414 authorization-server metadata** at
    `/.well-known/oauth-authorization-server` (advertises the authorize/token
    endpoints, JWKS URI, scopes, grant types, and `S256`).
  - **Per-tool-call audit logging** (`mcp.tool_called`): every authorized tool
    call is recorded as the human subject, attributed to the acting agent
    (`via_agent`); tool arguments are never logged.
  - The access token's subject is the **human**; the agent rides in the
    `client_id`/`agent_name` claims (from v0.4.248) for audit attribution.
  - **Not yet:** revoke-on-reuse refresh detection + `/revoke` + a "Connected
    agents" management UI (next PR), and Dynamic Client Registration so a
    connector self-registers (follow-up) — for now an OAuth client must be
    pre-registered.

## [0.4.248] - 2026-05-23

### Added

- **MCP OAuth authorization-server data layer + token attribution — dormant (#700).**
  Groundwork for the Phase 2 browser OAuth flow (so an agent can self-serve a
  token instead of an admin pasting one). None of this is wired into a live
  endpoint yet — the `/authorize` + `/token` flow follows in the next PR.
  - **Three Fluent tables + migrations:** `oauth_clients` (registered agents —
    `MCPOAuthClient`), `oauth_authorization_codes` (short-lived PKCE codes —
    `MCPAuthorizationCode`), and `oauth_grants` (durable, refresh-token-backed
    authorizations — `MCPGrant`). Codes/refresh tokens are stored only as
    SHA-256 hashes; user FKs cascade.
  - **Token client-attribution.** Access tokens can now carry `client_id` +
    `agent_name` claims so a browser-flow token records the human as the
    subject *and* the agent it was issued through — surfaced on
    `MCPPrincipal` / `ToolContext` for separate audit attribution. Phase-1
    admin-minted service tokens carry no acting client (the subject is the
    agent).
  - **Config knobs:** `MCP_ACCESS_TOKEN_TTL_SECONDS` (browser-flow access-token
    lifetime, default 10 min — kept short so revoking a grant takes effect
    quickly) and `MCP_GRANT_TTL_DAYS` (authorize-once-per-term grant lifetime,
    default 120 days).

## [0.4.247] - 2026-05-23

### Added

- **Admin "MCP" tab for provisioning agents + minting tokens (#699).** Completes
  the content-authoring MCP server: an operator can now create accounts and mint
  tokens entirely from the web UI, and the README documents the full enable →
  provision → smoke-test flow.
  - **`Admin → MCP`** lists `mcp` service accounts, creates new ones (a
    non-loginable `mcp`-role `APIUser` with a random unusable password hash —
    no first-login path can auto-assign this role), mints an access token
    (read+write or read-only, shown exactly once and only while MCP is active),
    and deletes accounts. Each action is audit-logged (`mcp.account_created` /
    `mcp.token_minted` / `mcp.account_deleted`); the token itself is never
    logged.
  - **Stateless-token caveat surfaced in the UI + README:** deleting an account
    stops new tokens being minted but cannot revoke one already issued — it
    expires after `MCP_TOKEN_TTL_SECONDS`.
  - **README** gains an "MCP content-authoring server" section: required env
    vars, the discovery endpoints, the admin provisioning steps, and a `curl`
    smoke test (`initialize` / `tools/list` / `tools/call`).

## [0.4.246] - 2026-05-23

### Added

- **MCP content-authoring endpoint goes live behind OAuth 2.1 (#698).** The
  dormant auth machinery from v0.4.245 is now wired into the running server.
  Opt in with `MCP_ENABLED=true` (plus `PUBLIC_BASE_URL`, or explicit
  `MCP_ISSUER`/`MCP_RESOURCE`); the endpoint stays absent otherwise.
  - **`/mcp` is mounted behind `MCPBearerAuthMiddleware`** via
    `registerMCPRoutes`, which resolves the issuer/resource identifiers from
    config (falling back to `PUBLIC_BASE_URL`) and loads — or auto-generates —
    the ES256 signing-key authority at startup. The transport now builds its
    `ToolContext` from the authenticated `request.mcpPrincipal` (subject +
    granted scopes) instead of the placeholder ungated context.
  - **OAuth discovery endpoints (unauthenticated):**
    `GET /.well-known/oauth-protected-resource` (RFC 9728 metadata —
    authorization server + supported scopes) and `GET /.well-known/jwks.json`
    (the ES256 public signing key as a JWK, RFC 7517), so a client can locate
    the authorization server and verify tokens.
  - **Per-tool scope enforcement.** The dispatcher requires the caller's
    granted scopes to cover each tool's `requiredScopes`; a read-only token
    calling a `content:write` tool is rejected before execution and surfaced as
    HTTP 403 with a `WWW-Authenticate: …, error="insufficient_scope"` challenge.
  - End-to-end tests drive the real `registerMCPRoutes` wiring (token → bearer
    middleware → dispatcher → tool), plus scope-rejection, discovery-metadata,
    and JWKS coverage.

## [0.4.245] - 2026-05-23

### Added

- **MCP auth machinery — dormant, not yet mounted (#697).** Groundwork for
  gating the content-authoring `/mcp` endpoint behind OAuth 2.1 bearer tokens,
  with Chickadee acting as its own authorization server (Phase 1: admin-minted
  tokens). None of this is wired into the live request path yet — the `/mcp`
  route remains ungated until a follow-up PR mounts the middleware and adds the
  metadata/JWKS endpoints.
  - `MCPConfig` substruct on `AppConfig` (`enabled`, `allowedHosts`,
    `allowedOrigins`, `tokenTTLSeconds`, `signingKeyPath`, `issuer`,
    `resource`), resolved from the environment with safe defaults and a
    redacted `logSummary` line.
  - **`mcp`-role guardrail.** First-login flows (register + SSO) can never
    auto-assign the `mcp` service-account role: `APIUser.autoAssignableRoles`
    limits auto-assignment to `student`/`instructor`/`admin`, and SSO role
    mapping is filtered through `APIUser.sanitizedAutoAssignedRole(_:)`. An
    admin must set `mcp` deliberately.
  - **`MCPTokenAuthority`** — an ES256 (P-256) token authority that mints and
    verifies MCP access tokens (`MCPAccessTokenClaims`: subject, issuer,
    audience, expiry, scopes), persisting an auto-generated signing key to disk
    (mode 0600) and exporting EC public-key parameters for a future JWKS
    endpoint.
  - **`MCPBearerAuthMiddleware`** — validates the bearer token (signature +
    expiry), binds the issuer and audience (RFC 8707), requires at least one
    content scope (defence in depth), surfaces the caller on
    `request.mcpPrincipal`, and returns 401/403 with a
    `WWW-Authenticate: Bearer resource_metadata="…"` challenge on failure.

## [0.4.244] - 2026-05-23

### Changed

- **Runner dashboard adopts the shared `sortable-table.js`.** `admin-runner.leaf`
  carried its own inline copy of the generic column sorter and its
  `.sort-header` / `th.sort-asc` / `th.sort-desc` CSS — both duplicates of the
  shared assets introduced in v0.4.241. It now loads `Public/sortable-table.js`
  (styling from `styles.css`) like `admin-storage.leaf`. The page-specific
  inline script — relative-time formatting, the offline badge, and the 5s
  `/admin/runners` poll — stays inline. Sorter behaviour is unchanged (the
  extracted JS is byte-identical to the removed block).

## [0.4.243] - 2026-05-23

### Added

- **Content-authoring MCP server — Phase 1, ungated core (#695).** A native
  Model Context Protocol server under `Sources/APIServer/MCP/`: JSON-RPC 2.0
  over a Streamable-HTTP `/mcp` route (Host/Origin DNS-rebinding guard;
  `initialize` / `ping` / `tools/*` / `resources/*`; notifications → 202;
  GET/DELETE → 405), a `ContentTool` protocol + type-erased registry, and two
  authoring tools wired to Fluent — `list_assignments` and
  `update_assignment_title`. Spec revision 2025-11-25. The endpoint is **not
  yet mounted on the live app** (dormant); OAuth 2.1 bearer auth, the `mcp`
  role + admin token minting, and scope enforcement land in a follow-up PR
  before it goes live.

## [0.4.242] - 2026-05-23

### Changed

- **Runner-offline alert is now proactive — it fires on an empty queue too.**
  Previously the runner-offline health rule only fired when jobs were queued AND
  no runner had checked in, so a dead runner went unnoticed until work piled up
  behind it. The rule now has two modes:
  - **Jobs queued (urgent):** unchanged — fires when no runner has checked in
    within `ALERT_RUNNER_OFFLINE_SECONDS` (default 300s).
  - **Empty queue (proactive):** fires when a runner we've seen this session has
    gone quiet for longer than the new `ALERT_RUNNER_ABSENT_SECONDS` grace
    period (default 600s / 10 min), so capacity loss is caught before a backlog
    forms.

  The proactive case only fires if at least one runner has checked in this
  session (a runner-less / browser-graded-only deployment never pages), and a
  long-dead runner is "forgotten" after the same 1-hour window the admin
  dashboard uses, so the alert auto-resolves rather than nagging forever.

  Implementation: `WorkerActivityStore.runnerPresence(graceSeconds:rememberSeconds:)`
  (non-mutating, so it never races the dashboard's pruning) plus a pure
  `decideRunnerOffline(...)` decision function for table-testable firing logic.

  **Known limitation:** because runner identity is in-memory and Docker runners
  use ephemeral IDs (v0.4.32), this detects "no runner at all is checking in",
  not "1 of N specific runners died". Per-runner / expected-runner monitoring
  needs a stable runner identity + an expected-count registry — tracked as a
  follow-up.

## [0.4.241] - 2026-05-23

### Added

- **Admin Storage "By Assignment" table is now sortable by column**, matching
  the runner dashboard. Size columns (Test Suite / Submissions / Total) sort by
  raw bytes, not the formatted string, so "1.4 GB" sorts above "320 MB". The
  generic sorter was extracted to a shared `Public/sortable-table.js`
  (`<table class="sortable-table">` + `data-sort-type` headers +
  `data-sort-value` cells) with its styling moved to `styles.css`, so other
  tables can opt in the same way.

### Changed

- **Instructor student-submission view uses icon buttons.** The per-assignment
  Retest button and the Grant/Edit-extension toggle on
  `course-student-submissions.leaf` now render as inline-SVG icon buttons
  (refresh arrows for retest; calendar / calendar-check for the extension
  toggle), matching the icon-button language already used on the assignments
  list and the assignment-submissions view. The extension form panel keeps its
  text Save/Remove labels.

### Removed

- **Trimmed explanatory blurbs from admin pages.** Removed the "On-disk
  footprint…" and "Test-suite bytes cover…" captions from the admin Storage
  panel and the "Chickadee evaluates four rules every 60s…" paragraph from the
  admin Health Alerts page.

## [0.4.240] - 2026-05-23

### Security

- **Logout / idle-timeout now fully end the session, and authenticated pages
  are no longer cacheable.** Surfaced by the IRA-PIA security review: after
  clicking "Log out" a returning browser still showed a logged-in view, and
  only closing the browser truly signed the user out.

  - **Root cause was browser caching, not a live server session.** The server
    already invalidated the session on logout, but HTML responses carried no
    `Cache-Control` header, so the browser served the dashboard from its disk /
    back-forward cache. `SecurityHeadersMiddleware` now adds
    `Cache-Control: no-store` to every `text/html` response. Scoped to HTML so
    the vendored static assets (Pyodide, JupyterLite, CodeMirror) keep their
    long-lived caching.
  - **Logout and idle timeout now call `req.session.destroy()`** instead of
    `unauthenticate()`. `destroy()` deletes the persisted Fluent session row
    and emits a `Set-Cookie` that expires the cookie immediately, so logout no
    longer depends on the browser being closed (`AuthRoutes.logout`,
    `SessionIdleTimeoutMiddleware`).
  - New regression tests: `logoutInvalidatesServerSideSession`,
    `htmlResponsesAreNotCacheable`, `nonHtmlResponsesStayCacheable`.

## [0.4.239] - 2026-05-22

### Removed

- **Dead-code cleanup after the unified Test Editor modal (PR4g).** Now that
  all three editors are shell renderers and every write flows through
  `PUT /suite`, removed the scaffolding that's no longer reachable
  (net ≈ −945 lines):
  - Deleted the orphaned `Public/add-test-dispatcher.js` (the two-step picker)
    and `Public/notebook-check-editor.js` (replaced by `test-renderer-check.js`).
  - `test-editor-modal.js`: dropped the staged-rollout `delegateOpen` /
    `delegateMode` / "Continue →" hop — every mechanism has a renderer.
  - `pattern-family-editor.js`: removed the legacy `PUT /families` fallback in
    `persistFamilies`, the now-unused `extractErrorMessage` + `onFamiliesChange`
    + `urls.putFamilies` (init now requires only `solutionNotebook` +
    `scanNotebook`), and the dead `add-family-btn` handler.
  - `suite-table.js`: removed the unused `syncFamilies` / `syncChecks` hooks and
    the legacy `PUT /checks` delete fallback; check-row Edit/Delete now open the
    shell / re-save via `saveChecksViaSuite`.
  - Both leaves: dropped `urls.putFamilies` / `urls.putChecks`,
    `onFamiliesChange` / `onChecksChange`, the `chickadeeSync*` /
    `chickadeeOpenScriptCreator` globals, and the dead hidden `new-script-btn` /
    `add-family-btn` buttons.

  No backend or model changes — purely front-end dead-code removal; the full
  Swift suite (1351 tests) and both leaf-render paths stay green. Backwards
  compatible: existing manifests are read through the unchanged `GET /suite`.

## [0.4.238] - 2026-05-22

### Changed

- **Pattern-family editor folded into the unified Test Editor modal (PR4f) —
  all three test types now morph in one overlay, no hop.** The 2085-line family
  editor (`Public/pattern-family-editor.js`) now registers a body renderer on
  `window.ChickadeeTestRenderers.family`; its heavy logic (solution-notebook
  scan, cases table, Variables table, Pyodide auto-compute of Expected, the
  per-kind layout) is unchanged. The family form markup was carved out of its
  standalone `#family-editor-overlay` into a hidden `#family-editor-body` that
  the renderer's `mount()` relocates into the shell panel; the shell owns the
  chrome (title / Save / close), so `overlay` / `titleEl` / `saveBtn` uses are
  null-guarded and the validation + upsert logic is factored into
  `readFamilySpec` / `persistFamilySpec` shared by the renderer's
  `readSpec` / `persistAndSync`. Editing a family from a suite row now opens the
  shell pre-populated. With this, the legacy `add-test-dispatcher` two-step hop
  is fully retired in practice — the `Continue →` delegate path in the shell is
  dead and removed in the PR4g cleanup. No backend changes.

## [0.4.237] - 2026-05-22

### Changed

- **Custom-script editor folded into the unified Test Editor modal (PR4e).**
  The hand-written-script editor is now a body renderer
  (`Public/test-renderer-script.js`, an ES module carrying the CodeMirror 6
  editor, filename + template controls, and the per-script hint) hosted by the
  shell — picking "Write a custom script" morphs the body in place, no hop. The
  inline `#script-editor-overlay` + its `<script type="module">` editor are
  removed from both leaves; editing a saved script and editing a queued-but-
  unsaved upload are rewired to open the shell (the renderer fetches the body
  for saved scripts via the page-supplied `scriptContentURL`, and writes back
  to the file `<input>` for uploads). Create + content/hint edits persist
  through the single `PUT /suite` path (`saveScriptViaSuite`); the shared
  `#cm-editor-mount` CSS is retained and the dark-mode input rules retargeted to
  the shell. **Family** is now the only type still delegating to its legacy
  overlay (the shell shows "Continue →"); it becomes a renderer in PR4f. No
  backend changes.

## [0.4.236] - 2026-05-22

### Changed

- **Unified "+ Add Test" modal — shell + first body renderer (check).** The
  instructor "+ Add Test" flow is now one modal (`Public/test-editor-modal.js`)
  that owns the chrome (overlay / open / close / Escape / overlay-click), the
  instructor-facing type `<select>` catalog, a color-coded status line, a single
  deduped `extractErrorMessage`, and the generic Save flow. Picking a type
  morphs the body in place — no two-step hop. Editors become **body renderers**
  registered on `window.ChickadeeTestRenderers[mechanism]` implementing
  `mount / reset / populate / readSpec / persistAndSync / cleanup / title`. This
  is the first slice of the renderer rewrite: the **notebook-check** form is now
  a renderer (`Public/test-renderer-check.js`, fed by the `#check-schema` seed,
  persisting via the single `PUT /suite` path); the **family** and **script**
  types delegate to their existing overlays for now (the shell shows a
  "Continue →" button for them) and become renderers in follow-up slices.
  Replaces the standalone notebook-check editor + the `add-test-dispatcher`
  picker. No backend changes.

## [0.4.235] - 2026-05-22

### Fixed

- **Per-student deadline extensions now actually let the student view and
  submit after the assignment-wide deadline.** The automatic deadline sweep
  (`closeExpiredAssignments`) flips an assignment's single `isOpen` flag to
  false the moment the base deadline passes, and every student-facing path
  checked `isOpen` first — so a granted extension was silently ignored exactly
  when it mattered: the assignment disappeared from the student dashboard and
  the notebook page hid the Submit button. The per-user open check
  (`isAssignmentOpenForUser`, used by the submit gate, the dashboard, and the
  notebook page) now treats an active extension as reopening submission for that
  one student when the assignment was *auto-closed at its deadline*, while a
  deliberate manual close *before* the deadline still stays closed. The sweep
  also no longer closes an assignment that still has a live extension, so
  `isOpen` stays true through the extension window. The notebook page switched
  from the assignment-wide `isAssignmentEffectivelyOpen` to the per-user
  variant, and the dashboard now lists setups where the student holds an active
  extension. The now-unused single-argument `isAssignmentEffectivelyOpen` was
  removed.

## [0.4.234] - 2026-05-22

### Changed

- **The script editor now saves through the declarative `PUT /suite` path and
  supports a per-script hint.** Previously the hand-written-script editor used
  the legacy `POST /scripts` (create) and `PUT /scripts/:name` (edit-content)
  endpoints, which carried no hint. It now routes through
  `suite-table.js`'s new `saveScriptViaSuite` hook (a sibling of the family /
  check save hooks), which writes the body into the zip via PR4a's
  `ScriptDTO.content` channel and persists a hint via `ScriptDTO.hint` onto the
  manifest entry — surfaced to students as the "💡 Hint" callout on failure
  (PR2). A hint input was added to the script-editor modal on both the edit and
  new-assignment pages (visible in create + edit modes; pre-filled from the
  suite row when editing). The suite table now carries each script row's hint
  and re-emits it on every push, so a reorder/retier never wipes it; the body
  rides on a transient that the post-push re-seed clears. Legacy `POST`/`PUT
  /scripts` fallbacks remain for any context without the suite table. Works
  identically for published assignments and the new-assignment draft (both
  `PUT /suite` variants go through `applySuiteEdit`).

## [0.4.233] - 2026-05-22

### Added

- **Restored hint authoring in the pattern-family editor.** v0.4.94 removed the
  visible hint UI (keeping `PatternCase.hint` / `PatternDefaults.hint` in the
  manifest shape); now that hints surface as a "💡 Hint" callout on failing
  tests (PR2), the editor exposes them again: a per-case **Hint** column in the
  cases table (read on save and preserved across function/kind switches and the
  header rebuild) and a visible family-level **Default hint** field (shown when
  a case with no hint of its own fails). Backend already supported both — this
  is the UI + read-path wiring (`Public/pattern-family-editor.js`, the
  family modal markup in `assignment-edit.leaf` / `assignment-new.leaf`). Hints
  flow through the existing `PUT /suite` family save; blank hints are omitted to
  keep manifests clean.

## [0.4.232] - 2026-05-22

### Fixed

- **Docker tag builds no longer fail the Trivy scan on `no space left on
  device`.** The `build-and-push` job `load`s the large (~1.4 GB Pyodide +
  distro + static binaries) image into the local Docker daemon, then Trivy
  re-exports it to a `/tmp` tarball to scan — two copies on the runner's root
  FS plus the BuildKit gha cache, which intermittently exhausted the default
  ubuntu-latest ~14 GB. Because the scan gates (runs before) the push step, a
  scan failure meant the versioned image was never published — the v0.4.231
  tag build failed here, so `ghcr.io/jimwallace/chickadee:0.4.231` is missing
  (`:latest` / `:sha-d7d7971`, pushed by the same commit's main build, carry
  the identical bits). Added a disk-reclaim step that removes unused
  preinstalled toolchains (~25 GB) before the build. No change to the
  scan-gates-push ordering.

## [0.4.231] - 2026-05-22

### Added

- **Raw-script instructor hints now persist through `PUT`/`GET /suite`.** PR2
  added `TestSuiteEntry.hint` and the display-time "💡 Hint" callout but left
  hand-written scripts with no write-path to author one. The hint now threads
  end to end: `ScriptDTO.hint` → `AuthoredRawScript.hint` → `applySuiteEdit` /
  `applyPatternFamilies` (both the authored-items and manifest-reconstruct
  paths, so a reorder preserves it) → `ConfiguredSuiteEntry.hint` →
  `testSuiteEntryToDict` (emitted only when non-empty) → the manifest's
  `TestSuiteEntry.hint`. `GET /suite` reads it back so the editor round-trips
  it. Backend foundation for the script hint field in the upcoming unified
  "Add Test" modal (families and checks already carry hints via their specs).
  No runner or generated-script changes.

## [0.4.230] - 2026-05-22

### Changed

- **Notebook-check editor forms are now schema-driven from a single backend
  source.** Each `NotebookCheckKind`'s form fields (variable name, expected
  shape, tolerances, match mode, …) are declared once in
  `Sources/APIServer/Utilities/NotebookCheckFormSchema.swift`, beside the
  validators in `NotebookCheckKindHandler.swift`, via an exhaustive `switch`
  over `NotebookCheckKind` (a new kind won't compile until it declares its
  fields). The schema is emitted to the assignment editor pages as a
  `<script id="check-schema">` seed and rendered generically by
  `Public/notebook-check-editor.js` — its `reset` / `populate` / `build`
  logic is now one engine driven by each field's `valueType`. This retires
  the ~10 hand-coded `.check-fields[data-kind=…]` cards that were duplicated
  across `assignment-edit.leaf` and `assignment-new.leaf`, plus the parallel
  per-kind JS switches. Checks become **hint-authorable immediately**: `hint`
  is a common schema field (PR2 surfaces it as the "💡 Hint" callout).
  Side effect: the new-assignment page's check-kind picker, which had drifted
  to omit `variable_exists`, now matches the edit page (both render every
  kind from the schema). New `NotebookCheckFormSchemaTests` pins each kind's
  `required` flags to its validator so the two can't drift. No manifest,
  runner, or generated-script changes — the schema is pure authoring-UI
  metadata.

## [0.4.229] - 2026-05-22

### Added

- **Instructor hints are now first-class across all test items, shown as a
  "💡 Hint" callout on failing tests.** Previously a hint existed only on
  pattern-family cases and was *baked into the generated Python's failure
  string*, so it landed as buried prose in the output panel. Hints now live on
  the spec for every flavour — `PatternCase`/`PatternDefaults` (families, as
  before), the new `NotebookCheck.hint`, and the new `TestSuiteEntry.hint`
  (hand-written raw scripts) — and are surfaced at **results-display time** via
  a filename-keyed join (`buildHintByFilename` in `WebRoutes+Submission.swift`),
  rendered as a distinct callout in `submission.leaf` only on failing tests.

### Changed

- **Pattern-family scripts no longer bake hints into their output**
  (`PatternFamilyRenderer`); `generatedCaseHintLineExpr` and its ~20 injection
  sites are gone. The hint is decoupled from the test script — it's always
  current, styled distinctly, and works identically for native- and
  browser-graded results (both render through `submission.leaf`). This changes
  generated-script bytes (so `spec_hash` shifts on the next save), with no
  behaviour change to grading itself.

### Notes

- The authoring UI (a hint field in the notebook-check form, the restored
  per-case hint column for families, and a script hint field) lands with the
  suite-editor modal work; checks already round-trip a hint through `PUT /suite`
  since it carries the full check spec.

## [0.4.228] - 2026-05-22

### Changed

- **`TestItem` is now a proper Swift `enum`** (`Sources/Core/Models/TestItem.swift`).
  It was a `struct` wrapping a private `Payload` enum + a `type` discriminator;
  it's now `enum TestItem { case family(PatternFamily); case check(NotebookCheck) }`
  directly. The custom `Codable` is unchanged (`{ "type": …, "spec": … }`), so
  manifests round-trip identically — no migration. The `type` / `family` /
  `check` / `id` / `displayName` / `dependsOn` accessors are preserved (the
  `compactMap(\.family)` keypaths in `TestProperties` keep working); the
  `init(family:)` / `init(check:)` factory call sites become the `TestItem.family`
  / `TestItem.check` case constructors. Pure internal elegance — exhaustive
  `switch`es instead of optional wrangling, no behaviour change.

## [0.4.227] - 2026-05-22

### Removed

- **Retired the dedicated `PUT /families` and `PUT /checks` write endpoints
  (declarative suite, phase 3).** Since v0.4.226 the family and notebook-check
  modals save through the unified `PUT /suite`, so the standalone
  full-replace endpoints were dead weight. Removed (published + draft):
  `GET`/`PUT /instructor/:id/families`, `GET`/`PUT /instructor/:id/checks`,
  `PUT /instructor/new/draft/families`, `PUT /instructor/new/draft/checks`,
  along with the `applyPatternFamiliesEdit` / `applyNotebookChecksEdit`
  helpers and the `PublishedAssignmentRoutes+Families.swift` /
  `+Checks.swift` files. `PUT /suite` (`applySuiteEdit` → `applyPatternFamilies`)
  is now the single write surface for both. The `*/scripts` endpoints stay —
  raw-script *content* still travels through them until the suite-editor UI
  rework moves it onto `PUT /suite`. Family/check apply behaviour remains
  covered by `PatternFamilyApplyTests` (kernel) and `SuiteRouteTests`
  (`PUT /suite`); the obsolete `PatternFamilyRouteTests` and
  `DraftNotebookChecksRoutesTests` were removed, and the generated-file
  edit/delete guard was ported into `SuiteRouteTests`.

## [0.4.226] - 2026-05-22

### Changed

- **Pattern-family and notebook-check saves now go through the single
  `PUT /suite` write path (declarative suite, phase 2a).** Previously the
  family modal `PUT`ed `/families` and the check modal `PUT`ed `/checks`, each
  followed by a second `PUT /suite` (via `onFamiliesChange`/`onChecksChange`)
  to re-assert ordering and section placement — a double-write. Both modals now
  build the full item list and issue **one** awaited `PUT /suite`
  (`suite-table.js` `saveFamiliesViaSuite` / `saveChecksViaSuite`), then re-seed
  the table from the reconciled response. The modal still gets synchronous
  validation feedback (the save awaits the server result and surfaces errors
  inline), and on failure the optimistic row is rolled back. Family delete and
  check delete route through the same path. The check create/draft page no
  longer full-reloads on a check save. Raw scripts are unchanged — still
  `POST/PUT/DELETE /scripts`, and `PUT /suite` continues to send `content: nil`
  for them (Phase 1 leaves their files untouched), so there is no
  script-clobbering risk. The dedicated `PUT /families` / `PUT /checks`
  endpoints remain as a fallback and are retired in phase 3. No backend changes.

## [0.4.225] - 2026-05-22

### Added

- **Admin Storage tab now breaks footprint down per assignment.** Alongside
  the aggregate cards, a "By Assignment" table lists each assignment's
  test-suite bytes (the test setup archive, extracted support files, and any
  draft notebooks) and submission bytes (every submission graded against that
  setup), with a count and total, sorted largest-first — so an operator can
  see where disk is going, not just the volume totals. New per-id disk
  helpers (`topLevelFileSizesByID`, `testSetupSizesByID`) bucket the flat
  `<id>.<ext>` archives and the `shared/<id>/` + `notebooks/<id>/` subtrees.
- **Admin Users tab auto-refreshes.** The user table now polls
  `GET /admin/users-data` every few seconds and repaints in place so
  last-seen times and new/removed users stay current without a manual reload.
  Repaints pause while an admin is mid-interaction (focused on the table or
  filter) and on hidden tabs.

### Changed

- **System-generated dashboard polls no longer keep a session alive.**
  Auto-refresh requests (the new Users poll plus the existing Overview
  runner/metrics polls) send an `X-Background-Refresh` header;
  `UserActivityMiddleware` skips the `last_seen_at` update for those, so a
  dashboard left open in a tab can no longer keep an admin logged in past the
  idle timeout. Genuine navigation and clicks still refresh activity.
- **Every admin tab carries the Chickadee version stamp.** The version banner
  (previously only on Overview) now appears on Users, Storage, Audit Log, and
  Health Alerts for consistency.

## [0.4.224] - 2026-05-22

### Fixed

- **Active users no longer signed out mid-session under short idle timeouts.**
  `UserActivityMiddleware` refreshed `last_seen_at` on a fixed 60 s debounce.
  That's negligible under the 30-minute production ceiling, but when
  `SESSION_IDLE_TIMEOUT_MINUTES` is set low (e.g. 1, for testing the
  inactivity logout) the debounce was **≥ the ceiling**, so an actively
  browsing user's row never refreshed in time and `SessionIdleTimeoutMiddleware`
  logged them out mid-activity — with no warning, since a server-side logout
  can't show the client countdown. The debounce is now bounded to
  `min(60 s, timeout / 3)`, keeping it safely below the idle ceiling at any
  configured timeout while leaving production behaviour unchanged.

## [0.4.222] - 2026-05-21

### Added

- **`PUT /suite` can now carry raw-script content (declarative suite, phase 1).**
  Groundwork for routing every suite write through the single
  `GET`/`PUT /instructor/:id/suite` pair. `ScriptDTO` (and the internal
  `AuthoredRawScript`) gained an optional `content` field: on `PUT /suite` a
  script item that carries `content` has that body written into the test-setup
  zip (variables re-inlined for `.py`), so a hand-written script can be created
  or updated without a separate `POST /scripts`. On `GET /suite` — and in the
  assignment edit/create page seed — each raw script's body is now emitted
  (via an optional `zipPath` on `buildSuitePayload` / `suiteStateJSON`), so the
  editor has the complete declarative state without a per-file fetch. Purely
  additive: a script item with no `content` leaves the existing file untouched
  (variables still re-inlined), so the unchanged editor and the existing
  `POST/PUT/DELETE /scripts` + `PUT /families` + `PUT /checks` endpoints keep
  working exactly as before. Deletion reconciliation and endpoint retirement
  come in later phases.

## [0.4.221] - 2026-05-21

### Changed

- **Unified "+ Add Test" entry point for the suite editor.** Each suite
  section's toolbar previously carried three separate buttons — "+ Add
  Script", "+ Add Family", "+ Add Check". These collapse into a single
  **"+ Add Test"** button that opens a picker listing the available test
  *types* grouped by intent (test a function / test a value or data
  structure / test notebook structure & output / custom), in the
  instructor's mental model rather than the script-vs-family-vs-check
  implementation taxonomy. Choosing a type routes to the matching editor
  pre-seeded with that kind. New `Public/add-test-dispatcher.js` owns the
  picker modal; the notebook-check and pattern-family editors gained an
  optional `presetKind` argument to `open()`. First pass of the suite-editor
  unification — the picker hands off to the existing per-kind editors; a
  later pass folds the bodies into one morphing modal.
- **Notebook-check saves hot-sync the suite table.** Saving a notebook check
  no longer triggers a full page reload on the assignment edit page — the new
  row appears inline via `suite-table.js`'s `syncChecks()`, matching how
  pattern-family saves already behaved. (The create/draft page keeps its
  reload-based flow, consistent with how its family saves work there.)

## [0.4.220] - 2026-05-21

### Fixed

- **Hotfix: notebook cells containing `/` were silently dropped during native
  grading (v0.4.219 regression).** v0.4.219's per-cell `exec(compile(<source>))`
  encoded the cell source via `NotebookExtractor.pythonStringLiteral`, which
  used `JSONSerialization`. Foundation's JSON encoder escapes `/` as `\/` —
  valid JSON, but `\/` is **not** a valid Python escape. Because the literal is
  fed to `compile()` inside the generated module, any cell containing a `/`
  (e.g. `daily_l = daily_ml / 1000`) made that inner `compile()` raise
  `SyntaxError: unexpected character after line continuation character`, so the
  whole cell was caught-and-skipped and its variables went undefined. Students
  who had previously scored 100% dropped (e.g. to 67%) on retest once v0.4.219
  was deployed, failing exactly the checks for variables defined in a cell that
  used division. `pythonStringLiteral` now hand-escapes only the characters
  Python needs (`\`, `"`, `\n`, `\r`, `\t`, control chars) and passes `/` (and
  everything else) through unchanged. Native-only — the browser runner uses JS
  `JSON.stringify`, which does not escape `/`. Verified end-to-end against the
  affected student submission with the real Swift extractor.

## [0.4.219] - 2026-05-21

### Fixed

- **A syntax error (or an untouched comment-only cell) in one notebook cell no
  longer zeros the whole submission.** v0.4.218 wrapped each cell's body in
  `try/except`, which isolates *runtime* errors (e.g. `x = ____` → `NameError`)
  but not *syntax* errors: a single bad-syntax cell still failed the
  whole-module compile before any `try/except` could run, so the student got
  `0` on every question — including the ones they got right. A comment-only
  cell was even worse: `try:` + a lone comment is itself a `SyntaxError`
  (empty try body), so an untouched `# Your code here` cell zeroed the
  notebook.

  Both extractors now compile and execute **each cell as its own unit**:
  `exec(compile(<cell source>, "cell N", "exec"), globals())` wrapped in
  `try/except`. A syntax error is raised by `compile()` and caught per-cell —
  only that cell is skipped — and a comment-only cell compiles to a harmless
  empty unit. Runtime-error and incremental-progress isolation from v0.4.218 is
  preserved (now via the same per-cell `exec`), and the native runner keeps the
  `if __name__` quarantine so module-level `assert`/loops/`print()`/side effects
  still don't run at import. `exec(..., globals())` keeps every name at module
  scope, so functions/variables defined in one cell stay visible to later cells
  and to the test scripts. Tracebacks now carry clean `cell N` filenames.
  Verified against real student submissions: each now scores its correct cells,
  with a single broken cell skipped. (`NotebookExtractor.swift`
  `wrapCellForResilientLoad`, `Public/browser-runner.js` `extractPythonCell`.)

### Notes

- Submission-extraction change only — instructor test setups, generated test
  scripts, manifests, `spec_hash`, and the `TestSetupCache` are untouched, so
  no test suites need regenerating. Existing submissions pick up the fix on
  **retest** (re-extraction runs fresh on every grade); new submissions get it
  automatically. Backwards compatible: a submission that already graded
  correctly produces the same names and quarantine behavior, so no grade
  regresses.

## [0.4.218] - 2026-05-21

### Fixed

- **One broken notebook cell no longer fails every test.** Browser-graded labs
  extract the student notebook into a single Python module that the test
  scripts import. Previously every cell was concatenated raw, so one cell that
  raised at import time — an unfilled `x = ____` placeholder, or a reference to
  a variable the student hasn't defined yet — aborted the *entire* module load.
  `student_module` became `None` and every `variableExists`/function check
  reported "not defined", including tests for cells the student got right.
  Each Python cell is now wrapped in its own `try/except` during extraction
  (`extractPythonCell` in `Public/browser-runner.js`), so a failing cell only
  withholds the names *it* would have defined; correct cells still load and
  their tests still pass. IPython magics (`%`/`!`) are stripped (they are
  SyntaxErrors in plain Python and would break the whole-file compile, which
  `try/except` cannot catch); `from __future__` imports stay unwrapped at
  module top. The native worker's `NotebookExtractor.sanitizeCellForModule`
  applies the same per-cell wrapping for parity with the browser backstop.
- **Raw JSON result envelope no longer leaks into student-facing output.** The
  native runner already strips the trailing machine-readable JSON line that
  `test_runtime`'s `failed()`/`errored()` print after the human-readable
  message, but the browser runner returned raw stdout — so students saw the
  `{"shortResult": …, "status": …}` blob beneath the message. `runPyScript`
  now strips that footer line before building `longResult`, matching
  `RunnerDaemon+JobProcessing.swift`.

### Changed

- **Browser/native runner parity hardening.** Two long-standing divergences
  between the browser (Pyodide) runner and the native worker were closed so
  the two grade consistently: (1) `require_function`'s no-module path in the
  browser's embedded `test_runtime` now prints the load traceback and reports
  `"SyntaxError in submission"`, matching the canonical/native copy (it had
  drifted to a generic "could not load" message); (2) the browser runner now
  maps process exit code `3` to `fail` (the Marmoset `chickadee.py` convention)
  instead of `error`, via a shared `statusFromExitCode` helper. Added
  `Tools/runner-support/sitecustomize.py` as the canonical source for the
  bootstrap that both runners embed.
- **Drift guards for the duplicated runtime helpers.** New tests fail CI if the
  embedded `test_runtime`/`sitecustomize` copies in
  `Sources/Worker/TestRuntimeSources.swift` or `Public/browser-runner.js` drift
  (in executable code) from the canonical `Tools/runner-support/*` sources
  (`Tests/WorkerTests/RuntimeSourceDriftTests.swift`,
  `Tests/BrowserRunnerJSTests/runtime-drift.test.mjs`).
- **Output-interpretation contract corpus.** The native stdout/stderr/exit-code
  → status/shortResult/longResult logic was extracted into a pure
  `interpretScriptOutput` function. A shared fixture corpus
  (`Tests/Fixtures/output-contract.json`) is run against both runners
  (`Tests/WorkerTests/OutputContractTests.swift`,
  `Tests/BrowserRunnerJSTests/output-contract.test.mjs`): grading `status` must
  be identical across runners and neither may leak the raw JSON envelope into
  student-facing strings. (The `shortResult`/`longResult` *formatting* still
  differs between runners — tracked for a future unification.)

## [0.4.217] - 2026-05-21

### Changed

- **Admin dashboard split into navigable tabs.** A tab bar now sits atop
  every admin page, replacing the ad-hoc buttons. The dashboard is divided
  into: **Overview** (`/admin` — diagnostics
  cards, Runners, Courses), **Users** (`/admin/users`), **Storage**
  (`/admin/storage`), **Audit Log** (`/admin/audit`), and **Health Alerts**
  (`/admin/alerts`). The Users table and the v0.4.216 Storage panel moved off
  the single monolithic dashboard into their own routes/views
  (`admin-users.leaf`, `admin-storage.leaf`), each with a self-contained
  script. The tab-bar markup is inlined per page rather than a Leaf fragment
  (LeafKit 1.x raises a false-positive cycle error on `#extend` of a shared
  partial here). Side benefit: the Storage directory walk + DB-size query now
  run only when the Storage tab is opened rather than on every dashboard load.

## [0.4.216] - 2026-05-21

### Added

- **Admin storage breakdown panel.** The admin dashboard now shows a
  **Storage** section with the on-disk footprint of each persistent-volume
  sink (Submissions, Test Setups, Results & Logs, Static Assets) plus the
  database size, a running total, and the active DB backend. Directory walks
  run on the thread pool so the page stays responsive; sizes are computed by a
  new `Sources/APIServer/Utilities/DiskUsage.swift` helper
  (`directorySizeBytes`, `databaseSizeBytes`, `humanReadableBytes`). This is
  the first step toward a submission-retention policy — it surfaces where the
  volume is actually being consumed so retention can be tuned from real data.

### Changed

- **Result JSON is no longer duplicated to disk.** Previously every
  `TestOutcomeCollection` was written both to the authoritative
  `results.collection_json` DB column *and* to a never-read
  `{submissionID}_{timestamp}.json` file under `results/` (a debug aid that
  grew unbounded — one file per submission per retest). The disk write is
  removed, and a one-time startup sweep (`sweepLegacyResultDumps`) reclaims the
  accumulated `*.json` dumps on first boot, logging bytes freed. Runner/server
  `*.log` files in the same directory are left untouched.

## [0.4.215] - 2026-05-21

### Added

- **Visible inactivity logout with a warning countdown.** When an
  authenticated user goes idle, a warning modal now appears
  `SESSION_IDLE_WARNING_SECONDS` (default 120) before the ceiling, showing a
  live countdown and a **Stay signed in** button. Clicking it calls a new
  `POST /session/keepalive` endpoint that refreshes `last_seen_at` and resets
  the clock; ignoring it logs the user out with a visible "Signing you out…"
  transition rather than the previous silent redirect-on-next-click. The
  warning window is clamped to stay strictly below the timeout.

### Changed

- **Closing the browser now ends the session.** The session cookie is
  session-scoped (no `Expires`/`Max-Age`) instead of persisting for a week, so
  the browser drops it on close. The idle timeout remains the backstop for
  session-restore browsers that resurrect the cookie.
- **Idle watchdog rewritten to actually fire at the ceiling.** `idle-logout.js`
  now tracks an absolute deadline and re-evaluates on
  `visibilitychange`/`focus`/`pageshow`, not just a polling interval. A tab
  that was backgrounded (where browsers freeze timers) past the idle ceiling is
  now signed out the instant it is refocused, with no click required —
  previously the client watchdog could miss the mark entirely and only the
  server-side gate caught it on the next request.
- **In-notebook work counts as activity.** Keystrokes inside the JupyterLite
  editor iframe (which never reach the parent window) are bridged to the
  watchdog and send a throttled keep-alive, so a student actively editing is no
  longer treated as idle.
- **Cross-tab session sync.** Activity, extend, and logout are mirrored across
  open tabs via `BroadcastChannel`, so an idle background tab can't expire a
  session the user is actively using elsewhere.

## [0.4.214] - 2026-05-20

### Changed

- **Less redundant work per worker job claim and per notebook normalization**
  (no behaviour change). (1) When the worker collects claim candidates, it
  resolves each test-setup row and decodes its manifest once per
  `testSetupID` and reuses the result, instead of re-querying the row and
  re-decoding the identical manifest JSON for every pending submission
  targeting the same assignment — the common shape when a class submits before
  a deadline. (2) `SubmissionNormalizer` now reads and parses an uploaded
  notebook once: the parsed JSON is carried from classification into extraction
  via `DetectedSubmissionKind.jupyterNotebook([String: Any])`, eliminating a
  duplicate `Data(contentsOf:)` read + JSON parse of the same file.

## [0.4.213] - 2026-05-20

### Changed

- **Indexes for hot-path filters that scan unbounded-growth tables.** Several
  recurring queries did full-table scans: the BrightSpace grade-sync sweep
  (every 60s) filtering `results` on `brightspace_sync_pending`, the
  stuck-submission reaper filtering `submissions` on `status` + `assigned_at`,
  and the admin runner dashboard / rolling-average queries filtering
  `runner_snapshots` and `job_execution_metrics` by runner. A new
  `CreateHotPathIndexes` migration adds covering indexes:
  `results(brightspace_sync_pending, brightspace_pending_since)`,
  `submissions(status, assigned_at)`,
  `runner_snapshots(runner_id, recorded_at)`, and
  `job_execution_metrics(runner_id, completed_at)`. Idempotent
  (`CREATE INDEX IF NOT EXISTS`), registered last so its target tables already
  exist; no schema or behaviour change.

## [0.4.212] - 2026-05-20

### Fixed

- **The "Login with UWaterloo" button now works on the post-logout login
  page.** v0.4.211 stopped SSO-only mode from auto-redirecting `/login` into
  the SSO flow (so logout actually lands on the login form), which surfaced
  the SSO sign-in button for the first time. That button was a GET `<form>`
  submitting to `/auth/sso/start`, which 303-redirects to the IdP's
  authorization endpoint — but browsers enforce the `form-action` CSP
  directive across the whole redirect chain, and only the `end_session`
  origin was allow-listed, so the redirect to the authorization endpoint (and
  any 2FA/consent hops) was silently blocked. The button is now a plain
  navigation link (`<a href="/auth/sso/start">`), which `form-action` does not
  govern — matching how the old auto-redirect reached the IdP.

## [0.4.211] - 2026-05-20

### Added

- **Client-side 30-minute inactivity auto-logout.** `SessionIdleTimeoutMiddleware`
  already dropped idle sessions, but only on the *next* request — a user sitting
  idle on a page was never actually signed out or redirected. New
  `Public/idle-logout.js` watches for user input and, once the configured idle
  ceiling is reached, saves any open notebook (best-effort, via the new
  `window.chickadeeSaveNotebook` hook in `notebook.js`) then submits logout so
  the full server-side sign-out runs and the browser lands on the login page
  with an inactivity message. The ceiling is shared with the server through the
  new `#sessionIdleTimeoutSeconds()` Leaf tag
  (`<meta name="session-idle-timeout-seconds">`), so client and server enforce
  the same `SESSION_IDLE_TIMEOUT_MINUTES` (default 30). The script stays dormant
  when the gate is disabled (value 0) and only loads for authenticated pages.

### Fixed

- **The logout button now reliably lands on the login page with a clear
  confirmation.** Logout already redirected to `/login`, but in SSO mode
  `/login` immediately restarted the SSO flow (`/auth/sso/start`), silently
  re-authenticating the user — so the button felt broken. `/login` now stays on
  the form (showing "You have been signed out.") when the request arrives from a
  logout (`?loggedout=1`) or an inactivity timeout (`?error=timeout`), and the
  logout handler's post-logout redirect — including the SSO
  `post_logout_redirect_uri` — carries the marker so the user reliably ends up
  on the Chickadee login page.

## [0.4.210] - 2026-05-20

### Changed

- **Admin dashboard counts now aggregate in the database instead of loading
  whole tables into memory.** `makeWorkerRows` (the `/admin/runners` table)
  loaded the *entire* `submissions` table via `.all()` and tallied
  assigned/processed counts per worker in a Swift loop — a full-table scan that
  grows every term. It now issues a single `GROUP BY worker_id, status` count.
  Likewise `assignmentCountsByCourse` (admin course cards) replaced its
  load-all-assignments-then-loop with a `GROUP BY course_id` count. Both fall
  back to the previous in-memory tally on a non-SQL driver (none ship today).
  No change to displayed numbers; covered by new dual-backend tests
  (`assignmentCountsByCourseGroupsPerCourse`,
  `adminRunnersCountsAssignedAndProcessedPerWorker`) that run against both
  SQLite and Postgres in CI.

## [0.4.209] - 2026-05-20

### Changed

- **Submission intake no longer blocks the cooperative thread pool on disk
  I/O or notebook merging.** `POST /api/v1/submissions` and
  `POST /api/v1/submissions/file` wrote the decoded upload to disk with a
  synchronous `Data.write(to:)` directly in the async request handler, and the
  `.ipynb` path additionally read the instructor notebook and merged its
  authoritative test cells inline (synchronous `Data(contentsOf:)` plus a
  JSON parse/merge/serialize). Under a deadline-spike of concurrent
  submissions, that synchronous work serialized request handling on the
  cooperative executor. Both file writes now go through `req.fileio.writeFile`
  (the NIO thread pool, matching `ResultRoutes`), and the instructor-notebook
  read + merge run on `req.application.threadPool`. A new `Sendable`
  `NotebookSourceRef` snapshot lets a new `notebookData(from:)` overload
  resolve the notebook off the cooperative executor without capturing the
  non-`Sendable` `APITestSetup` Fluent model; `notebookData(for:)` now
  delegates to it. No change to what is stored or graded.

## [0.4.208] - 2026-05-20

### Fixed

- **HTTPS enforcement no longer blocks the internal worker API.** When
  `ENFORCE_HTTPS=true`, the global `HTTPSRedirectMiddleware` ran on every
  request — including the runner's plain-HTTP `POST /api/v1/worker/*` polls on
  the internal Docker network (no TLS, no `X-Forwarded-Proto`) — and rejected
  them with `426 Upgrade Required` before `WorkerHMACAuthMiddleware` could
  authenticate them. The runner retried forever and never registered in the
  admin dashboard. The middleware now exempts the HMAC-authenticated worker
  endpoints (`/api/v1/worker/*`) and the container healthcheck (`/health`) from
  HTTPS enforcement, since both are internal service-to-service calls that
  legitimately speak plain HTTP. Covered by `workerPostPassesThroughOverPlainHTTP`
  and `healthGetPassesThroughOverPlainHTTP`. This is what lets a co-located
  runner use `--api-base-url http://server:8080` (the internal Docker service)
  with HTTPS enforcement left on, instead of being forced through the public
  TLS endpoint.

### Changed

- **`docker-compose.yml` forwards `OUTBOUND_HTTP_PROXY` to the server.** v0.4.205
  added app-side support for routing the outbound HTTP client (OIDC discovery /
  JWKS / token, BrightSpace) through a forward proxy, but the var was never
  listed in the server service's `environment:` block, so it could not reach the
  container even when set in `.env`. Added the passthrough and documented it in
  `.env.example`.

## [0.4.207] - 2026-05-20

### Changed

- **`PUT /suite` is now authoritative for the whole test-item list — scripts,
  pattern families, AND notebook checks (Phase B of the test-item
  unification).**  Previously a suite save only persisted check *positions*
  (id + sectionID); check *specs* had to be saved separately through
  `PUT /checks`.  `applySuiteEdit` now collects each check row's spec into a
  full-replace `nextChecks` list (symmetric with `nextFamilies`), so a single
  suite save round-trips scripts, families, and checks together.  The editor
  already sends every row's current spec in the `PUT /suite` body (the seed is
  refreshed after each modal save), so this is a server-only change with no
  client change required; the dedicated `PUT /checks` endpoint stays for the
  check modal.  Covered by `put_suitePersistsChangedCheckSpec` and
  `put_suiteOmittingCheckRemovesIt`.

## [0.4.206] - 2026-05-20

### Added

- **Unified `TestItem` manifest model (Phase A of the test-item unification).**
  Pattern families and notebook checks are now both represented by a single
  `TestItem` type in Core — a tagged union (`.family(PatternFamily)` /
  `.check(NotebookCheck)`) with shared envelope accessors (`id`,
  `displayName`, `dependsOn`, `type`). `TestProperties` gains a `testItems`
  list as the canonical source of truth; `patternFamilies` / `notebookChecks`
  become derived views so every existing read site keeps working unchanged.

### Changed

- **Manifests now persist a `testItems` array.** Legacy manifests (which carry
  separate `patternFamilies` / `notebookChecks` arrays) migrate to `testItems`
  on read; `encode` mirrors both legacy keys back out (derived from
  `testItems`, so they can't drift) for cross-version readers, and
  `makeWorkerManifestJSON` emits `testItems` in authored order.
  `runnerSanitized()` empties `testItems` exactly as it already empties the
  family/check lists, so runners never decode a `PatternKind` /
  `NotebookCheckKind` case they don't know. No behaviour change for the
  runner, the grading pipeline, or generated script bytes.

## [0.4.205] - 2026-05-20

### Added

- **`OUTBOUND_HTTP_PROXY` — route the server's outbound HTTP client through a
  forward proxy.**  On networks where direct egress is blocked and all traffic
  must traverse a proxy (e.g. the UWaterloo NAT'd VLAN), the OIDC discovery
  fetch at startup `connectTimeout`s and crash-loops the server, because Vapor's
  HTTP client (AsyncHTTPClient) ignores the standard `HTTP_PROXY`/`HTTPS_PROXY`
  env vars and the Docker daemon proxy only covers image pulls.  Setting
  `OUTBOUND_HTTP_PROXY` (e.g. `http://172.16.136.36:3128`) now applies the proxy
  to `app.http.client` before first use, so OIDC discovery/JWKS/token calls —
  and BrightSpace grade-sync — go through it.  Flows through `AppConfig`
  (`appConfig.outboundProxy`) and is reported in the redacted startup summary.
  Unset = direct egress, unchanged behaviour.

## [0.4.204] - 2026-05-20

### Changed

- **The instructor dashboard "Students With Browser Errors" card now counts
  only students who are *actually stuck*, not everyone who hit a transient
  hiccup.**  The in-browser editor records a client diagnostic
  (`preflight_fail` / `watchdog_timeout`) even when the student reloads and
  submits fine, so a slow Pyodide cold start that clears on reload was
  inflating the card.  A student who errored on a setup but then got a
  submission in for that setup is now treated as recovered and excluded;
  what remains is the set of students who errored and never submitted —
  the signal an instructor can act on.  Diagnostics are still scoped to the
  course's setups, the 24h window, active students, and a non-null
  `test_setup_id`, exactly as before.

## [0.4.203] - 2026-05-20

### Added

- **`scripts/restore-from-share.sh`** — version-controls the consumer-side
  wrapper a non-production box runs from cron to track production data: it
  rsync's the latest snapshot down from the shared mount, finds the newest
  *complete* snapshot, and restores it via `scripts/restore.sh`
  (`--yes --regenerate-secrets`). Idempotent (a `.last-restored` marker skips a
  snapshot already restored) and a clean skip when the share isn't mounted. The
  share path and PII scrubbing are configurable via
  `CHICKADEE_SNAPSHOT_SHARE_MOUNT` / `CHICKADEE_SNAPSHOT_SHARE_DIR` /
  `CHICKADEE_RESTORE_SCRUB_PII`, defaulting to the UWaterloo AHS share and no
  scrub. Pairs with `snapshot.sh` (producer) and `restore.sh` (engine).

## [0.4.202] - 2026-05-20

### Internal

- **Forward-chain regression test for the namespace reconciler.**  Adds
  `appliesNewMigrationsForwardAfterReconcile`, which simulates a database that is
  *behind* (a recent migration reverted + its history row removed) and recorded
  under a legacy namespace, then asserts that after
  `reconcileLegacyMigrationNamespace` the already-applied migrations are
  recognized AND the missing one is applied forward by `autoMigrate` without a
  collision — the 0.4.172→latest restore scenario in miniature. Complements the
  real-world coverage from the nightly restore-from-share on prod data.

## [0.4.201] - 2026-05-20

### Changed

- **Migration identifiers are now module-independent, so a future module rename
  can't break migration history again.**  Fluent's default migration `name` is
  `String(reflecting: Self.self)` (module-qualified), which is exactly why the
  `chickadee-server` → `APIServer` split orphaned every history row.  All 23 of
  our migrations now adopt a `ChickadeeMigration` protocol whose `name` is pinned
  to `"chickadee.<TypeName>"`, decoupled from the Swift module.  Vapor's own
  migrations (e.g. `SessionRecord`) are unaffected.
- **`reconcileLegacyMigrationNamespace` now maps both legacy namespaces** —
  `chickadee_server.*` (executable-module era) and `APIServer.*` (library-split
  era, v0.4.198–0.4.200) — onto `chickadee.*`.  Still idempotent and a no-op on
  fresh/already-canonical databases; the first boot of this build rewrites an
  older database's history once.

## [0.4.200] - 2026-05-20

### Changed

- **Snapshots now record the *running* build's identity, and `restore.sh`
  checks it against the build it's restoring into.**  `snapshot.sh` previously
  recorded only `chickadee_version` from the source-tree `VERSION` file, which
  can drift from the image actually deployed (a stale `:latest`, a cloned VM).
  The manifest now also carries `build_version` (from the running server's
  `/health`) and `image_ref` / `image_digest` (from the running container).
  `restore.sh` reads those, compares them against the build currently running
  on the target host (its `/health` version and image digest), and warns —
  requiring `--yes` — when they differ.  This catches the exact skew that was
  previously invisible: a snapshot's data being restored into a *different*
  build than the one that produced it, where the `VERSION` files happened to
  match.  Old snapshots without the new fields still restore (the check is
  skipped when either side's identity is unknown).

## [0.4.199] - 2026-05-20

### Fixed

- **`WorkerTests` intermittent `SIGABRT` (signal 6) under parallel
  execution.**  The `rscriptAvailable()` helper launched a `Process`
  (`/usr/bin/env Rscript --version`) with `try? proc.run()`, swallowing
  any launch error, then unconditionally read `proc.terminationStatus`.
  When `run()` intermittently failed — e.g. `posix_spawn` returning
  `EAGAIN` under the spawn pressure of Swift Testing's default in-suite
  parallelism, where the R / zip / runner subprocess tests all fork at
  once — `terminationStatus` on a never-launched task raised an uncaught
  Objective-C `NSInvalidArgumentException` (`task not launched`) that
  aborted the whole test process (~1 in 12 local runs, and reproducible
  in CI's `swift test --filter WorkerTests`).  The helper now guards the
  launch in `do/catch` and returns `false` (skip the optional R tests)
  when the process fails to start, so `terminationStatus` is only read
  after a confirmed launch.  Test-only; no production code touched.

## [0.4.198] - 2026-05-20

### Fixed

- **Latest builds can now migrate a database created by a pre-rename build
  (e.g. a restored v0.4.172 snapshot).**  Fluent identifies a migration by its
  module-qualified type name (`<module>.<Type>`).  When the server code was
  refactored out of the `chickadee-server` executable module into the
  `APIServer` library target, every migration identifier changed from
  `chickadee_server.*` to `APIServer.*`.  A database produced by the old build
  records `chickadee_server.CreateUsers`; the current build looked for
  `APIServer.CreateUsers`, decided it was unapplied, re-ran `CreateUsers`, and
  crash-looped on `CREATE TABLE "users"` (Postgres `42P07`).  A new idempotent
  reconciliation step (`reconcileLegacyMigrationNamespace`) runs between
  `registerMigrations` and `autoMigrate`, rewriting legacy-namespace history
  rows to the current module's namespace (dropping any duplicate rather than
  colliding).  No-op on fresh databases and when no legacy rows are present.

## [0.4.197] - 2026-05-20

### Internal

- **CI: only run the Docker image build on PRs that can affect the image.**
  `Build and Push Docker Image` is the longest job in the suite (~10–18 min
  on PRs), and it already builds + Trivy-scans without pushing on PRs.  Its
  `pull_request` trigger is now `paths`-filtered to the inputs that can
  actually change the build or the scan result — `Dockerfile`,
  `Package.swift`, `Package.resolved`, `docker-compose.yml`, `deploy/**`,
  and the workflow file itself — so the ~90% of PRs that only touch
  `Sources/`, `Tests/`, or front-end assets no longer pay for it.  The
  `push` (main) and tag triggers stay unconditional, so every merge to main
  and every release tag still gets a full build + Trivy scan + push; that
  also keeps catching base-image CVE drift independent of code changes.  The
  release *compile* signal dropped from source-only PRs is already covered
  by the debug build in `swift-tests.yml`.  (`main` has no required status
  checks, so a skipped run does not block PR merges.)

- **CI: cancel superseded in-progress Docker runs on PRs.**  Added a
  `concurrency` group to `docker-build.yml` keyed on workflow + ref with
  `cancel-in-progress` gated to `pull_request` events, so re-pushing a PR
  cancels its prior in-flight run instead of queueing a second copy of the
  longest job.  `main` and tag builds are never cancelled — they push
  images and must not be interrupted mid-flight.

- **CI: action bumps (supersedes Dependabot #315, #423).**
  `actions/setup-node@v5 → v6` (`swift-tests.yml`) and
  `aquasecurity/trivy-action@v0.35.0 → v0.36.0` (`docker-build.yml`).
  Both are drop-in: setup-node v6 stays on Node 24 with the same inputs,
  and trivy-action v0.36.0 only bumps the bundled Trivy binary (no
  action-interface change to the `image-ref` / `severity` / `exit-code`
  inputs we use).

## [0.4.196] - 2026-05-20

### Internal

- **CI: migrate every Node.js 20 GitHub Action to Node.js 24.**  GitHub is
  forcing Node.js 20 JavaScript actions onto Node.js 24 starting 2026-06-02
  and removing the Node 20 runtime from runners on 2026-09-16
  ([changelog](https://github.blog/changelog/2025-09-19-deprecation-of-node-20-on-github-actions-runners/)).
  Bumped every action that still declared `runs.using: node20`:
  - `actions/upload-artifact@v4 → v7` (`docker-build`, `zap-baseline`) —
    the action that produced the visible deprecation warning.
  - `actions/download-artifact@v4 → v8` (`docker-build`).  v8 defaults a
    download hash mismatch to *error* (was warn); harmless for the
    same-workflow zipped upload→download here.
  - `actions/setup-python@v5 → v6` (`jupyterlite`).
  - `softprops/action-gh-release@v2 → v3` (`release`).
  - `codecov/codecov-action@v5 → v6` (`test-coverage`) — v5 is a composite
    action that internally pinned `actions/github-script@v7.0.1` (Node 20);
    v6 moves it to github-script v8 (Node 24), so it was a hidden offender.

  Already on Node 24 and left unchanged: `actions/checkout@v6`,
  `actions/cache@v5`, `actions/setup-node@v5`, `github/codeql-action@v4`,
  and the `docker/*` actions; `aquasecurity/trivy-action` is a composite
  action with no Node runtime.  `upload-artifact@v6+` /
  `download-artifact@v7+` require Actions Runner ≥2.327.1, satisfied by the
  GitHub-hosted `ubuntu-latest` runners these jobs use.  Supersedes
  Dependabot PRs #368, #316, #314.

## [0.4.195] - 2026-05-20

### Fixed

- **`WorkerTests` env-passthrough race (follow-up to v0.4.194).**  v0.4.194
  serialized `WorkerDaemonTests`' env mutation but left the two env tests in
  `WorkerTests` unguarded.  `scriptEnvVarUnsetWhenNoOverride` calls
  `unsetenv("CHICKADEE_ASSIGNMENT_SEED")`, while `scriptReceivesEnvVarFromRunner`
  drives `UnsandboxedScriptRunner`, whose `mergedScriptEnvironment` reads
  `ProcessInfo.processInfo.environment` (walking the C `environ` array) to build
  the child env.  Under Swift Testing's in-suite parallelism the unset could
  clobber `environ` while the other test read it back, so both env regions now
  run under the same process-wide `withEnvLock`
  (`Tests/WorkerTests/Support/EnvTestLock.swift`).  The unset test also restores
  the prior `CHICKADEE_ASSIGNMENT_SEED` value on exit instead of leaving it
  cleared.  Test-only; no production code touched.

## [0.4.194] - 2026-05-20

### Fixed

- **`WorkerDaemonTests` env-var race.**  The
  `workerDaemonRetriesPollingAfter*` tests mutate the process-global
  `RUNNER_RETRY_*` environment variables (the daemon reads its retry
  policy from `ProcessInfo`), but Swift Testing parallelizes tests within
  a suite, so two of them could clobber each other's env while a spawned
  daemon was reading it back.  Routed the suite's `withEnvironment` helper
  through a new process-wide `withEnvLock`
  (`Tests/WorkerTests/Support/EnvTestLock.swift`), mirroring the existing
  `withMockURLProtocolLock` and the APITests `withAsyncEnvLock` — the
  set → run → restore region of one env-mutating test now never overlaps
  another's.  Test-only; no production code touched.

## [0.4.193] - 2026-05-20

### Internal

- **CI: Docker image build no longer recompiles from scratch (#523
  follow-up).**  The `build-and-push` job used to `swift build -c release`
  *inside* the Dockerfile, so any `Sources/` change busted the compile
  layer and triggered a cold ~13-min release rebuild on every push.  The
  release compile now happens in a dedicated `build-release` job that uses
  the same `actions/cache` + `git-restore-mtime` incremental scheme as the
  `build` job in `swift-tests.yml` (its own `-release-` cache namespace,
  keyed on `Sources/**` + manifest — Tests don't affect it).  It uploads
  the two static binaries as a workflow artifact; `build-and-push` then
  just downloads them and assembles the runtime image (seconds).

- **`Dockerfile` binary source is now a build arg.**  `ARG BINARIES`
  selects between `compile` (default — build from source in-image, used by
  `docker build .` and `docker compose up --build`) and `prebuilt` (copy
  the binaries CI staged in `./artifacts/`).  BuildKit prunes the unused
  stage, so a `prebuilt` build never pulls the Swift toolchain image.
  Standalone and dev builds are unchanged; only CI passes
  `--build-arg BINARIES=prebuilt`.  Debug-for-tests and release-for-ship
  remain two separate cached compiles — tests are never built in release,
  which would weaken the test signal.

## [0.4.192] - 2026-05-20

### Fixed

- **Nightly clean-build coverage flake in `WorkerDaemonTests`.**  The
  daemon polling gates (`workerDaemonCanBeCancelledWhilePollingForNoWork`,
  `workerDaemonRetriesPollingAfterTransientHTTP500`, et al.) waited on a
  spawned `Task { daemon.run() }` to poll within a 2–4s window.  On the
  cold-cache nightly — where all ~1280 tests run in parallel on a
  saturated cooperative thread pool — that Task can be starved for
  several seconds before it first runs, so the gates intermittently
  timed out (one run failed `didPoll` / `didKeepPolling` while the
  identically-shaped HTTP401 and duplicate-worker-ID variants passed,
  confirming timing variance rather than a logic bug).  Widened every
  `waitUntil` window in the suite to a uniform 10s.  `waitUntil`
  short-circuits the instant its condition holds (the tests still pass
  in ~0.05s locally), so the larger ceiling costs passing runs nothing
  and only buys slack on a loaded machine.

## [0.4.191] - 2026-05-20

### Internal

- **CI: true incremental builds via `git restore-mtime`, plus a nightly
  clean-build canary (#523 follow-up).**  The `build` job in
  `swift-tests.yml` already restored a prior `.build/` on a content-hash
  miss, but `actions/checkout` stamps every source file with a fresh
  mtime, so llbuild treated all sources as changed and recompiled from
  scratch.  The job now checks out full history (`fetch-depth: 0` +
  `filter: blob:none`, so the vendored Pyodide blob isn't pulled) and
  runs `git restore-mtime` to reset each file's mtime to its last-commit
  time.  llbuild then recompiles only the files touched by new commits —
  a typical source-only PR drops the `build` job from a near-cold
  recompile to a small incremental one.

- **`test-coverage.yml` is now the documented clean-build canary.**  It
  compiles the whole package from scratch nightly (caches only
  `.build/checkouts`, never compiled artifacts, and uses the `-spm-`
  key namespace, never the `-build-` one), so it catches any break that
  the per-PR incremental cache could mask via a stale object.  A new
  `report-failure` job opens (or comments on) a deduplicated
  "Nightly clean build failing" tracking issue when the run fails, so a
  dirty-cache regression surfaces as an actionable item instead of a
  red run no one watches.  The workflow is renamed
  "Nightly Clean Build & Coverage" to reflect the dual purpose.

## [0.4.190] - 2026-05-19

### Internal

- **CI: shared build job caches compiled `.build/` across Swift test
  jobs (#523).**  Previously every Swift test job in
  `swift-tests.yml` (`core-tests`, `api-tests`, `api-tests-postgres`,
  `worker-tests`) did a full compile from scratch — roughly 40 minutes
  of wall-clock compile time per PR across five near-identical Linux
  containers building the same package graph.

  A new `build` job now compiles the whole package plus all test
  targets once (`swift build --build-tests`) and caches the resulting
  `.build/` tree.  Each test job declares `needs: build`, restores that
  cache, and runs `swift test --skip-build --filter <Target>`, skipping
  the compile entirely on a cache hit.

  Cache key combines the toolchain fingerprint (`swift --version`) with
  a content hash of `Package.resolved`, `Package.swift`, `Sources/**`,
  and `Tests/**`.  `restore-keys` lets a content-hash miss restore the
  most recent prior `.build/` for the same toolchain, so a miss
  recompiles incrementally rather than cold — no slower than today.
  Each test job falls back to a plain `swift test` build if the cache
  is unexpectedly absent.

  The `build` job's status is intended to be a required check so a
  compile break surfaces once instead of fanning out to four red test
  jobs (configure in branch protection).

  Out of scope: the `docker-build` / `release` Docker pipelines and the
  nightly `test-coverage` workflow, which exercise different build
  paths.  `worker-tests` stays sequential (no `--parallel`) — the
  MockURLProtocol global-state constraint is unchanged.

## [0.4.189] - 2026-05-19

### Internal

- **Per-kind handler registry for `PatternKind` / `NotebookCheckKind`.**
  Replaced the parallel `switch family.kind` / `switch check.kind`
  dispatch — previously smeared across `PatternFamilyRenderer`,
  `PatternFamilyValidator`, `NotebookCheckRenderer`, and
  `NotebookCheckValidator` — with two per-kind handler protocols
  (`PatternKindHandler`, `NotebookCheckKindHandler`), one conforming
  type per case, each resolved through a single exhaustive
  switch-factory (`patternKindHandler(for:)`,
  `notebookCheckKindHandler(for:)`).  Adding or changing a kind now
  touches one handler plus its resolver, and a new enum case fails to
  compile until the resolver gains an entry — restoring the
  compile-time exhaustiveness the scattered switches provided.

  The two enums stay the Codable wire format unchanged (raw values
  byte-identical; `Sources/Core` untouched), so stored manifests and
  `.chickadee` bundles are unaffected.  Render bodies stay in place and
  the handlers delegate to them, so generated script bytes — and
  therefore every `spec_hash` header and runner-side `TestSetupCache`
  key — are identical.  Pure structural refactor: no behaviour change.

## [0.4.188] - 2026-05-19

### Internal

- **Renamed `AssignmentRoutes+*.swift` files to match their new
  parent collections.**  Phase 2 split `AssignmentRoutes` into 5
  `RouteCollection`s but kept the existing `AssignmentRoutes+*.swift`
  filenames for `git blame` continuity.  Sixteen files since extended
  a different collection from what their name suggested; this PR
  closes the deferred file-rename item by aligning the names.

  Renames (all via `git mv`, blame preserved):

    - `AssignmentRoutes.swift` →
      `InstructorDashboardRoutes.swift`
    - `AssignmentRoutes+List.swift` →
      `InstructorDashboardRoutes+List.swift`
    - `AssignmentRoutes+Submissions.swift` →
      `InstructorDashboardRoutes+Submissions.swift`
    - `AssignmentRoutes+NewAssignment.swift` →
      `DraftAssignmentRoutes+NewAssignment.swift`
    - `AssignmentRoutes+NewPage.swift` →
      `DraftAssignmentRoutes+NewPage.swift`
    - `AssignmentRoutes+SaveValidation.swift` →
      `DraftAssignmentRoutes+SaveValidation.swift`
    - `AssignmentRoutes+Draft.swift` →
      `DraftAssignmentRoutes+SuiteEditing.swift`
    - `AssignmentRoutes+DraftSections.swift` →
      `DraftAssignmentRoutes+Sections.swift`
    - `AssignmentRoutes+Suite.swift` →
      `PublishedAssignmentRoutes+Suite.swift`
    - `AssignmentRoutes+SuiteSections.swift` →
      `PublishedAssignmentRoutes+SuiteSections.swift`
    - `AssignmentRoutes+Checks.swift` →
      `PublishedAssignmentRoutes+Checks.swift`
    - `AssignmentRoutes+Families.swift` →
      `PublishedAssignmentRoutes+Families.swift`
    - `AssignmentRoutes+GlobalVariables.swift` →
      `PublishedAssignmentRoutes+GlobalVariables.swift`
    - `AssignmentRoutes+Sections.swift` →
      `CourseAdminRoutes+Sections.swift`
    - `AssignmentRoutes+Enrollment.swift` →
      `CourseAdminRoutes+Enrollment.swift`
    - `AssignmentRoutes+StudentCourse.swift` →
      `StudentCourseRoutes+History.swift`

  Each file's leading `// APIServer/Routes/Web/<filename>` header
  comment was updated to match.  The in-scope file list in
  `WebAssignmentErrorTests.noRawAbortInInstructorAssignmentRoutes`
  was updated accordingly.

  No source-code edits beyond the path comments — just renames.

## [0.4.187] - 2026-05-19

### Internal

- **Extracted `_diagnostic-cards` Leaf partial.**
  `assignments.leaf` and `assignment-submissions.leaf` both rendered
  the same `#for(metric in metrics)` loop wrapping `<article
  class="diagnostic-card">` cards.  Lifted into a new
  `Resources/Views/_diagnostic-cards.leaf` partial; each call site
  shrinks from a 9-line section to a 3-line `#extend("_diagnostic-cards")`.

  `admin.leaf` keeps its own hardcoded 5-card structure — those cards
  have JS-targeted `id="diag-…"` attributes filled in by polling, not
  a Swift-side `metrics` array, so the loop pattern doesn't apply.

## [0.4.186] - 2026-05-19

### Internal

- **Test fixture consolidation.**  Six suites
  (`AdminRoutesTests`, `AccountRoutesTests`, `AssignmentEnrollmentTests`,
  `EnrollmentRoutesTests`, and others) each defined their own
  `private func makeCourse / makeUser / makeSetup / makeAssignment /
  makeEnrollment / makeSubmission / makeResult` wrappers — same shape,
  slightly different defaults.  When the underlying model gained a
  field, every copy needed updating.

  Lifted the canonical fixture bodies into a new
  `Tests/APITests/Fixtures.swift` exposing free functions
  `makeTestCourse(on:…)`, `makeTestUser(on:…)`, `makeTestStudent(on:…)`,
  `makeTestSetup(on:…)`, `makeTestAssignment(on:…)`,
  `makeTestEnrollment(on:…)`, `makeTestSubmission(on:…)`, and
  `makeTestResult(on:…)`.  Each suite keeps its own private wrapper
  for its suite-specific defaults (e.g. `AdminRoutesTests`'s
  `"ADM101"` / `"Admin Test Course"` defaults), but the body is now
  a one-line delegation.

  Also consolidated the three multipart body builders in
  `AssignmentRoutesHelpers.swift`.  `arMultipartAssignmentBody` and
  `arMultipartEditBody` are now thin wrappers around the generic
  `arMultipartBody(boundary:fields:files:)`; the inner `appendField`
  / `appendFile` closures lived in triplicate before this PR.

  Net diff: −113 LOC across 5 files, +180 LOC of consolidated
  `Fixtures.swift`.  The real win is single source of truth: future
  `APICourse` / `APIUser` / etc. field additions touch one helper
  instead of seven.

## [0.4.185] - 2026-05-19

### Internal

- **`PatternFamilyRenderer.swift` duplicate-pattern dedup.**  The
  seven kind-specific `renderXxx` functions each open-coded the same
  two-line `# Test:` / `# Generated from pattern family … spec_hash=…`
  header block (7 copies, byte-identical) and the same
  `resolvedHint.map { "\"Hint: \(escapeForPythonStringLiteral(\$0))\"" } ?? "\"\""`
  hint-line expression (7 copies).  Extracted two helpers,
  `generatedCaseHeader(family:case:specHash:)` and
  `generatedCaseHintLineExpr(_:family:)`, so the header format and
  hint shape live in one place — a future tweak (extending the
  spec_hash prefix length, changing the comment lead, etc.) touches
  one site instead of seven.

  Generated Python output is byte-identical to the pre-refactor
  rendering (66/66 pattern-family tests pass), so `spec_hash` /
  `TestSetupCache` keys stay stable across the upgrade.

## [0.4.184] - 2026-05-19

### Internal

- **`AssignmentRoutes+Editor.swift` split into four cohesive files.**
  Counterpart to v0.4.183 (Phase 4.1, `ManifestValidation` split).
  The 809-LOC file mixed four conceptually distinct handler groups
  under a single `extension PublishedAssignmentRoutes`.  Split into:

    - `PublishedAssignmentRoutes+FileDownloads.swift` (109 LOC) —
      the three `GET /instructor/:assignmentID/files/...` endpoints
      (notebook / item / solution).
    - `PublishedAssignmentRoutes+SaveEdit.swift` (328 LOC) —
      `saveEditedAssignment` plus its seven file-private helpers
      (`parseSaveEditedAssignmentForm`,
      `resolvedAssignmentNotebookRaw`,
      `resolveSolutionForEditedAssignment`,
      `persistAssignmentNotebook`,
      `extractSupportFilesForActiveSuite`,
      `enqueueValidationForEditedAssignment`, plus the two
      fileprivate types `SaveEditedAssignmentForm` and
      `ResolvedSolution`).
    - `PublishedAssignmentRoutes+ScriptCRUD.swift` (281 LOC) — the
      four `:assignmentID/scripts` endpoints (get/put/post/delete)
      plus the `safeScriptFilename(from:)` free helper that
      `AssignmentRoutes+Draft.swift` also calls.
    - `PublishedAssignmentRoutes+NotebookTools.swift` (140 LOC) —
      `script-templates`, `scan-notebook`, and `create-solution`
      endpoints.

  Filenames now match their new parent type — the audit's deferred
  `AssignmentRoutes+*` → `PublishedAssignmentRoutes+*` rename happens
  here for the four split files.  Other `AssignmentRoutes+*.swift`
  filenames stay as-is until those are next touched.

  Also updated `WebAssignmentErrorTests.noRawAbortInInstructorAssignmentRoutes`
  to reference the four new filenames in its in-scope list.

## [0.4.183] - 2026-05-19

### Internal

- **`ManifestValidation.swift` split into per-concern validators.**
  The 817-LOC megafile mixed three independent validation concerns:
  dependency-graph cycle detection, pattern-family schema validation,
  and notebook-check schema validation.  Every edit to one concern
  revalidated the whole file under Swift's type checker.  Split into
  four files, each under 400 LOC:

    - `ManifestValidation.swift` (72 LOC) — DAG cycle detection only.
      Kept the original filename so blame for the DAG part stays
      attached.
    - `PatternFamilyValidator.swift` (351 LOC) —
      `validatePatternFamilies` and its four private helpers
      (`validatePatternFamilyHeader`,
      `validatePatternCaseHeader`,
      `validatePatternCaseKindSpecific`,
      `validateFamilyVariablesAndArgRefs`).
    - `NotebookCheckValidator.swift` (392 LOC) —
      `validateNotebookChecks` plus its
      `swiftlint:disable cyclomatic_complexity function_body_length`
      wrapper.
    - `IdentifierValidation.swift` (36 LOC) —
      `isValidPythonIdentifier`, `isValidIdentifierFragment`,
      `pythonKeywords`.  Tiny shared helpers that all three
      validators reference.

  Public API unchanged — `validateManifestDependencies`,
  `validatePatternFamilies`, `validateNotebookChecks` keep the same
  signatures, so `PatternFamilyApplication.swift`,
  `TestSetupRoutes.swift`, and the tests don't need to change.

## [0.4.182] - 2026-05-19

### Internal

- **Shared notebook cell extraction in Core.**  Both
  `Sources/Worker/NotebookExtractor.swift` and
  `Sources/APIServer/Services/SolutionNotebookExtractor.swift`
  open-coded the same three primitives: parsing notebook JSON,
  iterating `code` cells, and reading the `source` field
  (string-or-array).  Each side's *post-processing* genuinely
  diverges (Worker's `sanitizeCellForModule` strips IPython magics
  and wraps top-level code in `if __name__ == "__main__":` for safe
  import; Server preserves cells as-is for `solution.py`), but the
  shape-level work was duplicated.

  Lifted into a small new
  `Sources/Core/NotebookCellSources.swift` namespace:

    - `NotebookCellSources.cells(from notebookData: Data)` — best-effort
      JSON parse returning the `cells` array.
    - `NotebookCellSources.cellSource(_ cell:)` — reads the `source`
      field, tolerating either nbformat representation.
    - `NotebookCellSources.codeCellSources(_ cells:)` — extracts and
      trims non-empty `code`-cell sources for the simple concat path.

  Net diff across the two consumers: −29 LOC.  Each side keeps its
  own post-processing.  Smaller win than the audit estimated (the
  diverging intent is structural, not accidental), but a clean
  removal of the shape-level duplication.

## [0.4.181] - 2026-05-19

### Added

- **Idle session timeout (institutional requirement).**  Authenticated
  sessions that go 30 minutes without a request are now expired
  server-side: any OIDC bearer tokens stashed in the session are
  cleared, the user is logged out, an `auth.session_idle_timeout`
  audit row is written, and the next request is redirected to
  `/login?error=timeout` (browser) or returned `401 Unauthorized`
  (API).  Applies to local and SSO auth modes alike — the gate
  reads `users.last_seen_at`, which `UserActivityMiddleware`
  already refreshes (debounced 60 s) on every authenticated
  request, so no schema change is required.

  Configurable via `SESSION_IDLE_TIMEOUT_MINUTES` (default 30, set
  to 0 to disable).  The middleware sits between
  `UserSessionAuthenticator` and `UserActivityMiddleware` in the
  global chain so it reads the previous request's `lastSeenAt`
  rather than the freshly-refreshed value.  New file:
  `Sources/APIServer/Middleware/SessionIdleTimeoutMiddleware.swift`.

## [0.4.180] - 2026-05-19

### Internal

- **One source of truth for worker HMAC signing.**  Before this change,
  `chickadee-server`'s `WorkerHMACAuthMiddleware.swift` and
  `chickadee-runner`'s `WorkerRequestSigner.swift` each held a private
  copy of `hmacSHA256Hex(...)`, a private `Data.hexEncodedString()`
  extension, and the signed-payload format
  (`METHOD\nPATH\nBODY_SHA256\nTIMESTAMP\nNONCE`).  Server and runner
  agreement was a hand-aligned convention spread across two files;
  any one-sided edit would silently 401 every worker request.

  Lifted into a new `Sources/Core/WorkerHMACSigning.swift`:

    - `WorkerHMACSigning.Header.{timestamp, nonce, bodyHash, signature, workerID}`
      — header-name constants both sides reference instead of literals.
    - `signedHeaders(method:path:body:secret:workerID:timestamp:nonce:)`
      — produces the full `SignedHeaders` struct for the signer.
    - `verify(method:path:headers:secret:)` — constant-time signature
      check for the verifier.
    - `signedPayload(...)`, `hmacSHA256Hex(...)`,
      `constantTimeEquals(...)` — exposed so future tooling (and
      `BrightSpaceAPIClient`'s separate HMAC site) can stay consistent.

  Algorithm drift is now a compile error rather than a silent auth
  break.  No behaviour change — the over-the-wire signing format and
  header names are byte-for-byte identical.

- **`ScriptOutput` moved to Core.**  The 14-LOC DTO returned by
  `ScriptRunner` (worker side) now lives in `Sources/Core/` next to
  `RunnerResult.swift` and `TestOutcome.swift`.  Made `public` +
  `Sendable` with a public memberwise initializer so future tooling
  can reference the shape.

## [0.4.179] - 2026-05-19

### Fixed

- **Worker's `unzip` had the same EFAULT race the server fixed in
  v0.4.178.**  `RunnerDaemon.unzip(_:to:)` was a naked
  `Process.run()` against `/usr/bin/unzip` — no lock, no retry.  When
  the runner ran with `--max-jobs > 1`, two concurrent jobs could hit
  the same Foundation `Process` race that the server-side
  `ZipArchiver` defended against.  Fixed by routing the runner
  through the same lock + retry as the server.

### Internal

- **Lifted `ZipArchiver` + `ZipProcessSerialization` from
  `Sources/APIServer/Utilities/` to `Sources/Core/`.**  Functions and
  the `ZipArchiverError` type are now `public`; both the API server
  and the runner import them from `Core`.  Worker's
  `unzip(_:to:)` method and `WorkerDaemonError.unzipFailed` case are
  gone — the two job-processing call sites now `await
  extractZipArchive(zipPath:into:)` from Core.  `JobStageTimings`
  grew an async-closure variant (`measure(_:operation:)`) so the
  submission-unpack stage timing keeps working through the new
  `await`.

  Core's footprint stayed narrow before this lift — pure DTOs +
  `Hashing.swift` / `ManifestCodec.swift`.  Subprocess plumbing is a
  noticeable expansion of that surface, but the shared lock is now
  meaningfully shared (closes the runner race), and the alternative
  was two side-by-side copies with the bug still present in one of
  them.

## [0.4.178] - 2026-05-19

### Fixed

- **Latent concurrency hole: every zip subprocess now shares one lock.**
  `ZipArchiver.swift` defended itself against the Foundation `Process`
  EFAULT race with a private `NSLock` + retry pair, but the sibling zip
  helpers in `TestSetupZipHelpers.swift` and `MarmosetImportParser.swift`
  issued naked `Process.run()` calls on `/usr/bin/zip` / `/usr/bin/unzip`
  that raced against ZipArchiver's lock-protected calls and each other.
  Lifted the lock + retry helpers into a shared
  `ZipProcessSerialization.swift` (free functions `withZipProcessLock`,
  `acquireZipProcessLock` / `releaseZipProcessLock`,
  `runProcessWithEFAULTRetry`); every zip Process site in the codebase
  now runs under the same serialization.  Sites updated:
    - `ZipArchiver.swift` — uses the shared helpers (no behaviour change).
    - `TestSetupZipHelpers.swift` — `validateZipUploadSize`,
      `listZipEntries`, `extractZipEntry`, plus the three repack paths
      (`updateScriptInZip`, `applyScriptChangesToZip`,
      `removeScriptFromZip`, `createRunnerSetupZip`).  New
      `repackZipFromDirectory(zipPath:sourceDir:)` extracts the
      "remove zip + `zip -q -r` from temp dir" idiom that those three
      paths previously inlined.
    - `MarmosetImportParser.swift` — `extractFileFromZip`.

### Internal

- **Single manifest accessor (collapsed ~30 inline decodes).**  Added
  `APITestSetup.decodedManifest() -> TestProperties?` plus free
  helpers `decodeManifest(from data: Data)` and
  `decodeManifest(fromJSON json: String)` for the call sites that have
  raw bytes or a string instead of a setup model.  Migrated every
  lenient `try? ManifestCodec.decoder.decode(TestProperties.self, ...)`
  site (~30 across 17 files) to the new helpers; the 3 strict-throw
  sites (`try`, not `try?`) keep their inline decode because they
  want exceptions to propagate.

### Deferred

- **Migration of remaining `Abort(...)` calls in `Routes/Web/`** to
  `WebAssignmentError`.  The audit flagged 48 sites in
  `AdminRoutes*`, `EnrollmentRoutes`, `AccountRoutes`, `VanityURLRoutes`,
  `CourseBundleRoutes`, `MarmosetImportRoutes`, `AuthRoutes`,
  `WebRoutes*`.  The existing
  `WebAssignmentErrorTests.noRawAbortInInstructorAssignmentRoutes`
  test deliberately exempts these with the comment "they have their
  own typed-error work in flight."  Migrating now risks conflicting
  with that work; defer to a separate PR once that effort lands.

## [0.4.177] - 2026-05-19

### Internal

- **`AssignmentRoutes` split into five `RouteCollection`s.**  The old
  `struct AssignmentRoutes` extended over 17 `+*.swift` files and ~6.5
  KLOC of handlers from five conceptually independent surfaces.  Swift
  type-checks every extension as part of the parent type, so every
  edit to any of the 17 files forced revalidation of the whole struct.
  Phase 2 of the audit refactor splits it into:

    - `InstructorDashboardRoutes` — the dashboard list view, assignment
      lifecycle (open/close/delete/status), validate page, grade CSV
      export, per-assignment submissions drilldown, BrightSpace sync.
      (Renamed from `AssignmentRoutes`; same files: `AssignmentRoutes.swift`,
      `AssignmentRoutes+List.swift`, `AssignmentRoutes+Submissions.swift`.)
    - `DraftAssignmentRoutes` — draft authoring (new-assignment page,
      draft suite / family / check / script / suite-section CRUD,
      save, publish).  Lives across `AssignmentRoutes+NewAssignment.swift`,
      `AssignmentRoutes+NewPage.swift`, `AssignmentRoutes+SaveValidation.swift`,
      `AssignmentRoutes+Draft.swift`, `AssignmentRoutes+DraftSections.swift`.
    - `PublishedAssignmentRoutes` — published-assignment editing
      (edit/save, file downloads, script CRUD, unified suite editor,
      suite-section CRUD, global variables, pattern families, notebook
      checks).  Lives across `AssignmentRoutes+Editor.swift`,
      `AssignmentRoutes+Suite.swift`, `AssignmentRoutes+SuiteSections.swift`,
      `AssignmentRoutes+GlobalVariables.swift`,
      `AssignmentRoutes+Families.swift`, `AssignmentRoutes+Checks.swift`.
      Also hosts the two `/instructor`-scope utilities used by both new
      and edit pages: `script-templates` and `scan-notebook`.
    - `StudentCourseRoutes` — per-course, per-student submission views
      (`/:courseCode/students/:urlToken/...`, retest, deadline extensions).
      Lives in `AssignmentRoutes+StudentCourse.swift`.
    - `CourseAdminRoutes` — course section CRUD and roster management
      (`/instructor/sections/...`, `/courses/:courseID/...`).
      Lives across `AssignmentRoutes+Sections.swift` and
      `AssignmentRoutes+Enrollment.swift`.

  Each new collection's `boot()` lives in a dedicated file
  (`InstructorDashboardRoutes` still uses `AssignmentRoutes.swift` for
  blame continuity); the `+*.swift` extension files are unchanged on
  disk save for swapping `extension AssignmentRoutes` for the new
  parent.  Routes themselves and URL shape are unchanged.

  Two minor support changes were needed:

    - The four nested DTOs on the old `AssignmentRoutes` (`SuitePayload`,
      `SuiteItemDTO`, `ScriptDTO`, `TestSuiteSectionDTO`) lifted into a
      new top-level file `SuitePayloadDTOs.swift` so the draft and
      published collections can share them.  Pure relocation; no
      behavioural change.
    - `preferredResultsBySubmissionID` promoted from a method on
      `AssignmentRoutes` to a free function so `InstructorDashboardRoutes`
      and `StudentCourseRoutes` can both call it.
    - `draftSolutionNotebook` (a draft-scoped handler that had been
      parked in `AssignmentRoutes+Editor.swift`) moved to
      `AssignmentRoutes+Draft.swift` to land with the rest of
      `DraftAssignmentRoutes`.

  Deferred to a follow-up pass: renaming the `AssignmentRoutes+*.swift`
  files to match their new parent type (`PublishedAssignmentRoutes+Suite.swift`,
  etc.).  Kept as-is for `git blame` continuity until the next cleanup.

## [0.4.176] - 2026-05-19

### Internal

- **Library extraction: `APIServer` is now a `target`, `chickadee-server`
  is a thin executable wrapper.**  Previously `chickadee-server` was a
  single `executableTarget` containing the entire server (35K LOC, 176
  files), and `APITests` depended on it directly.  Every `swift test`
  re-linked the binary as a side effect.  The new layout:
    - `Sources/APIServer/` is a `.target` (library) named `APIServer`
      with the same source files.
    - `Sources/chickadee-server/main.swift` is a 7-line executable
      target that just calls `runAPIServer()` from the library.
    - `APITests` now depends on `APIServer` instead of the executable.

  The executable name and on-disk layout (`.build/release/chickadee-server`)
  are preserved, so Dockerfiles, systemd units, and `deploy/` scripts
  are unaffected.  All 89 `@testable import chickadee_server` test
  imports were rewritten to `@testable import APIServer`.  No
  behaviour change; the server's `runAPIServer()` is byte-for-byte
  the body of the old `APIServerApp.main()`.

- **`AssignmentContextTypes.swift` split into four cohesive files.**
  The 422-line megafile contained 22 `Encodable` Leaf-context structs
  across four unrelated views.  The split:
    - `AssignmentListContexts.swift` — instructor dashboard listing
      (`AssignmentRow`, `CourseSectionRow`, `AssignmentsContext`,
      `InstructorDashboardMetric`, `EnrolledStudentRow`,
      `AssignmentSubmissionsContext`, `AssignmentStudentRow`).
    - `AssignmentEditorContexts.swift` — validate/new/edit pages
      (`ValidateContext`, `NewAssignmentContext`, `EditAssignmentContext`,
      `NewAssignmentNotebookContext`).
    - `SuiteRowContexts.swift` — per-row types shared by new/edit
      (`SuiteSectionShellRow`, `SuiteSectionVariableShellRow`,
      `CurrentFileLink`, `EditableSuiteRow`, `FamilySuiteRow`).
    - `StudentSubmissionContexts.swift` — per-student submission views.

  Isolates each `Encodable` synthesis to its own translation unit so
  touching one context no longer revalidates the others.  Field nesting
  (`NewAssignmentContext` is still 26 stored properties) is deferred —
  the Leaf templates reference fields flat via `#(field)`, so nesting
  would force a template-side rewrite for marginal compile-time gain.

## [0.4.175] - 2026-05-19

### Internal

- **Test code passes the same SwiftLint vocabulary as production**
  (`Tests/.swiftlint.yml` now only carves out `type_body_length`).
  Three back-to-back PRs cleared the per-rule exemptions that
  predated the Swift Testing migration:

  - **`non_optional_string_data_conversion`** enabled (#612, 27
    sites).  `<string>.data(using: .utf8)!` → `Data(<string>.utf8)`
    everywhere — faster (no encoding-failure branch) and removes
    a force-unwrap of a value that can never actually be nil for
    `String`.

  - **`force_unwrapping`** enabled (#613, 172 sites).  Conversion
    patterns:
    * `URL(string: "…")!` → `testURL("…")` via new free helpers
      in `Tests/CoreTests/CoreTestHelpers.swift` and
      `Tests/WorkerTests/Support/WorkerTestSkip.swift` that
      centralize the unavoidable unwrap of literal fixture URLs.
    * `model.id!` → `try model.requireID()` (Fluent's typed-throw
      equivalent).
    * `try await Y.first()!` (and `.find(…)!`) →
      `try #require(try await Y.first())`.
    * `let X = xOptional!` long-form XCTUnwrap → one-line
      `let X = try #require(xOptional)`.
    * `String(data: X, encoding: .utf8)!` →
      `try #require(String(data: X, encoding: .utf8))` (failable
      init preserved so the lint rule
      `optional_data_string_conversion` is satisfied too).
    * One non-throwing `URLProtocol.startLoading()` site uses
      `guard let response = HTTPURLResponse(…) else { return }`.

  - **`force_try` and `force_cast`** enabled (#614, 9 sites).
    `try!` → `try` with `throws` added to the surrounding
    `@Test func`; `as!` → `try #require(value as? T)`.

  After this release the only Tests/-side lint override is
  `type_body_length`, deliberately relaxed for the large
  grouped-suite pattern (WorkerDaemonTests at 800 lines, etc.).

## [0.4.174] - 2026-05-19

### Internal

- **Complete XCTest → Swift Testing migration.**  Phases 0–4E plus
  final cleanup (#597–#609) ported every test file (~107) from
  XCTest to Swift Testing and deleted the three shared
  `XCTestCase` base classes (`WebRoutesTestCase`,
  `AssignmentRoutesTestCase`, `AssignmentHelpersTestCase`) and the
  `PatternFamilyTestCase` fixture.  The CI gate
  `scripts/no-new-xctest.sh` now forbids `import XCTest` anywhere
  under `Tests/`.

  Pattern across the migration:
  - `final class X: XCTestCase` → `@Suite struct X` (default) or
    `@Suite final class X` with sync `init()` / `deinit` when the
    suite owns expensive state.
  - Shared-base subclasses replaced with free-function helpers
    (`withWebRoutesApp`, `withAssignmentRoutesApp`,
    `withPatternFamilyFixture`) and `wr*` / `ar*` / `ah*` / `pf*`
    helper modules.
  - Vapor app lifecycle wrapped per-`@Test` via
    `try await withApp(app) { _ in ... }` so shutdown is
    deterministic.
  - Cross-suite serializers `withAsyncEnvLock { ... }` (env-var
    mutations) and `withMockURLProtocolLock { ... }` (worker
    MockURLProtocol global state).
  - `XCTSkip` → `guard condition else { return }` for silent
    skip-on-platform; `throw IssueRecorded("…")` for skip-as-
    failure when setup is broken.
  - Force unwraps in new tests use `try #require(value)` (the
    `XCTUnwrap` equivalent); the `force_unwrapping` / `force_try`
    / `force_cast` exemption stays in `Tests/.swiftlint.yml` until
    a dedicated cleanup pass.

  Migration scaffolding removed in #609: the 3× repeat-run CI
  workflow (`test-isolation.yml`) and the per-file XCTest
  allowlist (`scripts/xctest-allowlist.txt`).  See the rewritten
  Testing Conventions section of `CLAUDE.md` for the post-
  migration state.

- **Fix `makeTestApp` partial-init SIGILL that took down
  api-tests-postgres.**  Every test factory that built an
  `Application` via `Application.make(.testing)` could leak a
  half-built app if any subsequent setup step threw —
  `Application.deinit` runs the *sync* `shutdown()`, which on a
  testing app with NIO event loops + FluentKit pools trips an
  assertion in `ServeCommand.deinit` → SIGILL on Linux,
  terminating the entire xctest process and every other
  concurrent test.  Introduces a `makeTestingApplication(setup:)`
  helper that owns the build / asyncShutdown-on-throw contract;
  routes every `makeApp`-style factory (`makeTestApp`,
  `SSOAuthFlowTests.makeApp`, `AssignmentSeedStoreTests.init`,
  `AuthModeGatingTests.makeApp`, `NotebookWebRoutesTests.init`,
  `SecurityAndHealthTests.makeHealthApp`,
  `withPatternFamilyFixture`) through it.

- **Unify env-mutation lock across test suites.**  The previous
  setup had two locks — `EnvTestLock.shared` (NSLock, sync
  scopes) and `withAsyncEnvLock` (actor, async scopes) — that
  didn't coordinate, so env writers in one suite could run while
  env readers (`configureTestDatabase`'s
  `testDatabaseSettingsFromEnvironment` call) in another suite
  were in flight.  Drops the NSLock, replaces the per-suite
  `EnvironmentScope` / `withEnvironment` helpers with a single
  async `withTestEnvironment(_:perform:)`, and wraps
  `configureTestDatabase`'s env read in `withAsyncEnvLock`.  The
  actor lock is reentrant on the same task (TaskLocal) so nested
  `withTestEnvironment` → `configureTestDatabase` calls don't
  deadlock.

- **Cap Swift Testing's internal parallel width on APITests
  jobs.**  Swift Testing schedules class-suite instances in
  parallel regardless of `swift test --parallel`.  Each in-flight
  test app holds a FluentKit connection pool; at unbounded
  parallelism the combined demand exceeded Postgres's default
  100-connection cap (`FATAL: sorry, too many clients already`)
  and the SQLite job's pool timeouts.  Sets
  `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=4` on
  `api-tests` and `api-tests-postgres` so at most four test apps
  run concurrently — well under the connection cap, with most of
  the parallelism speedup preserved.  `api-tests-postgres` is
  back to a blocking gate.

### Internal (pre-migration tranche)

- **Migrate 5 standalone XCTest files to Swift Testing.**  First slice
  of round-2 review item #4 (89 XCTest files total).  Picked the
  smallest, most independent suites — no shared base class, no
  async tearDown — to establish the conversion pattern:
    * `Tests/APITests/COEPMiddlewareTests.swift` (3 tests)
    * `Tests/APITests/ScanModeMiddlewareTests.swift` (3 tests)
    * `Tests/APITests/CurrentUserContextTests.swift` (2 tests)
    * `Tests/WorkerTests/DirectorySizeBytesTests.swift` (5 tests,
      migrated to `@Suite final class` + `init() throws` + `deinit`
      because the temp-dir setup/teardown needs lifecycle)
    * `Tests/WorkerTests/WorkerRequestSignerTests.swift` (2 tests)

  Pattern: `final class X: XCTestCase` → `@Suite struct X`
  (or `@Suite final class X` when teardown is needed);
  `func testFoo()` → `@Test func foo()`;
  `XCTAssertEqual(a, b)` → `#expect(a == b)`;
  `XCTAssertNil(x)` → `#expect(x == nil)`;
  `XCTAssertNotNil(x)` → `#expect(x != nil)`.  Imports drop
  `XCTest`, keep `XCTVapor` where Vapor test helpers are still
  used (`Application.testable()` works inside Swift Testing
  closures).  All 15 migrated tests pass under the new framework.

  Skipped for this slice: suites that subclass shared test bases
  (`AssignmentHelpersTestCase`, `WebRoutesTestCase`, etc.) and
  suites with async `tearDownTestApp()` cleanup (the
  `makeTestApp`-using files like `AuditLogReaperServiceTests`).
  Those need a designed cleanup pattern — Swift Testing has no
  `tearDown` and async `deinit` is unavailable for class-typed
  suites.  Follow-up PRs can tackle them with a dedicated helper.

- **Introduce general-purpose `AppError` typed error + migrate 45
  `Abort(.X, reason: "msg")` sites to it.**  PR #579 unified the
  *rendering* of bare `Abort(...)` and typed `WebAssignmentError`
  via `LeafErrorMiddleware.friendlyReason`, but the source-side
  split — `WebAssignmentError` for assignment routes, bare `Abort`
  elsewhere — remained.  This PR adds an `AppError` enum in
  `Sources/APIServer/Errors/APIErrors.swift` with the
  general-purpose case shapes (`.notFound(resource:)`,
  `.badRequest(reason:)`, `.invalidParameter(name:reason:)`,
  `.forbidden(action:)`, `.conflict(reason:)`,
  `.unprocessable(reason:)`, `.internalFailure(reason:)`), then
  migrates every `Abort` site that already had an explicit
  `reason:` string to the matching typed case.

  Files touched:
    * `ClientDiagnosticsRoutes`, `SubmissionRoutes`,
      `SubmissionQueryRoutes`, `TestSetupRoutes` (8 sites),
      `BrowserResultRoutes` (5 sites), `WebRoutes`, `WebRoutes+Notebook`
      (5 sites), `AdminRoutes+Courses` (3 sites),
      `MarmosetImportRoutes` (4 sites), `AdminRoutes`,
      `CourseBundleRoutes` (7 sites), `AccountRoutes`.
    * `Sources/APIServer/Errors/APIErrors.swift` — new `AppError`
      enum.

  Bare-`Abort(.X)` sites (no explicit reason) were intentionally
  left alone — `LeafErrorMiddleware.friendlyReason` already produces
  a humane default per status code for those, and fabricating
  contextual `resource:` / `action:` strings just to satisfy the
  typed constructor would have been busywork without UX benefit.

  Existing tests pass unchanged: 111 cases across the touched
  routes (BrowserResultRoutes, SubmissionRoutes, TestSetupRoutes,
  WebRoutes, AdminRoutes, CourseBundleRoutes, MarmosetImportRoutes,
  AccountRoutes, NotebookWebRoutes, AssignmentRoutesNotebook,
  AssignmentExtensions, etc.) — the `AbortError` protocol means
  `AppError.X` and the prior `Abort(.X, reason: …)` produce the
  same `(status, reason)` tuple, so the HTTP shape is preserved.

- **Parallelise the 5 sequential queries on `exportGradesCSV`.**
  Follows the `async let` pattern from PR #590 on the second-worst
  N+1 offender flagged in the architecture review:
    * Phase 1 (independent): `students` + `assignments` in parallel
      — both need only `activeCourseUUID`.
    * Phase 2 (depends on phase 1, independent of each other):
      `setupsByID` + `submissions` in parallel — both consume
      `setupIDs` / `studentIDs` but are otherwise independent.
    * Serial follow-on: `preferredResultsBySubmissionID` (needs
      submission IDs from phase 2).
  Latency goes from ~5×N round-trip to ~3×N.  No behaviour change;
  25 adjacent route tests (`AssignmentRoutesDashboardTests`,
  `AssignmentRoutesLifecycleTests`, `AssignmentRoutesRetestTests`,
  `AssignmentExtensionsTests`) pass unchanged.

- **Typed throws on `WorkerJobRoutes.buildJobPayload`.**  The
  function only throws `WorkerJobError.internalInconsistency` (two
  sites: missing id, malformed URL).  Signature tightens from
  `async throws -> Job` to `async throws(WorkerJobError) -> Job`
  so the compiler now enforces the error contract at the call
  sites.  The single caller (`requestJob` route handler) stays
  on plain `throws` — typed throws promotes to `Error`
  automatically when caught by an untyped catch.

  This is the first conversion of round-2 review item #1.  Two
  other candidates (`BrowserResultRoutes.submitBrowserResult` and
  `TestSetupRoutes.downloadSupportFile`) need `AppError` to land
  on main first (#591) before they can be similarly tightened.
  Sibling functions in `WorkerJobRoutes.swift` (e.g.
  `encodeJobResponse`) throw Codable errors and are intentionally
  left as untyped `throws`.

- **Document the one `try!` in production code.**  The compile-time
  regex literal in `NotebookSubstitution.placeholderRegex`
  (`Sources/APIServer/Services/NotebookSubstitution.swift:32`)
  unwraps `NSRegularExpression(pattern:)` with `try!` — the
  alternative is propagating `throws` through every call site of
  `apply(...)` for a failure case that cannot actually fire (the
  pattern is a string literal, not runtime input).  Comment now
  explains the safety reasoning so the next person reading it
  doesn't have to re-derive it.


- **Extract `updateNewAssignmentDraft` per-action dispatch into a
  new `NewAssignmentDraftService`.**  The 9 draft-action verbs
  (create / upload / clear assignment & solution notebooks, replace
  / clear suite files, etc.) had been an inline `switch action`
  inside the route handler — preserved that way through the parser
  extraction in PR #583 because the per-case branches shared five
  locals (`setup`, `setupID`, `userID`, `courseID`, `formState`)
  that threading through per-action free helpers would have made
  worse, not better.

  This PR moves the shared locals onto a `NewAssignmentDraftService`
  struct in `Sources/APIServer/Services/` and turns each verb into
  a `mutating` method on the service.  Each method reads/writes
  `self.setup` / `self.formState` instead of a thread-through.
  The handler shrinks from ~290 LOC to ~60 LOC: parse → resolve
  setup → seed form state → `service.perform()` → write back →
  redirect.  Outcome enum `NewAssignmentDraftActionOutcome`
  (`.applied` / `.validationFailed(String)`) keeps the service
  HTTP-agnostic — the handler builds the redirect from it.

  Additional changes:
    * `NewAssignmentDraftPayload` moved from a `fileprivate` struct
      inside `+NewAssignment.swift` to a file-internal struct in
      `Sources/APIServer/Routes/Web/NewAssignmentDraftPayload.swift`
      so the service can construct one.
    * `newAssignmentSectionGradingMode(...)` lifted from a `private`
      method on the `AssignmentRoutes` extension to a file-scope
      function so the service can call it.

  New `NewAssignmentDraftServiceTests` adds 11 service-level unit
  tests exercising each action in isolation (validation branches
  for both upload variants, file-system + form-state assertions
  for create/clear assignment notebook, no-op behaviour for
  unknown/empty action verbs, `notebookTitle` derivation).  The 18
  end-to-end tests in `AssignmentRoutesPublishTests` remain green
  (behavior parity confirmed).  Service-level tests run ~5× faster
  per case than the integration tests — adding a new action now
  comes with a fast inner-loop test cost.

  Sets the precedent for the service-layer pattern across the rest
  of the routes layer; follow-ups can apply the same shape to
  `saveEditedAssignment` and the helpers-as-services migration.

- **Parallelise the 7 sequential DB queries on
  `courseStudentSubmissionsPage`.**  The
  `/:courseCode/students/:username/submissions` handler in
  `AssignmentRoutes+StudentCourse.swift` was running every query
  in series — assignments, setups, submissions, preferred-results,
  extensions, class-badges, sections — even though only one pair
  has a real data dependency.  Restructured into two parallel
  batches via structured `async let`:
    * Phase 1 (independent): `assignments` + `allSections` in
      parallel.  Sections only need `courseID`.
    * Phase 2 (depends on assignments): `setupsByID` + `submissions`
      + `extensionByAssignmentID` + `classBadgesBySetupID` in
      parallel.  All four take the assignment list / setupIDs as
      input but are otherwise independent.
    * Serial follow-on: `preferredResultsBySubmissionID` (genuinely
      depends on submission IDs from phase 2).

  Latency goes from ~7×N round-trip to ~3×N, no JOIN gymnastics
  — Fluent's connection pool already supports parallel queries.
  Behaviour is unchanged; the 10 tests in
  `AssignmentRoutesNotebookTests` and `AssignmentExtensionsTests`
  that exercise this page pass unchanged.

- **Round-2 coverage for `WorkerDaemon`: job-claim concurrency +
  terminal download failure.**  Closes the two architecture-review
  follow-ups that PR #582 (`RunnerNetworkResilienceTests`)
  explicitly deferred.  New cases:
    * `testWorkerDaemonRunsJobsConcurrentlyWhenMaxConcurrentJobsAllows` —
      feeds 5 jobs to a daemon with `maxConcurrentJobs: 5` and a
      script runner that records peak simultaneous invocations.
      Asserts the recording runner observed ≥ 2 concurrent calls;
      regression-pins the `withThrowingDiscardingTaskGroup` worker-loop
      fanout that's been silently relied on by every production
      runner.
    * `testWorkerDaemonReportsSyntheticFailureWhenSubmissionDownloadTerminallyFails`
      — terminal 404 on the submission download → daemon still emits a
      `buildStatus: .failed` report with `outcomes: []` and does NOT
      invoke the script runner.  Complements
      `testDownloadRetriesThroughShortServerInterruption` which
      covers the *recoverable* download path.

  Supporting fixtures: `ConcurrencyRecordingRunner` actor (peak-count
  ScriptRunner) and `AlwaysFails404Server` (always-404 HTTP server),
  added inline in `WorkerDaemonTests` per the existing fixture
  convention there.  Full `WorkerDaemonTests` suite: 12 tests, 0
  failures.

- **Plug the remaining editor test gaps deferred in PR #581.**
  Adds 9 tests to `AssignmentRoutesEditorTests`:
    * **`GET /instructor/new/draft/solution-notebook`** (5 tests):
      happy-path returns the notebook bytes via the fallback path,
      404 for unknown draft, 404 for draft without a solution file,
      404 for missing `draftID` query param, 403 for student.
    * **`POST /instructor/:assignmentID/edit/save`** (4 tests):
      403 for student, 404 for unknown assignment, validation-failure
      redirect with `?error=Assignment%20name%20is%20required` on
      empty title, validation-failure redirect with `?error=…` on
      missing test suites.  Happy-path multipart save is already
      exercised end-to-end by `AssignmentRoutesPublishTests`.

  Includes a comment explaining the CSRF-token-ordering gotcha that
  bit during authoring (token must be fetched before any fixture
  creates a course-bearing setup; otherwise `GET /instructor` redirects
  to `/enroll` for the instructor and the token extractor returns the
  empty string).

  Editor suite is now 21 tests, 0 failures.

- **Extract `updateNewAssignmentDraft` request-body parsing into
  `parseNewAssignmentDraftPayload(req:)`.**  The handler's first
  ~90 lines were Multi/Single Vapor `Content` decoding + multipart
  fallback chains for 13 fields — exactly the pattern
  `parseSaveEditedAssignmentForm` follows further down the same
  file.  The body parsing moves into a `fileprivate` helper and a
  named `NewAssignmentDraftPayload` struct; the handler keeps its
  inline `switch action` over the 9 draft verbs (per the author's
  documented preference at lines 95-104 — the per-case branches
  share enough state that splitting them through helpers would
  be a regression, but the parsing is a clean cut).  Handler
  shrinks from ~370 LOC to ~280 LOC; the payload struct is
  testable on its own and forms the foundation for a future
  `NewAssignmentDraftService` per-action extraction if that
  direction is chosen.  No behaviour changes — `swift test
  --filter AssignmentRoutesPublishTests` is unchanged
  (18 tests, 0 failures).

- **Add `RunnerNetworkResilienceTests` to plug the coverage gap on the
  worker's retry classifier + backoff helpers.**  Prior coverage was
  indirect — `Reporter`/`JobPoller` tests drive the helpers through
  the HTTP stack and the two-case sanity check in `WorkerTests`
  (`testClassifyHTTPRetry*`) covered 4 of 9 status codes the classifier
  handles.  New file adds 16 pure-function tests with no daemon spin-up
  or wall-clock dependency:
    * `classifyHTTPRetry` — full grid of retryable codes (408, 425,
      429, 500, 502, 503, 504), terminal auth codes (401, 403), the
      duplicate-worker-ID 409 terminal case, and the
      "unknown-4xx ⇒ terminal" default.
    * `classifyPollHTTPRetry` — pins the poll-path-specific upgrade
      of 401/403 to retryable (so long-lived runners recover from
      transient auth-reconfiguration windows) and confirms non-auth
      codes fall through to the base classifier.
    * `withRunnerRetry` — succeeds without retry on first hit, retries
      until success, short-circuits on terminal disposition, respects
      `maxAttempts` and rethrows, honours `policy.enabled=false`,
      invokes `onRetry` exactly between attempts (N–1 calls for N
      attempts) with correct stage/attempt/message.
    * `ExponentialBackoff` — stays within the cap, never returns zero
      (regression-pin for the early bug fixed in v0.4.22), and `reset()`
      returns the next draw to within `2× initial`.

- **Add `AssignmentRoutesEditorTests` to plug the coverage gap on
  `AssignmentRoutes+Editor.swift` (881 LOC).**  The script CRUD
  endpoints (`getScript` / `updateScript` / `createScript` /
  `deleteScript`) were already covered by `ScriptEditRoutesTests`,
  and `saveEditedAssignment` is exercised end-to-end by
  `AssignmentRoutesPublishTests`, but the three file-download
  endpoints and the `create-solution` helper had zero direct test
  coverage.  New test file adds 12 cases covering:
    * `GET /instructor/:id/files/notebook` — happy path, student 403,
      unknown-assignment 404
    * `GET /instructor/:id/files/item?name=…` — happy path,
      missing-file 404, path-traversal 400, student 403
    * `GET /instructor/:id/files/solution` — solution-from-zip-entry
      happy path, no-solution 404, student 403
    * `POST /instructor/:id/create-solution` — student 403,
      unknown-assignment 404 (with valid CSRF token so the test
      reaches the handler, not the CSRF middleware)
  All 12 tests pass against in-memory SQLite.  The path-traversal
  test pins the existing `name == NSString.lastPathComponent` guard
  in `downloadCurrentSetupItem` (`AssignmentRoutes+Editor.swift:50`).

- **Unify error rendering for bare `Abort(...)` and typed
  `WebAssignmentError` throws.**  Both have always funneled through
  `LeafErrorMiddleware` and rendered the same Leaf `error` template,
  but the *user-facing message* diverged: typed errors produced
  contextual reasons ("Assignment 'foo' not found", "You do not have
  permission to edit assignments."), while a bare `Abort(.notFound)`
  with no `reason:` rendered the raw HTTP reason phrase
  ("Not Found", "Forbidden", "Bad Request") — and the Leaf template
  threw away typed-error context on 404 by hard-coding a canned
  message.  `LeafErrorMiddleware` now passes every `Abort` reason
  through a new `friendlyReason(status:reason:)` helper that
  substitutes a humane default (`We couldn't find that page.`,
  `You don't have permission to view this page.`, etc.) only when
  the caller did not supply a contextual reason; explicit reasons —
  including all `WebAssignmentError` messages — are returned
  verbatim.  The `error.leaf` template drops its 404 special-case
  branch since the middleware now always provides a meaningful
  message.  The JSON error envelope for `/api/*` and `/worker/*`
  paths gains a `"status": <code>` field for symmetry with the HTML
  page.  No source-side migration required — the 127 bare `Abort`
  call sites scattered across the non-AssignmentRoutes surface now
  render as friendly defaults without touching the route handlers
  themselves.

- **v0.6.0 cleanup: drop the two DEPRECATED back-compat shims.**
  CLAUDE.md flagged both for removal once their compatibility window
  closed.  (1) `NotebookFunctionScanner`: the
  `isShadowed = decodeIfPresent(...) ?? false` fallback in the custom
  `init(from:)` is now a plain `decode(...)` — browser clients on
  v0.4.94+ have shipped `isShadowed` unconditionally and the
  fallback no longer carries weight.  (2) `CourseBundleManifest`:
  the `openEnrollment: Bool?` field on `BundledCourse` (and its
  init parameter) is gone, and `bundledCourseEnrollmentMode(_:)`
  collapses to `course.enrollmentMode ?? .open`.  `.chickadee`
  bundle exports have only emitted `enrollmentMode` (never
  `openEnrollment`) since the helper extraction in #501, so old
  imports were already going through the `?? .open` default branch.
  Five tests that pinned the legacy contract
  (`isShadowedDecodeFallback_legacyJSONWithoutFieldDefaultsToFalse`,
  `bundledCourseBackwardCompatEnrollmentModeAbsent`, and the three
  `enrollmentModeResolver_legacy*` cases) are rewritten to assert
  the new contract: missing `isShadowed` now throws `DecodingError`,
  `bundledCourseEnrollmentMode` only consults `enrollmentMode`.

- **v0.5.0 cleanup: delete the 13 no-op `Add*` migration stubs.**
  PR #502 (v0.4.171) folded these into the corresponding `Create*`
  files, but left the structs in place as empty-bodied `AsyncMigration`
  no-ops so production DBs that had them marked applied in
  `_fluent_migrations` saw no runtime change.  CLAUDE.md flagged the
  actual deletion for v0.5.0 once production was observed tolerant of
  the consolidation.  Removed:
  `AddAssignmentDeadlineOverrideActive`, `AddAssignmentSlugs`,
  `AddBrightSpaceSyncFields`, `AddCourseEnrollmentMode`,
  `AddCourseOpenEnrollment`, `AddCourseSections`,
  `AddJobDiskUsageMetrics`, `AddJobExecutionCacheHit`,
  `AddJobExecutionStageTimings`, `AddSubmissionRetestedAt`,
  `AddSubmissionRetestedByUserID`, `AddTestSetupLastRetestedManifestHash`,
  `AddUserLastSeenAt`.  Their `.add(...)` lines in
  `registerMigrations(on:)` (`DatabaseConfiguration.swift:184`) are
  deleted too.  `AddSessionsCreatedAt` stays — it's a real migration
  against Vapor's `_fluent_sessions` table, not one of ours, and was
  never consolidated.  Fluent ignores `_fluent_migrations` history
  rows whose struct names are no longer registered, so existing
  production DBs are unaffected.  Fresh deploys produce the same
  final schema from the `Create*` files alone.

- **Wire SwiftLint into the `format-lint` CI job.**  `.swiftlint.yml` and
  `scripts/swiftlint.sh` have been on disk since the adoption PR, but the
  workflow only ran `scripts/lint.sh` (swift-format).  The violation
  backlog is now empty (`Found 0 violations, 0 serious in 329 files`),
  so the staged rollout described in `CLAUDE.md` advances to its final
  state: the `Run SwiftLint` step runs after `Check formatting` in the
  same job.  The script still skips `--strict`, so warning-severity
  rules report without blocking while error-severity outliers (function
  body > 300 lines, type body > 800 lines, cyclomatic complexity > 40,
  etc.) fail the job.  Added an SPM checkout cache to keep the
  swiftlint plugin warm across runs, and bumped the job timeout from
  5 min to 10 min to absorb the first cold build.  Job runs on
  `swift:6.3-noble` because SwiftLintBinary 0.63.2 needs GLIBC 2.38
  (jammy ships 2.35); other jobs stay on jammy.

- **Drop redundant in-handler role guards on AssignmentRoutes.**  The
  `AssignmentRoutes` collection (and every `+Extension`) is already
  registered behind `RoleMiddleware(required: .instructor)` in
  `routes.swift`, so the ~40 in-handler `guard user.isInstructor`
  checks (15 inline `WebAssignmentError.forbidden(action:)` sites in
  `+Editor` / `+Enrollment` / `editPage`; 25 `try requireInstructor(req)`
  sites in `+Suite` / `+Checks` / `+Families` / `+GlobalVariables` /
  `+SuiteSections` / `+DraftSections` / `+Draft`) were dead code — the
  middleware throws `Abort(.forbidden)` before any handler runs.  The
  `requireInstructor(_:)` helper in `SuiteEditHelpers.swift` is
  removed too.  Net: 11 files, 5 +, 104 −.  Two combined
  `guard user.isInstructor, let userID = user.id else { … }` sites in
  `+Editor` are simplified to a plain `let userID = user.id` extract
  (still required because `APIUser.id` is `UUID?` for Fluent reasons);
  their throw site changes from `.forbidden` to `.internalFailure`
  since the only reachable branch is a server-side data inconsistency,
  not an authorization failure.  Tests assert on HTTP status
  (`.forbidden`), not on `WebAssignmentError` cases, so existing
  rejection coverage in `AssignmentRoutesDashboardTests`,
  `AssignmentEnrollmentTests`, `SuiteRouteTests` continues to assert
  the right thing — `Abort(.forbidden)` from the middleware also
  yields a 403.  `TestSetupRoutes`, `WebRoutes(+Submission)`,
  `SubmissionRoutes`, and `VanityURLRoutes` are unchanged because
  their inline checks are legitimate per-resource authorization
  (the collections themselves are in the `.authenticated` group,
  not the `.instructor` group).

## [0.4.173] - 2026-05-17

Security & privacy pass.  Closes the security findings raised by the
v0.4.171 audit (issues #551, #552, #554, #555, #559, #560, #561, #563)
plus an already-merged queue-backup-alert fix from #570.  No schema
changes, no API shape changes; runtime behaviour is more restrictive
in three places (cross-tenant submission, vanity URL enumeration,
local-auth login timing) and one external dependency is removed
(`cdn.jsdelivr.net` / `esm.sh`).

### Security

- **Cross-tenant submission gate (#551, #567).**
  `requireOpenStudentAssignment` checked only that an assignment was
  open — never that the caller was enrolled in the owning course.  A
  student who learned a `testSetupID` for a different course could
  submit there and pollute the foreign instructor's queue.  The
  enrollment check is now inside the helper so every caller (web
  submit, browser submit, browser finalize) inherits it; the GET-side
  submit form picked up the same check so the assignment title doesn't
  leak across tenants.  Instructors and admins bypass via
  `requireCourseEnrollment`'s `isInstructor` short-circuit.
- **Worker secret file 0o600 (#552, #567).**
  `.worker-secret` was written with the process umask — 0644 on most
  Linux deploys, so any local user could read it and forge HMAC-signed
  worker requests.  `writeWorkerSecretToDisk` and
  `readWorkerSecretFromDisk` now restrict the file to owner read/write
  only; existing installs are tightened on read.
- **Login-timing equalization (#559, #567).**  `LocalAuthProvider`
  skipped bcrypt verify when the username didn't exist, leaking
  account existence via response time (~150 ms vs ~0 ms).  Now always
  runs a verify against a cached dummy hash computed via the same
  `AsyncPasswordHasher` so cost factor matches a real account.
- **Zip-bomb test-setup uploads (#554, #572).**
  `validateZipUploadSize` inspects `unzip -v` metadata and enforces
  per-entry (64 MB) and total (256 MB) uncompressed caps before any DB
  row references the file.  Limited blast radius — instructor-only
  path — but a compromised instructor account shouldn't be able to
  take down the host with a 1 MB upload.
- **Vanity URL enumeration (#561, #572).**  `resolveAssignment` now
  requires course enrollment.  Unenrolled access produces the same
  404 as no-such-course / no-such-assignment, so the routes can't be
  used to enumerate the institutional catalogue.
- **OIDC_AUTH_SERVER validation (#563, #572).**  New
  `validateOIDCDiscoveryURL` rejects `http://` and loopback /
  private-range hosts at startup unless `OIDC_ALLOW_INSECURE=true`
  is set.  Defense in depth against a fat-fingered env var pointing
  the discovery fetch at an internal service.
- **Audit log retention (#555, #573).**  The `audit_log` table grew
  forever — every authenticated action, login attempt, role change,
  retest, and admin operation lands a row with actor names, IPs,
  user-agents, and action metadata.  Under FIPPA / PIPEDA, indefinite
  retention isn't defensible.  New `AuditLogReaperService` mirrors
  `SessionReaperService`: one-shot startup sweep + hourly periodic
  sweep, default 90-day retention via
  `AUDIT_LOG_RETENTION_DAYS`.  Setting to 0 disables for operators
  piping to external sinks.
- **Self-host Pyodide, jszip, CodeMirror (#560, this release).**
  Pyodide was loaded from `cdn.jsdelivr.net` and CodeMirror from
  `esm.sh` on every page that needed them.  Every student/instructor
  IP that touched those pages was logged by third-party CDNs not in
  the institution's data-processing agreements.  Vendored under
  `Public/pyodide/` (full Pyodide v0.27.0, ~1.4 GB on disk, ~375 MB
  packed in git) and `Public/vendor/{jszip.min.js,codemirror.js}`.
  Same pattern as `Public/jupyterlite/`: source-of-truth in
  `scripts/setup-vendor.sh` + `Tools/vendor/`, generated bytes
  checked in.  CSP tightened to drop both CDN origins from
  `script-src`, `worker-src`, and `connect-src` — now strictly
  same-origin plus `'unsafe-eval'` (Pyodide WASM) and `blob:`
  (workers).  `python_flint-0.6.0` (155 MB) excluded because it
  exceeds GitHub's per-file hard limit; no Chickadee assignment
  plausibly needs symbolic-math integer arithmetic.

### Fixed

- **Queue-backup health alert no longer false-fires after a retest sweep.**
  Two independent bugs were combining to produce bogus alerts like
  `Queue backed up: 218 pending (>= 25); oldest pending 468679s old
  (>= 600s)` immediately after an instructor retested an assignment
  whose submissions drained within minutes.  (1) The "oldest pending
  age" was measured from `submittedAt`, but a retest flips a
  submission back to `pending` without resetting that column, so a
  retest of a week-old submission looked week-old to the alert.  The
  age now uses the effective enqueue time (`retestedAt ?? submittedAt`),
  matching the `queueWaitMs` baseline established in v0.4.45.
  (2) The rule fired on `depthBreached || ageBreached`, but a depth
  spike with fresh items is normal load (instructor retest, exam
  rush) — not a stuck queue.  The depth threshold is now an
  *aggravating* signal that's only included in the summary when age
  is *also* breached; age-breach is the sole trigger.  Both changes
  live in `Sources/APIServer/Services/ServerHealthAlertService.swift`.
  New regression tests cover both scenarios.
- **Admin runner page no longer shows `Total < Queue Wait`.** v0.4.164's
  retest-clear fix closed one cause (stale per-attempt fields on the
  `JobExecutionMetric` row across a retest), but the underlying math
  for `totalProcessingMs` still straddled two clocks:
  `millisecondsBetween(server enqueuedAt, runner finishedAt)`. Any
  runner clock skew let totals slip below queue wait — for example
  Queue Wait 210ms / Execution 101ms / Total 112ms on a runner whose
  clock was ~200ms behind the server. Now
  `totalProcessingMs = queueWaitMs + executionMs` (and the parallel
  `APISubmissionDiagnostics.turnaroundMs` is computed the same way) in
  both `recordWorkerExecutionReport` and `recordJobFailure`. Each
  component already lives on a single clock, so the sum is skew-safe.
  New `sumComponentMs` helper sits next to `millisecondsBetween`. New
  regression test `testTotalProcessingMsIsResilientToRunnerClockSkew`
  models the production failure mode. Existing rows in the DB carry
  their old values until reprocessed (no backfill).

## [0.4.172] - 2026-05-15

### Fixed

- **snapshot.sh / restore.sh read DATABASE_* from the live server container.**
  The v0.4.171 scripts sourced `.env` to detect `DATABASE_BACKEND`, which
  failed for deployments where compose resolves those vars from a
  `docker-compose.override.yml`, exported shell env, or any other source
  outside `.env` — the scripts incorrectly reported "Current value: sqlite"
  on a Postgres deployment.  Both scripts now run
  `docker compose exec -T server env` and pick up `DATABASE_*` from the
  authoritative container env, falling back to `.env` only when the server
  isn't running.  No interface changes.

## [0.4.171] - 2026-05-15

### Added

- **Snapshot/restore scripts for Postgres deployments.**  `scripts/snapshot.sh`
  bundles a `pg_dump -Fc` of the chickadee database plus a tar of the
  on-disk artifact paths (`testsetups/`, `submissions/`, `results/`,
  `.worker-secret`, `.local-runner-autostart`) into
  `backups/snapshot-<TS>[-<label>]/`, writing `manifest.json` last so
  partial snapshots are detectable.  `scripts/restore.sh` stops the
  server+runner, runs `pg_restore --clean --if-exists`, replaces the
  artifact dirs, and restarts the stack; supports `--yes`,
  `--regenerate-secrets` (for prod→staging copies — forces fresh worker
  HMAC secret), and `--scrub-pii` (anonymises identity columns on
  `users` rows with `role='student'`).  Daily 3am cron + 7-day prune
  recommended for ongoing rollback insurance.  Driven by the AppScan
  weekend rollback need.  SQLite deployments stay on `server-deploy.sh`'s
  existing volume tar.  See `deploy/README.md` ("Snapshots and rollback").

### Changed (groundwork for v0.5.0 / v0.6.0)

- **#502 step 1+2 — migration consolidation prep.**  All 13 historical
  `Add*` migrations except `AddSessionsCreatedAt` (which targets
  Fluent's own `_fluent_sessions` table) have been folded into the
  corresponding canonical `Create*` files.  Each `Add*` struct is
  preserved in its file and in `registerMigrations(...)` so existing
  production deploys, which already have these migrations marked
  applied in `_fluent_migrations`, see no change at runtime — the
  no-op bodies never run on those databases.  Fresh deploys produce
  the same final schema in roughly one migration step per table
  instead of 33 sequential steps.  The actual deletion of the no-op
  `Add*` files is deferred to v0.5.0 once we've confirmed Fluent
  tolerates name-disappearance gracefully.
- **#501 prep — runway for the v0.6.0 DEPRECATED cleanup.**  Extracted
  the inline 8-line enrollment-mode fallback at
  `CourseBundleRoutes.swift:395` into a `bundledCourseEnrollmentMode(_:)`
  helper in Core, so v0.6.0 has a single function to update when
  dropping the `openEnrollment` back-compat field.  Added four Core
  tests pinning the resolver branches (explicit mode wins, legacy
  `openEnrollment: false → .closed`, legacy `openEnrollment: true →
  .open`, both-missing defaults to `.open`) and two tests pinning the
  `NotebookFunctionInfo.isShadowed` decode fallback (legacy JSON
  without the field → false; modern JSON honours explicit true).
  DEPRECATED-marker audit confirms only the two known sites; no
  orphans.

## [0.4.170] - 2026-05-15

### Changed

- **Maintenance pass — extracted shared helpers and split overgrown
  bootstrap.**  No behaviour changes.

  - **#497** Extracted `escapeForPythonStringLiteral` and
    `tierFilenamePrefix` into
    `Sources/APIServer/Utilities/PythonScriptHelpers.swift`.  Both
    `PatternFamilyRenderer` and `NotebookCheckRenderer` (plus its
    `+Code` / `+DataFrame` / `+Plots` extensions) now read from the
    shared module; the byte-identical duplicates and the
    `*ForCheck` / `*Check` suffix smell are gone.  Generated test
    script bytes are unchanged, so `spec_hash` values and the
    `TestSetupCache` invalidation key remain stable.
  - **#495 (partial)** Moved ~290 lines of submission output-formatting
    helpers (stdout/stderr parsing, chickadee.py JSON-envelope
    extraction, `SubmitFormBody`) out of `WebRoutes+Submission.swift`
    into `Sources/APIServer/Helpers/SubmissionOutputFormatting.swift`.
    Route file goes 854 → 568 LOC.  The issue also called for splits
    of `AssignmentRoutes+NewAssignment.swift` and `AdminRoutes.swift`,
    but both have tight clusters of `private` extension helpers
    shared across adjacent route handlers — splitting would force a
    visibility regression to `internal` purely for LOC reduction, so
    deferred.
  - **#496** Split `APIServerApp.configure(_:)` (210 lines) into three
    bootstrap units under `Sources/APIServer/Bootstrap/`:
    `AppDirectories.swift` (on-disk dirs + worker secret + autostart
    + service stores), `AppMiddleware.swift` (order-sensitive
    middleware chain + sessions + Leaf tags + static-file middleware),
    `AppServices.swift` (database + migrations + lifecycle handlers +
    BrightSpace + SSO config-validation warnings).  `configure(_:)`
    now orchestrates the three.  `APIServerApp.swift` goes 399 → 242
    LOC.  Middleware ordering and storage-seeding semantics preserved
    exactly; the `Application.preloadedAppConfig` test seam keeps
    working.
  - **#499 (partial)** `makeTestApp()` now seeds
    `app.workerSecretFilePath` and `app.localRunnerAutoStartFilePath`
    inside the per-test temp dir.  `AdminRoutesTests` no longer has
    to wire them by hand.  The issue's broader "migrate ~56 tests"
    framing didn't survive code review — the bare-app tests have
    legitimate isolation reasons (single-middleware tests, custom
    workingDirectory layouts, DB-only suites) and would lose intent
    if forced onto `makeTestApp`, so those stay on
    `Application.make(.testing)`.

### Deferred

- **#500** (decompose `assignment-{new,edit}.leaf` into partials) is
  blocked by a LeafKit 1.14.1 cycle-detection false positive — the
  team already hit it at v0.4.91 and the workaround comment lives at
  `Resources/Views/assignment-new.leaf:691`.  A real fix requires an
  upstream LeafKit change or a major upgrade to LeafKit 2.x (Vapor 5
  beta), neither of which belongs in a maintenance PR.
- **#498** (replace `user.role == "student"` string compares with an
  enum/helper) skipped this round.  The five sites are stable, tests
  cover them, and the literal can't be renamed (DB-stored) — the
  compiler-safety argument doesn't earn its keep here.

## [0.4.169] - 2026-05-15

### Changed

- **Server-side env vars now flow through a single `AppConfig`.**  Every
  `Environment.get(...)` call has been consolidated under a typed
  `AppConfig` tree at `Sources/APIServer/Configuration/`.  At startup
  `configure(_:)` loads the entire config once via
  `AppConfig.fromEnvironment(workDir:)`, stores it on
  `Application.appConfig`, and emits a redacted summary to the log.
  Substructs cover auth, OIDC, security, scan mode, database, lockout,
  workers, BrightSpace, diagnostics, and alerts.  Subsystems read
  `app.appConfig.<sub>` instead of calling `Environment.get` directly,
  and tests preload an `AppConfig` via
  `Application.preloadedAppConfig` or pass one to
  `makeTestApp(appConfig:)`.

  No behavioural changes for operators — every env var keeps the same
  name and same defaults.  The CI guardrail
  `grep -rn "Environment.get" Sources/APIServer/` should only return
  hits under `Sources/APIServer/Configuration/`.

  The legacy `WORKER_SHARED_SECRET` alias for `RUNNER_SHARED_SECRET`
  still works but now emits a deprecation warning at startup when it
  was the active source.

### Deprecated

- `CourseBundleManifest.BundledCourse.openEnrollment` (replaced by
  `enrollmentMode` in v0.3.x) is now flagged for removal in **v0.6.0**.
- The `decodeIfPresent ?? false` fallback on
  `NotebookFunctionScannerResult.isShadowed` (browser clients
  pre-v0.4.94) is flagged for removal in **v0.6.0**.

## [0.4.168] - 2026-05-14

### Fixed

- **CSP hotfix: notebook/validate/browser-runner pages would have broken
  in production.**  The Content-Security-Policy introduced in 0.4.167 was
  too strict: it blocked the runtime CDN loads that Pyodide and the
  CodeMirror-based assignment editor depend on.  Specifically, every
  student notebook submission (Pyodide via
  `https://cdn.jsdelivr.net/pyodide/v0.27.0/full/pyodide.js`), every
  instructor in-browser validation, the browser-mode autograder (Pyodide
  plus jszip), and the assignment-new CodeMirror editor (modules from
  `https://esm.sh`) would have failed silently with CSP violations.
  Whitelisted `https://cdn.jsdelivr.net` and `https://esm.sh` in
  `script-src`, `worker-src` (jsdelivr only — esm.sh isn't loaded from
  a worker), and `connect-src` (Pyodide fetches Python wheels at
  runtime).  No staged 0.4.167 deployments were affected.

## [0.4.167] - 2026-05-14

### Added

- **AppScan / vulnerability-scanner hardening pass.**  Five new
  defenses, all live in production after this release:

  1. **`SCAN_MODE=true` operational seatbelt.**  When set, the new
     `ScanModeMiddleware` returns 503 for POSTs against destructive
     routes (`/api/v1/submissions{,/file,/browser-result,/runner-submit}`,
     `/api/v1/testsetups`, `/testsetups/*/submit`,
     `/instructor/*/retest`, `/admin/users/*/delete`,
     `/admin/users/*/role`).  Login, dashboards, admin UI, and static
     files continue to work so the scanner can crawl them.  Disable
     after the scan window by unsetting the env var and restarting.

  2. **Login / register brute-force protection.**  New
     `LoginRateLimitMiddleware` enforces a per-IP cap of
     `LOGIN_RATE_LIMIT_PER_MIN` requests/minute (default 10) on
     `/login` and `/register`.  Beyond the cap, requests get
     `429 Too Many Requests` with `Retry-After`.  Inside the login
     handler, `LoginAttemptStore` tracks per-username failures —
     `LOGIN_LOCKOUT_THRESHOLD` failures (default 5) inside
     `LOGIN_LOCKOUT_WINDOW_SEC` (default 900s) flip the account into
     a sliding-window soft lockout that surfaces as a "Too many
     failed sign-in attempts." message.  A successful login clears
     the failure record.  IP extraction honors `X-Forwarded-For`
     only when `TRUST_X_FORWARDED_PROTO` is true so spoofing behind
     untrusted proxies can't game the cap.  Store is in-memory
     (mirrors `WorkerNonceStore` pattern) — fine for Chickadee's
     single-process deployment.

  3. **Periodic session cleanup.**  Vapor's `_fluent_sessions` table
     gained a `created_at` column (via the new `AddSessionsCreatedAt`
     migration, which uses `DEFAULT CURRENT_TIMESTAMP` so the model
     class stays untouched).  New `SessionReaperLifecycleHandler`
     runs hourly and deletes rows older than 8 days (cookie lifetime
     plus 1-day grace).  Pre-migration NULL rows are preserved and
     roll out as Vapor rewrites them on the next login.

  4. **Security-header polish.**  `SecurityHeadersMiddleware` now
     sets a Content-Security-Policy permissive enough for JupyterLite
     + Pyodide (`script-src 'self' 'unsafe-eval' 'unsafe-inline'`,
     `worker-src 'self' blob:`); a Permissions-Policy that denies
     camera, microphone, geolocation, payment, and several others
     Chickadee never uses; and (when `ENFORCE_HTTPS` is on) a
     2-year `Strict-Transport-Security` header with subdomain
     coverage.  HSTS is gated on enforceHTTPS so dev `http://`
     servers don't get pinned.

  5. **Structured audit logging.**  New `audit_log` table +
     `APIAuditLogEntry` model + `AuditLogger.record(…)` helper.
     Hooks land on user delete, role change, runner secret rotation,
     runner autostart toggle, retest-all, and the three login
     outcomes (success, failure, lockout).  Each row carries actor
     (user + denormalised username), action, target type/ID, remote
     address, User-Agent, and a small JSON `metadata` blob.  Visible
     to admins at the new `/admin/audit` page (linked from the admin
     dashboard, newest 200 rows).

- Tight per-endpoint body limit (8 KB) on `POST /login` and
  `POST /register` so OOM via giant form posts is closed off
  independently of the 10 MB global default.

### Environment variables (new)

- `SCAN_MODE` — `true` to enable the destructive-route 503 seatbelt.
- `LOGIN_RATE_LIMIT_ENABLED` — `false` to disable login throttling
  (defaults to enabled).
- `LOGIN_RATE_LIMIT_PER_MIN` — per-IP login/register request cap
  per 60-second window (default 10).
- `LOGIN_LOCKOUT_THRESHOLD` — failed-login count that triggers
  per-username lockout (default 5).
- `LOGIN_LOCKOUT_WINDOW_SEC` — sliding window in seconds for the
  failed-login counter (default 900).

## [0.4.166] - 2026-05-14

### Changed

- **Closed assignments now load read-only instead of editable.**  When
  a student visits a closed assignment via either the vanity URL
  (`/:courseCode/:assignmentSlug`) or the canonical
  `/testsetups/:id/notebook` route, the JupyterLite iframe now mounts
  in a true read-only mode: cell editors are `contenteditable=false`,
  cell toolbars (run buttons) are hidden, and Shift / Ctrl / Cmd / Alt
  + Enter are swallowed at the iframe-document keydown level so the
  kernel can't be triggered.  The Submit button is replaced by a "This
  assignment is closed — view only." notice.  Past submissions and
  history links continue to work; the server-side
  `requireOpenStudentAssignment` gate on POST endpoints stays as the
  authoritative reject (403).  On the student dashboard, the notebook
  link is now reachable for closed assignments (rendered as an eye
  icon with title "View"); the upload link remains hidden when closed.
  A new `isClosed` flag flows from `NotebookContext` → `notebook.leaf`
  (`data-read-only` on the iframe) → `notebook.js`, which extends the
  existing `applyLockedNotebookUI()` pattern.  No JupyterLite extension
  changes; no Pyodide changes.

## [0.4.164] - 2026-05-14

### Added

- **Worker unit-test coverage for `JobPoller` and `Reporter`.**  Both
  files were at near-zero coverage despite being the entry/exit points
  for the entire grading pipeline.  Coverage now lands at **95.8%** for
  `JobPoller` and **96.7%** for `Reporter`.  A reusable
  `MockURLProtocol` test helper intercepts `URLSession` traffic so every
  status-code branch (200/204/409/500), retry classification
  (401/403/409/400/429/500/502/503/504), retry exhaustion, and wire
  format (HMAC headers, JSON body) is exercised deterministically.
  Source side: the two structs now accept an injected `URLSession`
  (default unchanged) — a one-line testability change with zero
  production-behaviour delta.
- **Runner-side disk-usage telemetry.**  Every job now records
  `freeDiskMBAtStart`, `freeDiskMBAtEnd`, and `workdirPeakBytes` on
  `WorkerExecutionDiagnostics`; the server persists them in both
  `job_execution_metrics` and `submission_diagnostics` via the new
  `AddJobDiskUsageMetrics` migration.  A dedicated
  `job_disk_usage` structured log event also lands at end-of-job so ops
  can answer "are we close to the floor?" without a SQL join.  The
  admin **Runner detail** page (`/admin/runners/:id`) gets a new
  sortable **Peak Disk** column (B/KB/MB/GB) in place of
  **Setup/Other**.
- **`RUNNER_MIN_FREE_DISK_MB` precheck.**  The runner now refuses to
  accept a new job when free space on the staging filesystem is below
  the configured floor (default **128 MB**; set to `0` to disable).
  Failures emit a structured `insufficient_disk_space` event and a
  clear `WorkerDaemonError.insufficientDiskSpace` instead of a cryptic
  mid-job ENOSPC.

### Changed

- **`RunnerProfileDetector` is now async + parallelized + bounded.**
  Capability probes (`python3 --version`, `R --version`, module imports,
  `which bash/zsh`) used to run sequentially with no timeout — a hung
  wrapper could wedge runner startup forever.  Each probe now has a 5 s
  wall-clock cap (`waitWithTimeout`) and the independent probes run
  concurrently via `async let` / `TaskGroup`.  Timeouts surface as
  `capability_detection_timeout` log events.
- **Test-execution loop extracted from `RunnerDaemon.process()`.**
  The ~75-line dependency-gate + script-dispatch + outcome-collection
  block is now `executeTestSuites(manifest:testSetupDir:job:)`; the
  parent method drops from ~270 lines to ~200 with no behaviour change.
- **Heartbeat task respects cancellation precisely.**  The per-job
  heartbeat loop in `RunnerDaemon.process()` now breaks on the
  `CancellationError` thrown by `Task.sleep` instead of firing one
  extra heartbeat after cancel.
- **Conservative disk default per project pattern.**  `minFreeDiskMB`
  defaults to 128, matching the "err on the small side so tight-VM
  deploys work unconfigured" pattern used elsewhere in
  `RunnerDaemonConfig`.
- **`mergeDirectoryContents` uses URL-component walks instead of
  string substitution** for computing relative paths — survives
  `/var` vs `/private/var` aliases and refuses to copy entries that
  resolve outside the source root.
- **Server-authoritative `Total` clarified.**  The Total column on the
  runner detail page is already true round-trip
  (`completed_at − enqueued_at`); the Setup/Other column it replaced
  was the residual.  Removed the now-redundant column.

### Fixed

- **`Total < Queue Wait` could show on the runner detail page during
  in-flight retests.**  `recordJobAssigned` updated `assignedAt` and
  recomputed `queueWaitMs`, but left `completedAt` /
  `totalProcessingMs` (and other per-attempt fields) carrying values
  from the previous attempt — so the row mixed fresh + stale
  timestamps until the retest completed.  Per-attempt fields are now
  cleared on re-assignment.
- **Retest queue-wait was baselined to the original submission time,
  not the retest click.**  The v0.4.45 fix shipped only to
  `APISubmissionDiagnostics`; the canonical `JobExecutionMetric`
  (which drives the admin page) still used `submittedAt`.  Retest
  queue-wait now uses `retestedAt ?? submittedAt` as the baseline,
  matching the legacy diagnostics table.
- **`TestSetupCache` evictions no longer fail silently.**  Disk-delete
  errors during LRU eviction now emit a
  `test_setup_cache_evict_failed` event with path + error type instead
  of being swallowed by `try?`.
- **Two-registry migration footgun.**  Server migrations are
  registered in *two* lists (production `registerMigrations` plus the
  observability-test `registerObservabilityTestMigrations`).  The new
  `AddJobDiskUsageMetrics` is added to both.

## [0.4.163] - 2026-05-14

### Added

- **Personalization expressions can import support files — Slice 5 of
  issue #461.**  The server-side evaluator now spawns `python3` with
  `PYTHONPATH` + cwd pointing at `{testSetupsDirectory}/shared/{setupID}/`
  (the same directory `extractSupportFilesToSharedDirectory` already
  populates after every test-setup save).  The auto-generated driver
  script then `importlib.import_module()`s every `.py` file in that
  directory and binds each as a top-level Python name — so an
  expression `= helpers.caesar_encode(plaintext, shift)` resolves
  directly when `helpers.py` is in the support files.

  **The solution notebook also becomes importable.**  Most assignments
  define their canonical functions (`caesar_encode`, `get_plaintext`,
  ...) in the instructor's `solution.ipynb`.  A new
  `SolutionNotebookExtractor` walks every code cell of `solution.ipynb`
  on save and writes a flat `solution.py` into the shared directory
  alongside support files — unless the instructor uploaded their own
  `solution.py`, in which case explicit beats derived.  Personalization
  expressions then call `solution.caesar_encode(...)` without the
  instructor needing to duplicate helper code into a separate
  `helpers.py`.

  Non-`.py` data files (CSVs, txt fixtures) are also reachable —
  expressions can `open("quotes.txt").read().splitlines()[seed % N]`
  because the subprocess cwd is the support-files directory.

  Pieces:

  - New `Sources/APIServer/Services/SolutionNotebookExtractor.swift`
    — walks `solution.ipynb` JSON, concatenates code-cell `source`,
    writes `solution.py` (skips when the file already exists OR the
    notebook has no code cells).  Called from
    `extractSupportFilesToSharedDirectory` so every existing save path
    picks it up automatically.
  - `PersonalizationEvaluator.evaluate(...)` gains an optional
    `supportFilesDirectory: String?` parameter.  When provided: cwd +
    `PYTHONPATH` are set, every `.py` module under that directory is
    auto-imported in the driver.  Broken modules silently swallow
    ImportError at the import call; they surface as `NameError` at
    expression-eval time if an expression actually references them
    (caught by the existing save-time eval check as a 400).
  - All three call sites (`applyNotebookSubstitutionsIfNeeded`,
    `PUT /global-variables`, `POST /suite-sections/.../variables`)
    pass `req.application.testSetupsDirectory + "shared/\(setupID)/"`.

  Out of scope:

  - Test-script substitution via runner-side bootstrap binding.
  - File-shaped personalized inputs (per-student CSVs delivered to
    the student's workspace).
  - Server-eval sandbox parity with the worker (`sandbox-exec` /
    `unshare`); same trust model as the validation-submission path.

  Backwards compatibility: zero runner changes; no manifest field
  added.  The evaluator's new parameter defaults to `nil`, so the
  Slice 2 behaviour (isolated temp dir) is preserved for any future
  caller that doesn't pass a support dir.

  Tests (`Tests/APITests/SupportImportTests.swift`, 8 cases):
  extractor concatenates code cells / skips markdown / respects
  instructor-uploaded `solution.py` / skips empty notebooks; evaluator
  auto-imports a `.py` support module; data files readable via cwd;
  broken support module is tolerated unless referenced; static global
  shadows same-named import; end-to-end Caesar cipher with chained
  expressions producing a known ciphertext for a known seed.

## [0.4.162] - 2026-05-13

### Changed

- **Worker claim ordering deprioritizes retests (#427).**  Pending
  student submissions with `retested_at IS NOT NULL` (i.e. queued by
  the assignment-revise sweep or a manual retest click) are now
  claimed only after fresh student submissions with `retested_at IS
  NULL` have drained.  Within each group the existing
  oldest-`submittedAt`-first FIFO order is preserved.  This stops a
  manifest-edit retest fan-out from starving students who are
  actively submitting during a term.  Validation submissions are
  unaffected (they're queued separately and never carry a retest
  timestamp).  No schema change — the `retested_at` column added in
  v0.4.45 already doubles as the priority signal.  Implementation is
  an in-Swift `sorted` pass on the existing SQL result so null-handling
  is explicit and portable.

### Fixed

- **Course-scoped submissions page now works for any enrolled user.**
  The instructor dashboard's roster table lists every enrolled user
  (students plus instructors/admins enrolled for testing) and links
  each row to `/instructor/students/:userID/submissions`.  Clicking
  a non-student row used to 404 because the handler
  (`courseStudentSubmissionsPage`) required `role == "student"` on top
  of the enrollment check.  The role filter is gone; enrollment in
  the active course is the sole gate, so instructors and admins can
  now view their own course-scoped submission history through the
  same UI.  Non-enrolled users still 404, preventing cross-course
  leakage.

## [0.4.161] - 2026-05-13

### Added

- **Section variables can carry `=` expressions — Slice 4 of issue
  #461 personalization.**  The per-section "+ Add Input" panel now
  accepts the same `= seed % 26` syntax Slice 2 added to the global
  panel.  Section expressions evaluate per-student at notebook
  first-open with `seed` and every static input (global + every
  section's variables) in scope, and substitute into starter-notebook
  `{{name}}` placeholders alongside literal values.

  Pieces:

  - `TestSuiteSection.expressions: [PersonalizationExpression]`
    (Core).  Optional decode + default `[]` so older manifests
    round-trip cleanly.
  - `POST /instructor/:assignmentID/suite-sections/:sectionID/variables`
    accepts an optional `expressions` array.  Validates
    identifier-shape names, `seed` reservation, cross-namespace
    uniqueness against globals + every other section, and runs a
    save-time eval against the instructor's seed so broken
    expressions surface as 400s before students see them.
  - `applyNotebookSubstitutionsIfNeeded` merges global + section
    expressions into one evaluator input (declared order: globals
    first, then sections, matching the literal precedence).
  - Inline section-vars JS block in `assignment-edit.leaf`
    extracted to `Public/section-inputs-editor.js`, gaining the same
    `=` prefix classification + subtle-green-tint visual cue Slice 2
    added to the global panel.  Per-section toolbar JS
    (`+ Add Script`, `+ Add Family`, etc.) stays inline.
  - `suiteSectionShellRows` renders section expressions in each
    section's editor table with a leading `=` so the JS classifier
    picks them up on load.

  Out of scope this slice (still in the #461 backlog):

  - Test-script substitution via runner-side bootstrap binding.
  - File-shaped personalized inputs.
  - NotebookCheck `$varname` resolution.

  Backwards compatibility: zero runner changes.  Older editor builds
  that POST only `{ variables }` to the section-vars endpoint keep
  working (server defaults the new `expressions` field to `[]`).
  Manifest's `sections[].expressions` decodes empty when absent.

  Tests (`Tests/APITests/SectionInputsTests.swift`, 5 cases): schema
  round-trip with both kinds populated; missing-field decode; manifest
  round-trip; runner-sanitized policy; end-to-end evaluator
  integration via a section expression referencing a global variable.

## [0.4.160] - 2026-05-13

### Changed

- **UI consistency: "enrolled students" count unified across pages.**
  Three places displayed different values for the same course because
  each ran its own enrollment query: `/admin` counted every enrollment
  row (instructors and admins included), `/instructor/:id/submissions`
  counted only logged-in student-role users, and `/instructor` counted
  student-role users plus pre-enrollments.  All three now resolve
  through new helpers in `CourseRosterCounts.swift`
  (`enrolledStudentCountsByCourse`, `enrolledStudentCount(forCourse:)`)
  using one definition: `role=="student"` enrollments plus
  `APIPreEnrollment` rows.  Instructors and admins enrolled in a
  course are excluded.  Affects the admin dashboard "Students"
  column, the admin course-detail "Enrolled students (N)" heading,
  and the assignment submissions page's "Students Submitted X/Y"
  denominator.  No schema changes; the submissions-page table still
  only lists logged-in students, so its denominator may exceed the
  row count when pre-enrolled students haven't signed in yet.
- **Global Inputs panel restyled to match the support-files table.**
  Dropped the standalone `<h2>Global Inputs</h2>` heading and the
  explanatory paragraph.  Each input row now leads with a
  `<strong>Global input</strong>` label cell, and the `+ Add Input`
  control moved into a trailing `<tr>` mirroring the support-files
  "Add support file → + Upload file" pattern.  Stacked back-to-back
  with the support-files table, the two read as one continuous
  table.  Persistence is unchanged (still its own
  `PUT /global-variables` endpoint outside the multipart form).

## [0.4.158] - 2026-05-13

### Added

- **Per-student expressions on Global Inputs — Slice 2 of issue #461
  personalization (notebooks-only).**  The Global Inputs panel now
  accepts rows where the Value cell starts with `=` — e.g.
  `= seed % 26`, `= quotes[seed % len(quotes)]`.  These are
  evaluated server-side at student-notebook first-open with `seed`
  (the per-(student, assignment) integer from Phase 1) and every
  literal global / section variable in scope.  The result
  substitutes into starter-notebook `{{name}}` placeholders
  alongside Slice 1's literal values.

  Pieces:

  - New `PersonalizationExpression` type in Core and a parallel
    `TestProperties.globalExpressions` field.  Decodes empty when
    absent; `runnerSanitized()` strips it (expressions never reach
    the runner — they're a server-side first-open concern).
  - New `PersonalizationEvaluator` service spawns `python3` with a
    generated driver script that binds `seed` + static vars + each
    expression in declared order, then emits a JSON map of
    `{name: repr(value)}`.  5-second timeout; instructor-authored
    code runs with the same trust model as validation submissions.
  - `applyNotebookSubstitutionsIfNeeded` (`WebRoutes+Notebook.swift`)
    now also evaluates expressions per-student before substituting,
    merging the evaluated map on top of literal values so a
    same-named expression overrides a literal (consistent with how
    the editor enforces no name clashes at save time).
  - `PUT /instructor/:assignmentID/global-variables` extended to
    accept `{ variables, expressions }`.  Same-namespace validation
    across both; save-time eval against the instructor's seed
    surfaces broken expressions (`= 1/0`, references to undefined
    names, etc.) as 400s before any student sees them.
  - Editor: `=` prefix in the Value cell switches a row to
    expression mode.  Distinct subtle green background marks
    per-student rows visually; placeholder text and panel hint were
    updated to surface the new syntax.  Pre-existing literal rows
    work unchanged.

  Out of scope (deferred):

  - Test-script access to per-student values.  Test scripts continue
    using the v0.4.156 env-var seed contract (`CHICKADEE_ASSIGNMENT_SEED`)
    for any per-student logic — Slice 2 ships notebook substitution
    only.
  - Section variables with expressions (globals-only this slice).

  Backwards compatibility: zero runner changes — `runnerSanitized()`
  strips `globalExpressions` from the Job manifest, so existing
  runners decode it identically to today.  Older editor builds that
  send only `variables` in the PUT body keep working.

  New tests (`PersonalizationEvaluatorTests`, 12 cases): driver-script
  shape, end-to-end arithmetic + variable + chained-expression
  evaluation, error surfaces (`1/0` → nonZeroExit with the Python
  traceback in stderr, undefined names → `NameError`), repr-output
  shape, and `TestProperties.globalExpressions` round-trip + sanitize.

## [0.4.159] - 2026-05-13

### Fixed

- **Suite editor: drag-and-drop for notebook-check rows.**  v0.4.157
  shipped the notebook-check generator (e.g. `variableExists`) but
  rendered each generated row in the suite editor as if it were a
  hand-written script.  Dragging a check row between sections fired a
  `PUT /suite` that re-asserted the row as `kind: "script"` with the
  generated filename — the server then saw that hand-written script
  *and* the still-active notebook check pointing at the same file and
  refused the save with "would generate '…', but a hand-written file
  with that name already exists."

  The unified suite editor now has a third row kind (`"check"`) that
  round-trips cleanly:

  - `SuiteItemDTO` gains a `check: NotebookCheck?` field; the GET
    handler in `AssignmentRoutes+Suite.swift` emits one `kind: "check"`
    row per check, the PUT handler in `SuiteEditHelpers.swift` accepts
    it and stamps a `.check(id:, sectionID:)` authored item that
    `applyPatternFamilies` already knows how to place.
  - `suite-table.js` recognises check items in `normaliseItems` and
    `buildPayload`, renders a dedicated check row (read-only tier and
    points, label = check name or id), and wires inline Edit / Delete
    buttons.  Edit opens the existing notebook-check modal; Delete
    `PUT`s `/checks` with the check filtered out and reloads.
  - Drop-adopt is suppressed when either side of a drag is a check
    row — there is no `check:<id>` dep token form, so adopting onto
    a check would have produced an invalid manifest dependency.
  - The author-facing rows for hand-written scripts and pattern
    families are unchanged.

## [0.4.157] - 2026-05-12

### Added

- **Generalized Inputs — Slice 1 of issue #461 personalization (UI track).**
  Section "+ Add Input" values now flow into *every* part of the
  assignment they can affect — and a parallel **assignment-scope
  Global Inputs** panel ships at the top of the edit page.  Both
  scopes share the existing `FamilyVariable` shape (name + JSON-able
  value) and the same `+ Add Input` row UX.

  Where the values land at save time:

  - **Pattern-family case args** — `$name` in args JSON resolves to
    the literal at family expansion (existing behaviour, now
    extended to global vars too).
  - **Raw Python test scripts** — `TestScriptVariablePrepender`
    inlines `name = <literal>` lines at the top of every raw `.py`
    script in the test setup zip.  Idempotent: a banner comment
    marks the auto-generated block so re-saves don't accumulate.
    Section vars get this for the first time; globals work the
    same way.
  - **Starter notebook** — `{{name}}` placeholders are replaced
    with `repr(value)` literals at student first-open.  Rewritten
    cells are tagged `metadata.chickadee_personalized = "<name>"`
    so future re-substitutions only touch fenced cells; student
    edits to non-fenced cells survive resets.

  New persistence:

  - `TestProperties.globalVariables: [FamilyVariable]` (optional
    decode; default `[]`).
  - `PUT /instructor/:assignmentID/global-variables` saves the new
    list and runs `applyPatternFamilies` to re-render generated
    tests and re-prepend raw scripts.  Validates that names are
    Python identifiers, `seed` is reserved (Slice 2 personalization
    claim), no duplicates within global, no duplicates against any
    section, and every `{{name}}` in the starter notebook matches a
    declared variable.

  Editor: new "Global Inputs" panel between the file table and the
  test-suite editor on `assignment-edit.leaf`.  Reuses the existing
  `+ Add Input` row markup and `tryParseValue` coercion JS so
  authoring feels identical to section variables.  Debounced
  auto-save with inline status feedback.

  Shell test scripts (`.sh`) don't receive the prepended block —
  variable injection is Python-only.  Documented in
  `docs/inputs.md`.

  Backwards compatibility: zero runner changes.  Existing runners
  receive a manifest + test setup zip with values already inlined
  and notebook substitutions applied server-side.  The new
  `globalVariables` field decodes as empty for older clients; the
  `TestSetupCache` invalidates naturally via the existing
  manifest+zip hash when a variable value changes.

  Deferred to a follow-up: `$varname` references inside
  `NotebookCheck.expected` values (Slice 1 scope; ships static
  expecteds only for now).

  New tests (`Tests/APITests/GlobalInputsTests.swift`, 22 cases)
  cover prepender output, idempotent re-save, shebang preservation,
  notebook substitution with fenced metadata, strict vs lenient
  unknown-placeholder behaviour, array-source-shape preservation,
  and `TestProperties.globalVariables` decode round-trip.

## [0.4.156] - 2026-05-12

### Added

- **Personalized per-student inputs — Phase 1 (issue #461).**  A
  stable per-(student, assignment) random seed is now surfaced to
  every grading subprocess via the `CHICKADEE_ASSIGNMENT_SEED`
  environment variable.  This is the minimum plumbing instructors
  need to write tests that derive per-student expected outputs from
  inside the test script — no editor UI, no generator subprocess,
  no notebook touchpoint, no manifest changes ship yet.

  Pieces:

  - New table `assignment_personalization_seeds` with
    `UNIQUE(user_id, assignment_id)` and cascade-delete from
    `users` and `assignments`.  Migration
    `CreateAssignmentPersonalizationSeeds`.
  - `AssignmentSeedStore.ensureSeed(userID:assignmentID:on:)` —
    lazy generator returning a 64-char lowercase hex string
    (32 random bytes from `SystemRandomNumberGenerator`).
    Idempotent under concurrent first-opens; the DB UNIQUE
    constraint serializes the race and the loser re-fetches the
    winner's row.
  - `Job.assignmentSeed: String?` — new optional field on the
    runner job descriptor; nil-defaulted so older runner versions
    continue to decode cleanly.
  - `WorkerJobRoutes.requestJob` calls `ensureSeed` at job-claim
    time, populating `assignmentSeed` from
    `submission.userID` + the assignment matched by the existing
    requirement loader.  Browser-graded submissions falling back to
    the worker (v0.4.56 backstop) get a seed via the same site.
    Nil-user submissions (rare legacy / no-user path) propagate
    nil and the runner skips env-var injection.
  - `ScriptRunner` protocol grew an `env: [String: String]`
    parameter (with a `[:]` default-overload so existing call
    sites compile unchanged).  Both `UnsandboxedScriptRunner` and
    `SandboxedScriptRunner` propagate the env: macOS uses
    `proc.environment`, Linux uses `execvpe` directly from the
    fork child.  `make` build-step subprocesses are not touched —
    builds remain non-personalized.
  - `RunnerDaemon` injects `CHICKADEE_ASSIGNMENT_SEED` into the
    per-script env only when the Job carries a non-empty seed, so
    non-personalized assignments observe no behaviour change.
  - Instructor-facing contract documented in
    `docs/personalization-phase1.md` with a worked Caesar-cipher
    example, env-var format notes, and an operational warning
    that the seed table is now load-bearing for grading
    correctness (treat as standard DB backup material).

  Phase 2 (manifest field, generator subprocess, submission/
  solution storage split, notebook `{{varname}}` substitution,
  Personalization editor card, `.personalized` pattern kind)
  remains out of scope and is tracked in issue #461.

  New tests:

  - `AssignmentSeedStoreTests` — 6 cases covering creation,
    idempotence, per-student / per-assignment uniqueness,
    concurrent first-access race, and hex output format.
  - `WorkerTests.testScriptReceivesEnvVarFromRunner` /
    `testScriptEnvVarUnsetWhenNoOverride` — end-to-end checks
    that the env actually reaches the spawned subprocess and that
    empty overrides do not leak a value.

## [0.4.155] - 2026-05-12

### Added

- **`NotebookCheckKind.variableExists` — sibling to `.functionExists`.**
  Asserts that a named module-level variable is defined on the student
  module, optionally with a runtime type precondition.  Used as a cheap
  gate before downstream value / shape checks so a missing variable
  fails clearly instead of erroring every dependent test.

  - **Bare existence**:
    `getattr(student_module, name, _MISSING) is _MISSING → fail`.
    `None` counts as defined, matching `.functionExists`'s "defined"
    semantics.
  - **Optional `expectedType`** (e.g. `"int"`, `"list"`, `"DataFrame"`,
    `"ndarray"`): appends an `isinstance` check for Python builtins or
    an MRO-name walk for library types, matching `PatternFamilyRenderer`'s
    `.returnTypeCheck` mapping byte-for-byte.  Unknown names fall back
    to a class-name MRO walk so student-defined classes and new library
    types work without a Swift edit.
  - **Validator** requires `variable` to be a non-empty Python
    identifier; rejects empty / whitespace-only `expectedType`.
  - **Editor UI** ships a "Variable exists (defined, optional type)"
    option in the notebook-check kind dropdown, with a free-form
    variable name input and a free-form type input.
  - **Runner-safe**: `TestProperties.runnerSanitized()` already strips
    `notebookChecks` before encoding to the runner manifest, so older
    runner binaries never see the new enum case.

## [0.4.154] - 2026-05-12

### Fixed

- **Critical: v0.4.153 cache-bust would wipe every existing student's
  in-progress IndexedDB work on their first post-deploy visit.**  The
  decision in `syncNotebookFromServerSnapshot` was
  `serverMtime > 0 && serverMtime > seenMtime`.  On the first post-
  deploy visit `localStorage["chickadee_nb_mtime_<setupID>"]` is empty,
  so `seenMtime = 0`, so any positive server mtime (i.e. any working
  copy file that exists) would be treated as "newer than my baseline"
  and force-overwrite the local IndexedDB copy.  v0.4.153 was
  identified-but-never-deployed; this fix went in before
  Jim pulled to production.

  Extracted the decision into a pure function
  `shouldForceReseed({ serverMtime, seenMtime })` (now exposed via
  the existing test-hooks export for unit-testing) and added a
  baseline-required guard:

      if (!serverMtime || serverMtime <= 0) return false;
      if (!seenMtime  || seenMtime  <= 0) return false;
      return serverMtime > seenMtime;

  Absence of a baseline (`seenMtime === 0`) is now treated as "no
  prior observation, do nothing destructive" — the localStorage stamp
  is still written at the end of the sync function so the *second*
  visit has a baseline to compare against, and only resets that
  happen *after* the baseline is recorded fire the force-reseed.

  Regression tests: 8 cases in new
  `Tests/BrowserRunnerJSTests/sync-force-reseed.test.mjs`, pinning
  the safety-critical cases (first-visit-after-deploy, missing
  server mtime, negative/NaN inputs) and the working-as-designed
  cases (server unchanged, after-instructor-reset).

## [0.4.153] - 2026-05-12

### Added

- **Instructor action: reset a student's working-copy notebook back to
  the assignment starter.**  Used when a student corrupts their own
  notebook — most commonly by uploading a broken `.ipynb` via the
  fallback panel that overwrites their working copy.  New icon-only
  trash-can button in the Action column on
  `/instructor/:assignmentID/submissions`, sitting alongside the
  existing Re-test action (also restyled as an icon for consistency
  with the assignments list on `/instructor`).  Confirmation dialog
  warns that past submissions are NOT affected (they remain in the DB
  for forensic review).

  New endpoint:
  `POST /instructor/:assignmentID/students/:studentID/reset-notebook`.
  Hard-gated to instructor role (existing `RoleMiddleware`).  Resolves
  the assignment → test setup, verifies the target student is
  enrolled in the same course, reads the canonical starter via
  `notebookData(for: setup)` (which extracts it from the test-setup
  zip or `setup.notebookPath`), and calls `ensureUserNotebookWorkingCopy`
  with `overwriteWith:` to force a clean re-seed.

  **End-to-end cache-bust** so the student's browser actually sees
  the reset without any manual cache-clear: every render of the
  notebook page now stamps the iframe with
  `data-working-copy-mtime="<unix-epoch-seconds>"` (the on-disk mtime
  of the user's working copy).  `Public/notebook.js`'s
  `syncNotebookFromServerSnapshot` persists the last-seen mtime per
  setup in `localStorage`; when the server's mtime is *newer*, the
  client force-overwrites the in-browser IndexedDB copy with the
  server snapshot instead of preserving local edits.  This makes the
  instructor reset visible on the student's next page load with no
  cache-clear required.  After a student submission the mtime also
  bumps (the working-copy file is rewritten with the submitted
  bytes) — force-reseed in that case is a no-op because the bytes
  match what's already in IndexedDB.

  Files: `Resources/Views/assignment-submissions.leaf` (icon
  buttons + reset action), `Resources/Views/notebook.leaf`
  (new iframe attribute), `Sources/APIServer/Routes/Web/AssignmentRoutes.swift`
  (route registration), `Sources/APIServer/Routes/Web/AssignmentRoutes+Submissions.swift`
  (new handler), `Sources/APIServer/Routes/Web/AssignmentContextTypes.swift`
  (new `studentUUID` field on `AssignmentStudentRow`),
  `Sources/APIServer/Routes/Web/WebContextTypes.swift` (new
  `workingCopyMtime` on `NotebookContext`),
  `Sources/APIServer/Routes/Web/WebRoutes+Notebook.swift`
  (`workingCopyMtimeEpoch` helper + populated context),
  `Public/notebook.js` (mtime-aware preservation logic).

  Tests: 3 cases in `Tests/APITests/AssignmentRoutesTests.swift`
  covering successful overwrite, prior-submissions-preserved, and
  the unenrolled-student rejection path — plus an assertion that the
  reset bumps the file mtime (the cache-bust signal).
  `Tests/APITests/NotebookWebRoutesTests.swift`'s notebook-page
  render test now asserts `data-working-copy-mtime` is a positive
  integer.

## [0.4.152] - 2026-05-12

### Fixed

- **Watchdog phase-2 (kernel-unhealthy) was false-positiving on healthy
  kernels.**  Hotfix on top of v0.4.151.  The kernel probe required
  *positive evidence of health* — specifically the strings `| Idle`
  or `| Busy` in the iframe DOM text, or `idle`/`busy` from
  `ServiceManager.sessions.running()`.  In Safari, where Pyodide WASM
  bootstrap can legitimately take longer than 60 s, and where the
  status indicator's exact DOM text may not match what we look for, a
  healthy kernel still in "Starting" / "Connecting" state would be
  flagged as failed and the fallback panel would hide the live editor.

  Jim observed this directly: notebook visibly loaded, Pyodide
  running, assignment rendered — and ~1 minute later the watchdog
  hid it all and posted a phase-2 `watchdog_timeout` row with
  `failed_checks=["kernel-unhealthy"]`.  Same class of false positive
  as v0.4.150's phase-1 bug, different probe.

  Inverted the probe semantics: `isKernelHealthy` is now
  `isKernelInFailureState`, returning true ONLY on **positive
  evidence of failure** — `Kernel Unknown` text in the iframe DOM
  (the original Hans symptom), or a session reporting
  `dead`/`unknown` kernel status via the ServiceManager API.
  Absence of evidence (kernels still bootstrapping, status text
  rendered differently than expected, cross-origin access blocked)
  is now treated as healthy.  Watchdog only fires phase 2 on the
  specific failures we know how to recognise.

  Phase-2 logic in `armEditorWatchdog` rewritten to match: instead of
  a kernel-readiness deadline, we have a kernel max-observation
  window (120 s) after which we silently stop polling — the user has
  a working editor and we shouldn't keep watching forever.  We fire
  the fallback only if `isKernelInFailureState` returns true at any
  poll within that window.

  Regression tests expanded from 10 → 18 cases in
  `Tests/BrowserRunnerJSTests/watchdog-probe.test.mjs`, including
  explicit guards for "starting", "no status text visible", and
  "API access throws" — all of which now correctly return *not in
  failure state*.

## [0.4.151] - 2026-05-12

### Fixed

- **Watchdog spuriously fires "Editor didn't load" while JupyterLite is
  actually working (Safari).**  The phase-1 readiness signal introduced
  in v0.4.149 was `frame.contentWindow.jupyterapp` truthy from the
  parent frame.  In Chromium this works fine; in Safari (and possibly
  other WebKit builds) cross-process iframe isolation can make that
  JS-property probe return undefined from the parent even when
  JupyterLite is fully loaded and the kernel is alive in the iframe.
  Result: students saw the editor running, then ~45 s later the
  fallback panel hid the iframe and posted a
  `watchdog_timeout` (phase-1) row — even though they could see the
  notebook and Pyodide was idle.

  Two fixes:
  1. **Layered readiness probe**: `Public/notebook.js`'s
     `probeIframeReadiness()` now also looks at the iframe's *DOM*
     (`.jp-Toolbar`, `.jp-Notebook`, any `.jp-*` class on the body)
     and the kernel status text (`| Idle` / `| Busy`).  DOM access
     is more permissive than arbitrary JS-property access from the
     parent, so the probe sees what the user sees on screen.
  2. **Latch `shellLoadedAt`**: once the shell is detected, the
     watchdog never regresses to phase 1 — even if a later poll
     fails to see the UI (intra-iframe navigation, transient access
     errors, etc.).  Phase 2 (kernel-unhealthy) is still possible
     after latch.

  Deadlines raised to be more forgiving given the campus-network
  packet-loss we observed on the night of v0.4.150 deployment:
  shell phase 45 s → 60 s, kernel phase 30 s → 60 s.

## [0.4.150] - 2026-05-11

### Fixed

- **"Kernel Unknown" failure in the in-browser notebook editor.**
  Hans reported (and reproduced on a managed-device MC Mac) that
  JupyterLite was hanging in "Kernel Unknown" after ~10 seconds, with
  the network panel showing POSTs to `/jupyterlite/api/drive`
  returning **404**.  Root cause: in JupyterLite 0.7.x the
  pyodide-kernel auto-mounts the JupyterLite Drive whenever the
  `serviceWorkerManager?.enabled` is truthy
  (`mountDrive = !!(serviceWorkerManager?.enabled || crossOriginIsolated)`).
  With `mountDrive=true` the kernel POSTs to `/api/drive` expecting
  the service worker to intercept them and broadcast the calls to the
  in-browser drive plugin — but on Chickadee the SW interception was
  not reliable (the precise reason is still unclear; checked MIME and
  scope, both correct; suspect a registration / `controller` race
  with managed-device browsers).  The requests reached the server and
  404'd, the kernel's promise chain broke with
  `Uncaught (in promise)` at `client.js:148`, and the session ended
  in "Unknown" forever.

  The fix disables the JupyterLite service-worker-manager plugin via
  `disabledExtensions` in `Tools/jupyterlite/jupyter-lite.json`.
  That makes `serviceWorkerManager?.enabled` falsy in the kernel, so
  `mountDrive` is forced to `false` and the kernel logs
  *"Pyodide contents will NOT be synced with Jupyter Contents"*
  instead of attempting the broken sync.  We don't rely on the
  JupyterLite Drive — Chickadee has its own server-side snapshot
  mechanism (`syncNotebookFromServerSnapshot` in `Public/notebook.js`,
  `ensureUserNotebookWorkingCopy` in
  `Sources/APIServer/Routes/Web/WebRoutes+Notebook.swift`) that
  predates the Drive feature and remains the source of truth.

  Bonus while editing the bundle config: the stale `appVersion` label
  is corrected from `0.7.1-chickadee.2` to `0.7.6-chickadee.1` so the
  reported version matches the actual JupyterLite pin from
  `Tools/jupyterlite/requirements.txt`.

  Side-effects to be aware of: with the service worker manager
  disabled, JupyterLite's SW no longer registers at all.  That means
  no stdin (rare in our coursework; `input()` in cells will hang) and
  no SW-based asset caching (asset reloads each visit, negligible at
  our scale).  Whether to revisit and adopt JupyterLite's native
  Drive sync for storage — replacing our snapshot bridge — is
  captured as a separate roadmap issue on GitHub.

- **JupyterLite config regression tests.**  Added
  `Tests/APITests/JupyterLiteConfigTests.swift` with two guards on
  the built `Public/jupyterlite/jupyter-lite.json`:
  `testBundleDisablesServiceWorkerManager` (the disable above must
  be present), and `testBundleAppVersionMatchesRequirementsPin`
  (the `appVersion` label must match the pinned `jupyterlite==X.Y.Z`
  in `Tools/jupyterlite/requirements.txt`).  Both fail loudly if a
  future JupyterLite bump forgets to update the source config.

## [0.4.149] - 2026-05-11

### Added

- **Client-side diagnostics for the in-browser notebook editor.**  The
  student submit page now runs a capability preflight (WebAssembly, Web
  Workers, service-worker registration, IndexedDB open) before mounting
  the JupyterLite iframe, then arms a two-phase watchdog on the
  JupyterLite readiness signals after mount: 45 s for the JupyterFrontEnd
  app shell to come up, plus a further 30 s for the Pyodide kernel to
  reach `idle`/`busy`.  The second phase catches the
  "JupyterLite loaded but kernel is Unknown" failure mode — a real one
  we've observed in the wild on Windows machines where the app shell
  mounts fine but the kernel never starts.  Watchdog records of that
  shape post `failedChecks: ["kernel-unhealthy"]` so the subtype is
  preserved on the row.  On either failure mode the iframe is hidden,
  a fallback section is revealed with a direct `.ipynb` upload picker
  (the existing upload-fallback JS re-used unchanged), and a record is
  posted to a new endpoint `POST /api/v1/client-diagnostics` (kinds:
  `preflight_fail`, `watchdog_timeout`).  When all checks pass the page
  is visually identical to before — no UI changes are made unless a
  failure occurs.  Records are stored in a new `client_diagnostics`
  table and rate-limited per (user, setup, kind) to one row per hour.
  Files: `Public/notebook-preflight.js`, `Public/sw-preflight.js`,
  `Public/notebook.js` (preflight gate + two-phase watchdog),
  `Resources/Views/notebook.leaf`,
  `Sources/APIServer/Routes/ClientDiagnosticsRoutes.swift`,
  `Sources/APIServer/Models/APIClientDiagnostic.swift`,
  `Sources/APIServer/Migrations/CreateClientDiagnostics.swift`.

- **JupyterLite bumped to 0.7.6 (was 0.7.1); pyodide-kernel bumped to
  0.7.2 (was 0.7.0).**  Picks up patch fixes in the 0.7.x series — most
  notably 0.7.6's "Fix service worker heartbeat bind so that it is
  called repeatedly," which addresses a known cause of the
  service-worker channel going stale and the Pyodide kernel ending up
  in the "Unknown" state without recovering.  Same family of failure
  the new watchdog now detects.  `Tools/jupyterlite/requirements.txt`
  pins updated; `Public/jupyterlite/` regenerated by
  `scripts/build-jupyterlite.sh`.  `scripts/verify-jupyterlite.sh` no
  longer hard-codes the content-hashed `remoteEntry.*.js` filename —
  it now globs, so future patch bumps won't break verification.

### Changed

- **Instructor dashboard card "Students With No Submissions" replaced
  with "Students With Browser Errors".**  The new card counts distinct
  students who posted a `client_diagnostics` record (preflight or
  watchdog failure) for one of the course's test setups within the
  same 24-hour window as the other dashboard metrics.  Diagnostics with
  a null `test_setup_id` (the supplied ID didn't resolve, e.g. the
  setup was deleted) are excluded since they can't be attributed to a
  course.  The regression test
  `testInstructorDashboardCountsPendingPreEnrollmentsAsNoSubmissionYet`
  is replaced with
  `testInstructorDashboardCountsStudentsWithBrowserErrors`.

## [0.4.147] - 2026-05-11

### Changed

- **Server health alert "error rate spike" no longer counts student-code
  failures.** Previously the rule fired whenever ≥ 30% of recent
  `JobExecutionMetric` rows had `finalStatus` of `error` or `timeout` — but
  `inferredFinalStatus(from:)` rolls a single per-test `error`/`timeout` up to
  the job level, so any assignment with buggy starter code or aggressive
  per-test time limits could trip the alert.  The rule now classifies a row
  as a system failure only when `finalStatus` is `error`/`timeout` AND the
  matching per-test counter (`testsErrored` / `testsTimedOut`) is zero — i.e.
  the runner itself failed or the worker timed out a job before any test
  reported.  Alert label renamed to "System-level failure rate spike";
  webhook detail keys renamed (`error_count` → `system_failure_count`,
  `error_rate_percent` → `system_failure_rate_percent`).  Helper
  `JobFailureClassification.isSystemFailure(finalStatus:testsErrored:testsTimedOut:)`
  added so the predicate is unit-testable without spinning up a DB.

## [0.4.146] - 2026-04-30

### Changed

- **BrightSpace auth switched to D2L Valence key signing (#463).** The initial
  implementation used OAuth2 client credentials; UWaterloo LEARN uses the older
  Valence "App + User" key model instead. Each request URL is now signed with
  HMAC-SHA256 using App Key (`x_c`) and User Key (`x_d`) — no token endpoint
  required. Env vars updated: `BRIGHTSPACE_CLIENT_ID` / `BRIGHTSPACE_CLIENT_SECRET`
  replaced by `BRIGHTSPACE_APP_ID`, `BRIGHTSPACE_APP_KEY`, `BRIGHTSPACE_USER_ID`,
  `BRIGHTSPACE_USER_KEY`. Credentials are obtained via the UW D2L credential
  harvester (`d2l-api-cred.fast.uwaterloo.ca`).

## [0.4.145] - 2026-04-30

### Added

- **BrightSpace grade sync (#462).** Chickadee now pushes grades to the D2L
  BrightSpace REST API automatically whenever a grading result arrives.
  A 60-second background sweep picks up pending results after a configurable
  debounce window (default 90 s) so rapid resubmissions coalesce into a
  single API call.  The student's best grade across all attempts is what
  gets pushed.  On BrightSpace error the row stays pending and is retried
  on the next sweep.
  - New env vars: `BRIGHTSPACE_URL`, `BRIGHTSPACE_CLIENT_ID`,
    `BRIGHTSPACE_CLIENT_SECRET`, `BRIGHTSPACE_SYNC_DEBOUNCE_SECS` (optional).
    Sync is entirely disabled when the vars are absent — zero overhead for
    non-BrightSpace deployments.
  - Per-course **Org Unit ID** field on the Admin → Course page.
  - Per-assignment **Grade Item ID** field in a collapsible "BrightSpace Grade
    Sync" section on the assignment editor.
  - D2L internal user IDs are resolved by `OrgDefinedId` (student number) on
    first sync and cached on `APIUser`.
  - New migration `AddBrightSpaceSyncFields` adds sync-pending columns to
    `courses`, `assignments`, `users`, and `results`.

## [0.4.144] - 2026-04-30

### Changed

- **Untangled `OperationalDiagnostics.swift` (#444).**  The 1523-line
  file interleaved Fluent persistence, structured logging, and pure
  bucket/stage math inside `recordWorkerExecutionReport()` (lines
  477–630) and `metricsTimeSeriesSnapshot()` (lines 837–964).  Two
  pure helpers now own the math:
  - `StageTimingAggregator` (`Sources/APIServer/Diagnostics/StageTimingAggregator.swift`)
    wraps `WorkerExecutionStageTimings`, applies the 10 stage fields
    onto a `JobExecutionMetric` via `apply(to:)`, and exposes
    `totalKnownStageMs` for downstream consumers.
  - `MetricBucketAccumulators` + `BucketWindow`
    (`Sources/APIServer/Diagnostics/MetricBucketAccumulators.swift`)
    own window resolution (clamping hours/bucketMinutes), bucket
    indexing, the three sample accumulators (runner/request/job),
    response building, and the `percentile`/`average`/`percentile95`
    helpers.
  `OperationalDiagnosticsService` keeps every public signature; both
  target functions now read top-to-bottom as orchestration.  File
  drops from 1523 → 1380 lines.

- **`ResultRoutes` migrated to typed errors.**  The two
  `throw Abort(...)` sites in `reportResults` now raise
  `WorkerJobError.invalidBody` / `WorkerJobError.unprocessableBody`,
  matching the typed-error pattern adopted by `WorkerJobRoutes` and
  the v0.4.143 `WebAssignmentError` work.  HTTP status codes are
  preserved (400 for empty body, 422 for malformed JSON).

### Added

- **`WorkerJobError.unprocessableBody(reason:)`.**  New case mapping
  to HTTP 422 (`unprocessableEntity`), used when a request body is
  syntactically valid but its semantic content fails to decode into
  the expected schema.  Complements the existing `.invalidBody`
  (HTTP 400) case.

- **`StageTimingAggregatorTests` and `MetricBucketAccumulatorsTests`
  (25 new test cases).**  The pure helpers had no test coverage
  previously because the math was buried inside async methods that
  required a `Request` and a database.  New tests cover: stage
  timing field round-trips, `totalKnownStageMs` aggregation,
  `BucketWindow.resolve` clamping (`hours ∈ [1, 72]`,
  `bucketMinutes ∈ [1, 60]`), `bucketIndex` boundary behaviour,
  utilization clamping (0/100), `maxJobs == 0` handling, status
  routing across all four `JobFinalStatus` values, percentile/average
  edge cases, and one end-to-end pinned scenario that fixes
  bucket-by-bucket expectations.

## [0.4.143] - 2026-04-30

### Changed

- **Completed `WebAssignmentError` typed-errors migration across the
  instructor assignment routes (#442).**  PR 456 (#443) introduced
  `WebAssignmentError` and migrated the 19 sites in
  `AssignmentRoutes.swift` itself, leaving ~120 `Abort(...)` sites in
  the sibling extensions and helpers as deferred work.  This release
  finishes that migration: every `throw Abort(...)` in
  `Routes/Web/Assignment*.swift`, `SuiteEditHelpers.swift`,
  `TestSetupZipHelpers.swift`, `RunnerValidationHelpers.swift`,
  `AssignmentSlugHelpers.swift`, and `AssignmentHelpers.swift` is now
  a typed `WebAssignmentError` throw.  Files migrated this release
  (count of original sites): `AssignmentRoutes+Editor.swift` (40),
  `AssignmentRoutes+Sections.swift` (15), `+SuiteSections.swift` (13),
  `+DraftSections.swift` (13), `+Draft.swift` (11), `+Submissions.swift`
  (8), `+Enrollment.swift` (8), `+Suite.swift` (1), `+Families.swift`
  (1), `+Checks.swift` (1), `SuiteEditHelpers.swift` (9),
  `AssignmentSlugHelpers.swift` (3), `TestSetupZipHelpers.swift` (1),
  `RunnerValidationHelpers.swift` (1), `AssignmentHelpers.swift` (1).
  HTTP status codes are preserved across the migration — every
  `Abort(.X, ...)` was mapped to the `WebAssignmentError` case whose
  `status` is `.X`.

### Added

- **`WebAssignmentError.unprocessable(reason:)`.**  Maps to HTTP 422
  (`unprocessableEntity`).  Used by the four section-variable validation
  sites that reject malformed Python identifiers and duplicate names —
  these are well-formed requests with semantically invalid content,
  which is exactly what 422 means.  Pre-existing cases
  (`notFound`, `invalidParameter`, `noActiveCourse`, `forbidden`,
  `conflict`, `validationRequired`, `internalFailure`) cover the
  remaining four statuses (404, 400, 403, 409, 500).

- **`WebAssignmentErrorTests.swift`.**  Two regression guards: (i) a
  parameterised test that walks every `WebAssignmentError` case and
  asserts the rendered HTTP status matches its documented contract,
  catching switch-statement typos that the compiler can't; (ii) a
  source-grep test that fails if any in-scope file reverts to a raw
  `throw Abort(`, locking in the migration so a future copy-paste
  regression gets caught at PR time instead of in production traffic.

## [0.4.142] - 2026-04-30

### Changed

- **Split `AssignmentHelpers.swift` (#442).**  The 2310-line file mixed
  manifest mutation, zip member ops, notebook scaffolding, multipart
  helpers, draft state, slug allocation, requirement detection, suite-row
  builders, and runner-validation glue.  Each concern now has its own
  file:

  - `ManifestFileHelpers.swift` — `manifestDependents`,
    `generatedByFamilyID`, `setupHasAnyTestEntries`,
    `updateManifestAddingScript`, `updateManifestRemovingScript`,
    `makeWorkerManifestJSON`, `topologicallySorted` (private),
    `manifestHash`.
  - `TestSetupZipHelpers.swift` — `ScriptZipError`, `RunnerSetupPackage`,
    `listZipEntries`, `readScriptFromZip`, `updateScriptInZip`,
    `applyScriptChangesToZip`, `removeScriptFromZip`, `extractZipEntry`,
    `buildFileResponse`, `contentType`, `createRunnerSetupZip`,
    `writeEmptyZip` (private), `extractSupportFilesToSharedDirectory`.
  - `NotebookScaffoldHelpers.swift` — `minimalEmptyNotebookData`,
    `notebookFilenameForStorage`, `submissionFilenameForStorage`,
    `autoScaffoldFromSolutionNotebook`, `defaultNotebookData`,
    `removeMaterializedNotebookFiles`.
  - `MultipartHelpers.swift` — `urlEncode`, `multipartParts`,
    `multipartFiles`, `multipartTextField`.
  - `AssignmentDraftHelpers.swift` — `ExistingSolution`,
    `NewAssignmentDraftFormState`, `DraftRequirementSuggestions`,
    `loadExistingSolution`, `existingSolutionFilename`,
    `draftFormStateSessionKey`, `loadDraftFormState`,
    `saveDraftFormState`, `clearDraftFormState`,
    `draftNotebookDirectory`, `draftSolutionNotebookPath`,
    `ensureDraftNotebookDirectory`, `draftNotebookData`,
    `removeDraftNotebookFiles`.
  - `AssignmentSlugHelpers.swift` — `assignmentByPublicID`,
    `uniqueAssignmentSlug`, `isValidAssignmentPublicID`,
    `assignmentPublicIDParameter`, `createAssignmentWithUniquePublicID`.
  - `AssignmentRequirementHelpers.swift` — `parsedRequirementCSV`,
    `assignmentRequirementSpec`, `detectRequirementSuggestions`,
    `pythonCapabilitySuggestions` (private),
    `loadAssignmentRequirementSpec`.
  - `RunnerValidationHelpers.swift` — `RunnerValidationOutcome`,
    `enqueueRunnerValidationSubmission`,
    `scheduleValidationAfterSuiteEdit`, `retestAllSubmissionsForSetup`,
    `waitForRunnerValidation`, `ensureValidationRunnerAvailability`,
    `hasCompatibleValidationRunner`,
    `ensureCompatibleValidationRunnerAvailability`.
  - `SuiteRowHelpers.swift` — `EditSuiteConfigRow`,
    `ReindexedSuiteConfigRow`, `ResolvedEditSuiteFiles`,
    `SuiteConfigRow`, `ConfiguredSuiteEntry`, `currentSetupFiles`,
    `resolveEditSuiteFiles`, `editableSuiteRowsForSetup`,
    `authoredSuiteItemsFromDraftManifest`, `familySuiteRowsForSetup`,
    `mergeExistingFilesIntoSuiteFiles`, `sanitizeSuiteFilename`,
    `buildSuiteEntries`, `inferredOrder`, `normalizeTier`,
    `isLikelyTestSuiteFile`, `hasRecognizedScriptShebang`.

  `AssignmentHelpers.swift` (181 lines residual) keeps the small
  cross-cutting helpers — section-ID resolution, due-date
  parsing/formatting, human-name splitting, return-path sanitization,
  deadline-override helpers, sort-order allocation, grade extraction,
  CSV escaping, and student-ID name inference.  No behaviour changes —
  pure relocation; `swift test` is green pre- and post-split.

## [0.4.141] - 2026-04-30

### Changed

- **Decomposed three oversized handlers in `AssignmentRoutes.swift`
  (#443).**  `list()` (~380 lines), `newAssignmentPage()` (~190 lines),
  and `saveNewAssignment()` (~350 lines) each interleaved Fluent
  queries, dashboard-metric computation, multipart fan-in, validation,
  inline error redirects, and view-context assembly in one block —
  every UI fix required re-reading hundreds of lines of unrelated
  logic.  Each is now a thin orchestrator over focused helpers:

  - `AssignmentRoutes+List.swift` — `loadCourseSetups`,
    `loadCourseAssignments`, `loadCourseSections`, `buildCourseRoster`
    (rolls up enrolled-student rows + the five dashboard metric cards
    in one place), `loadUniqueSubmittersBySetup`, `buildAssignmentRows`,
    `sortAssignmentRows`, `groupRowsBySection`, plus a
    `placeholderDashboardMetrics()` for the no-active-course path.
  - `AssignmentRoutes+NewPage.swift` — context-builders for the new-
    assignment page: `newAssignmentNotebookContext`,
    `newAssignmentSolutionNotebookContext`,
    `newAssignmentSupportFileRows`,
    `newAssignmentRequirementSuggestions`, plus three JSON-seed helpers
    (`newAssignmentDraftIDJSON`, `newAssignmentPatternFamiliesJSON`,
    `newAssignmentNotebookChecksJSON`) and `loadNewAssignmentSectionPicker`.
  - `AssignmentRoutes+SaveValidation.swift` — `parseSaveNewAssignmentForm`
    consolidates the dual `SaveBodyMany` / `SaveBodySingle` decode paths;
    `validateSaveNewAssignment` returns
    `SaveNewAssignmentValidation.valid(ValidatedSaveNewAssignment)` or
    `.redirect(toURL:)` instead of the ~10 inline `req.redirect` calls
    the original handler had; `newAssignmentErrorRedirect` is the single
    place that composes the bounce-back URL.

  Behaviour is unchanged: every guard, redirect, and dashboard-metric
  formula is preserved.

- **Adopted `WebAssignmentError` typed errors throughout the touched
  code.**  New cases on `APIErrors.swift`: `notFound(resource:)`,
  `invalidParameter(name:reason:)`, `noActiveCourse(action:)`,
  `forbidden(action:)`, `conflict(reason:)`,
  `validationRequired(reason:)`, `internalFailure(reason:)`.  All 19
  `Abort(...)` sites in `AssignmentRoutes.swift` migrated to typed
  throws; the remaining ~114 sites in the `+Editor`, `+Submissions`,
  `+Sections`, `+SuiteSections`, `+DraftSections`, `+Draft`,
  `+Enrollment`, `+Suite`, `+Families`, and `+Checks` extensions
  follow the project's "migrate incrementally as those files are
  touched for other reasons" strategy and stay unchanged in this PR.

## [0.4.140] - 2026-04-30

### Changed

- **Centralized runner env-var reads in a `RunnerDaemonConfig` struct
  (#450).**  Eight `RUNNER_*` env vars were read independently from
  three different files (`RunnerDaemon`, `RunnerNetworkResilience`,
  `RunnerProfileDetector`).  Each subsystem decided on its own when to
  read and how to parse, so a misconfigured env var only surfaced once
  the relevant code path ran.

  Adds `Sources/Worker/RunnerDaemonConfig.swift`.  `WorkerCommand.run()`
  now builds the config once at startup via
  `RunnerDaemonConfig.loadFromEnvironment()` and threads it through
  `Reporter`, `WorkerDaemon`, and the `RunnerRetryPolicy.poll/heartbeat/
  resultUpload/download` factories.  The factories' `config:` parameter
  has a `.loadFromEnvironment()` default so existing tests that
  construct `WorkerDaemon` without an explicit config still work.

  The legacy `runnerEnvironmentBool` / `runnerEnvironmentInt` helpers
  in `RunnerProfileDetector.swift` and `RunnerNetworkResilience.swift`
  are removed — no production callers remain.  New
  `RunnerDaemonConfigTests` exercises the env-parsing rules
  (bool aliases, invalid-value fallback, empty-string-as-absent for
  `RUNNER_TEST_SETUP_CACHE_DIR`).

### Removed

- **Dead `validateManifest()` umbrella in `ManifestValidation.swift`.**
  Defined but never called; folded the cleanup into this PR while
  triaging #447 (which was closed as not-planned — its premise of
  duplicate validation was not borne out by the actual call graph).

## [0.4.139] - 2026-04-30

### Changed

- **Reuse a static `JSONDecoder` / `JSONEncoder` for `TestProperties`
  manifest I/O (#446).**  Roughly 40 sites across the server and
  runner were allocating a fresh `JSONDecoder` (and a few a fresh
  `JSONEncoder`) per request to decode the manifest — every
  assignment edit, suite save, validate, and student submission view
  paid the allocation.  Several routes also kept a local
  `let decoder = JSONDecoder()` followed by a single decode call.

  Adds `Core/ManifestCodec.swift` with
  `nonisolated(unsafe) public static let decoder/encoder` (default
  config; `TestProperties` has no `Date` fields).  Migrates every
  call site that decodes or encodes a manifest to use the shared
  instances.

  Sites that decode `Date`-bearing types (`TestOutcomeCollection`,
  `WorkerExecutionReport`, `Job`) keep their iso8601-configured
  decoders; sites that need `outputFormatting = [.sortedKeys]` for
  canonical hash input (`PatternFamilyRenderer`, `NotebookCheckRenderer`,
  the in-line manifest sub-encoders in `AssignmentRoutes`) also stay
  local, since their config isn't `ManifestCodec`'s default.

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
