# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project follows Semantic Versioning.

## [Unreleased]

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
