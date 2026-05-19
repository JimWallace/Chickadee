# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project follows Semantic Versioning.

## [Unreleased]

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
