# Feature interactions

Most Chickadee features act on the same few objects: a deadline, an
enrollment, a manifest entry, a test outcome. A change can be correct for one
feature and a defect in another feature that reads the same object. This
document is the map of those objects. For each object, it gives the features
that write it, the features that read it, and the rules that must stay true.

The `interaction-review` agent (`.claude/agents/interaction-review.md`) uses
this map as its checklist. CI runs the agent on every pull request that
changes `Sources/` or a `Public/*.js` file
(`.github/workflows/interaction-review.yml`). Human reviewers can use the map
in the same way.

## How to use this map

- A change **touches** an object when it does one of these:
  - It writes the object or reads it.
  - It changes the meaning or the default of the object.
  - It adds a new path that computes the object.
- The lists of readers are a start. They are not complete. Before you rely on
  a list, grep for the symbol.
- **Parallel paths** are the largest risk. A parallel path is a second place
  that computes the same value. When you change one, you must also change the
  other. Each section names its parallel paths.
- When a change adds a new shared object, add a section here in the same pull
  request.

Paths are relative to `Sources/APIServer/` unless they start with `Sources/`,
`Public/`, `Tests/` or `docs/`. This map names symbols, not line numbers,
because line numbers go out of date.

---

## Deadlines and visibility

### The class deadline: `APIAssignment.dueAt`

- **Writers:**
  - `AssignmentAuthoringService` (the web edit and MCP `update_assignment`).
  - The new-assignment draft route.
  - Course bundle import.
  - A clone for a new term clears it.
- **Readers:**
  - The per-student resolvers in `Services/AssignmentDeadlineService.swift`.
  - The slip-day arithmetic in `Services/SlipDayStore.swift`.
  - The class-goal freeze in `AchievementEvaluationService`.
  - The wardrobe "early" rule in `WardrobeUnlockStore`.
- **Rules:**
  - Extensions start from the original `dueAt`. The n-th slip day gives
    `dueAt + n × extensionHours` (`docs/slip-days.md`, "The claim window").
  - The class-goal freeze reads the class `dueAt` and ignores extensions. This
    is intentional.
  - The wardrobe "early" rule also reads the class `dueAt` on purpose. If you
    change either rule to use the per-student deadline, that is a change of
    behaviour, not a fix.
- **Trap:** a change to `dueAt` after a student spent a slip day does not
  change the extension row. A later refund calculates the row again from the
  new `dueAt` (`docs/slip-days.md`, "Edge cases").

### The per-student extension: `APIAssignmentExtension.extendedDueAt`

- **Writers:**
  - The staff grant in `StudentCourseRoutes+History.swift`. It sets
    `grantedByUserID`.
  - Slip days: `SlipDayStore.upsertExtension` and
    `recomputeExtensionAfterRefund`. They set `grantedByUserID` to nil.
- **Readers:**
  - `studentExtensionDueAt`.
  - The dashboard batch load, `loadExtensionDueDates`.
  - `SlipDayStore.spend`.
  - The slip-day route, the GitHub submit context and the data export.
- **Rule:** an extension row with no unrefunded slip-day spends is a staff
  extension. In that case, the slip-day offer does not show. `spend` checks
  this again inside its transaction (`docs/slip-days.md`, "Staff extensions
  take precedence").
- **Trap:** staff can edit an extension that slip days made, and nothing
  detects it. A refund then overwrites the staff edit.

### The effective deadline: `laterDeadline` and `effectiveDueAt`

- **Definition:** the later of `dueAt` and the extension
  (`Services/AssignmentDeadlineService.swift`).
- **Readers:**
  - `releaseVisibilityDeadline`, when the release hold is off.
  - `isAssignmentEffectivelyOpenResolved`.
  - `postDeadlineRevealDeadline`.
- **Parallel paths:** the dashboard row (`WebRoutes+IndexRows.swift`) and
  `GitHubSubmitContext` calculate the same maximum by hand. They use extension
  dates from a batch load.
- **Rule:** an extension sets only the deadline. A separate test,
  `studentHasActiveExtension`, decides if an extension is active. The
  submission gate, the dashboard gate and the dashboard filter all use it, so
  that they agree. Use this function. Do not write a fourth copy.

### Open or closed: `visibility`, `startsAt`, `deadlineOverrideActive`

- **Writers:**
  - The deadline sweep: `closeAssignmentIfExpired` and
    `openScheduledAssignment`. The sweep also runs when a student request
    arrives, in `requireOpenStudentAssignment`.
  - `AssignmentAuthoringService.applyOpenState`.
  - An MCP content edit that closes the assignment (`ContentEditClose`).
  - Bundle import. It keeps `deadlineOverrideActive` (#2166).
- **Readers:**
  - `isAssignmentOpenForUser`, through `isAssignmentEffectivelyOpenResolved`.
    Its callers are the submission, notebook, notebook guide and student data
    routes.
  - The dashboard. It calls `submissionGate(isStaff:)` separately.
- **Rules:**
  - An active extension opens submission again after a manual close.
  - An active extension does not override a future `startsAt`.
  - A close before the deadline, with no extension, stays closed.
  - A scheduled open does not occur until validation passes. See the "Lab 6
    incident" comment in `openScheduledAssignment`.
- **Planned input:** `docs/unlockable-labs.md` adds a prerequisite lock to
  this gate. The code does not have it yet. Put it in the shared gate, not in
  one caller.

### Visible to a student by state: `assignmentVisibleToStudentByState`

- **Rule:** the assignment is open. Or it is closed, its `dueAt` is in the
  past, and it has no future `startsAt`. A preview or a draft is never
  visible.
- **Readers:**
  - The dashboard.
  - `studentMayViewClosedAssignment` in `NotebookWorkingCopyStore`. It serves
    the closed-assignment gate and the dataset downloads.
  - `solutionVisibleToStudent`.

### The reveal moment: `postDeadlineRevealDeadline`

- **Value:** the later of two dates: the effective deadline, and the slip-day
  claim-window ceiling (`slipDayClaimWindowCeiling`).
- **Rule:** this is the one resolver for the reveal moment. Release-tier
  output and the solution reveal both use it (`Sources/APIServer/CLAUDE.md`).
- **Parallel paths:**
  - The dashboard's `solutionRevealAvailable` (`WebRoutes+IndexRows.swift`)
    has an inline copy of the full calculation. The copy prevents one query
    for each row.
  - Three places load the slip-day inputs (policy, balance, spends, staff
    extension): `loadSlipDayDashboardData`, the slip-day route, and the
    database form of `slipDayClaimWindowCeiling`.
  - `slipDayOffer` repeats the window arithmetic.
  - A change to the reveal rule must go to all of these.
- **Rule:** a link or a button can hide while its URL still serves the
  content. The opposite must never occur (`docs/solution-visibility.md`,
  "Enforcement chokepoints").

### Release and secret tiers: `releaseVisibilityDeadline`, `SecretRevealState`

- **Policy:** `SlipDayPolicy.releaseRevealHold`, through
  `APICourse.slipDayPolicy`. Also `APIAssignment.secretRevealEnabled`.
- **Readers.** These three gates must agree:
  - The web submission view: `releaseOutputVisible`, then
    `SubmissionResultPresenter`.
  - The JSON results API: `SubmissionQueryRoutes`, through `visibleTiers`.
    Its ETag includes the set of visible tiers.
  - The personal data export: `DataExportContent`.
- **Rules:**
  - The grade includes all tiers, and it does not change at the deadline.
    Only the output is gated.
  - Before the deadline, release rows show by name only.
  - Secret tests show only as totals, unless the student spent a reveal
    token. See the header of `Utilities/TierFilter.swift` and `CLAUDE.md`,
    "Three test tiers".
  - The solution reveal ignores the release-hold opt-out. This is intentional
    (`docs/solution-visibility.md`).

### The solution reveal: `solutionVisibleToStudent`, `requireSolutionVisible`

- **Writers of the policy:**
  - `AssignmentAuthoringService` (web, and MCP `update_assignment`).
  - Bundle import.
- **Readers:**
  - The notebook routes that serve the solution.
  - The notice on the submission page.
  - The dashboard copy (see "The reveal moment").
- **Rule:** the solution shows only when all four conditions are true
  (`docs/solution-visibility.md`, "The reveal gate"):
  1. The policy is `afterDue`.
  2. No deadline override is active.
  3. The assignment is visible to students by its state.
  4. `postDeadlineRevealDeadline` is in the past.
- **Trap:** the three solution routes each had a copy of the guard. One of
  them shipped with no guard. Every route that serves solution content must
  call `requireSolutionVisible`.

### Failure detail: `TestSuiteEntry.failureDetail`

- **Writers:** the suite, family and notebook-check editors, and their MCP
  tools. A family or a check writes its resolved level onto each entry that
  it generates (`docs/failure-detail.md`, "Where it is set").
- **Readers:**
  - `buildFailureDetailByFilename` and `renderOutcomeRow` in
    `SubmissionResultPresenter`. The mask applies after release redaction,
    and only for a viewer who is not staff.
  - `NotebookGuideBuilder`.
- **Rule:** the mask is a display policy. It is not a secret
  (`docs/failure-detail.md`, "Where it is applied").
- **Known gap:** the JSON results API and the data export return the full
  text. See "Gaps found while mapping".

### Grade push: `requestGradePush`

- **Callers:**
  - `ResultIngestEffects`.
  - `GradeOverrideHelpers`.
  - The class-goal freeze in `AchievementEvaluationService`.
- **Rules:**
  - A new trigger calls `requestGradePush` one time. The function sends to
    BrightSpace and to LTI AGS.
  - `course.usesLTIGrades` makes the two integrations exclusive.
  - `GradePushCoverageTests` keeps the calls for each integration inside
    `GradePushRequest.swift`.
- **Trap:** the browser result path once did not set the BrightSpace flag. As
  a result, notebook labs did not reach LEARN (`GradePushRequest.swift`
  header).
- **Edge case:** an assignment with no due date never freezes its class goal.
  Its bonus reaches LEARN only through "Push all"
  (`docs/brightspace-setup.md`, "What triggers a push").

---

## The grading pipeline

### A manifest suite row: `TestSuiteEntry`

- **Writers:**
  - The `applySuiteEdit` chokepoint (`Services/SuiteEditing.swift`). All web
    and MCP suite edits go through it.
  - `applyPatternFamilies`. The new-assignment route and
    `GlobalInputsService` also call it directly.
  - `SuiteEntryBuilder`.
  - `makeWorkerManifestJSON(preserving:)`.
  - A version restore.
- **Readers:**
  - The native suite mapping
    (`Sources/Worker/RunnerDaemon+SuiteExecution.swift`).
  - The browser suite mapping (`Public/browser-runner.js`).
  - `languagesRequiredToGrade`.
  - `suiteTimeBudget` in the stuck-submission reaper.
- **Rules:**
  - The encoder writes only values that are not the default. It writes
    `points` when the value is not 1. A missing key decodes to 1, so a
    0-point gate would start to count toward the score
    (`Sources/Core/TestProperties.swift`).
  - An entry sets `generatedBy` or `generatedByCheck`, never both.
  - A raw script edit refuses a generated entry.
  - A manifest rewrite copies the decoded manifest. A new dictionary loses
    fields (`Sources/APIServer/CLAUDE.md`; `docs/language-declaration.md`,
    "An adjacent defect").
- **Parallel paths:**
  - The map from an entry to a `SuiteItem` is in Swift and in JS.
  - The default time limit, 10 seconds, is written in five places:
    `Public/browser-runner.js`, `GetSuiteTool`, `InstructorDashboardRoutes`,
    the default parameter of `makeWorkerManifestJSON`, and a JSON literal in
    `AssignmentAuthoringService`.

### Time limits: `timeLimitSeconds`

- **Rule:** use the entry value. If it is not set, use the manifest value.
- **Readers.** Each of these applies the rule itself:
  - The native worker.
  - The browser runner.
  - The stuck-submission reaper.
- RunnerCore `executeSuites` does not apply the rule. A change to the rule
  must go to all three readers.
- **Family rule:** `PatternCase.resolvedTimeLimit` uses the case value, then
  the family default, then nil.

### Dependencies, points and score

- **Rules:**
  - A `family:<id>` token in `dependsOn` expands to the family's generated
    filenames before the manifest is saved. The saved manifest never contains
    the token (`PatternFamilyApplication`).
  - When the RunnerCore dependency gate skips a test, the test gets score 0.
    It keeps its points, and it counts in `totalPoints`.
  - `score` is credit, clamped to 0...1. `metric` is not clamped, and it is
    never credit (`CLAUDE.md`, "Test Script Contract").
  - `Tests/Fixtures/output-contract.json` pins how output is interpreted, for
    the native build and for the vendored wasm. After a RunnerCore change,
    vendor the wasm again. If you do not, the browser grader runs the old
    code.
- **Trap:** the old manifest's dependencies were once carried forward. This
  made family dependencies "sticky", with references to deleted files that no
  edit could remove.

### The declared language and `languagesRequiredToGrade`

- **Writers:**
  - Only `applyLanguageDeclaration`, through `changeDeclaredLanguage`. Its
    callers are the save-edit route and MCP `set_assignment_language`.
  - `derivedDeclaration` runs only at two boundaries: test setup upload and
    bundle import.
- **Readers of the union:** `RunnerLanguageGate.evaluate`, through
  `claimCompatibility`. The claim walk and `UnclaimableJobsRule` share it, so
  the alert and the claim agree.
- **Rules:**
  - Nothing infers a language.
  - No `language:` parameter has a default (`docs/language-declaration.md`).
  - The runner advertises `AssignmentLanguage.capabilityName`, and the gate
    compares the same name. Both sides must use it.
- **Parallel paths.** Four places map a file extension to a language:
  - `LanguageDescriptor.scriptExtensions`, through
    `languageByScriptExtension`.
  - RunnerCore `classifyScriptInterpreter`.
  - The generated `INTERPRETER_KINDS` table in `Public/browser-runner.js`.
  - The zip scan in `AssignmentRequirementHelpers`, which uses the first one.
  - A new language or extension must go to all of them
    (`docs/adding-a-xeus-kernel.md`).
- **Edge case:** a version restore can change the language without
  `changeDeclaredLanguage`. The restore writes the snapshot manifest as it was
  stored.

### Grading and submission mode: `effectiveGradingMode`, `effectiveSubmissionMode`

- **Rule:** every consumer reads the effective value, not the raw field. Only
  coherence and authoring code read the raw field.
- **Fact:** the claim walk also takes pending submissions in browser mode. So
  the native worker grades a retest or a failover of a browser-graded
  submission. For this reason, the two graders must agree, and the language
  gate also covers browser assignments.

### What a runner receives: `RunnerManifest` and the cache key

- **Rules:**
  - `RunnerManifest` removes these fields: families, checks, `=` expressions,
    datasets, grader-only files, the activity, `minimumRunnerVersion` and the
    anchor. A new `TestProperties` field reaches a runner only when you add
    it to `RunnerManifest`.
  - The test setup cache key (`testSetupCacheKey`) is the setup ID, plus a
    hash of the download URL and the stable-encoded runner manifest. The URL
    carries the download version. Thus any suite edit makes a new cache entry
    (`Sources/Worker/CLAUDE.md`).
  - Use `ManifestCodec.stableEncoder`, not `.encoder` (#1526).
  - No student identity goes into the key or into the cached directory.
    Per-student bytes go only into the scratch copy for each job
    (`docs/datasets.md`, "Runner cache is preserved").

### The per-student seed, inputs and datasets

- **Seeds:**
  - `AssignmentSeedStore.ensureSeed`. Do not call it inside a transaction.
  - `CourseSeedStore`.
  - `DatasetSeedDerivation.effectiveSeed`.
- **Parallel paths.** These must give the same values:
  - The worker job payload (`WorkerJobRoutes.buildJobPayload`).
  - The browser seed endpoint (`BrowserRunnerRoutes.getAssignmentSeed`).
  - Both use `gradingInputs`, `CompositeSlots` and `DatasetResolver.resolve`.
- **Parallel paths.** The student's download must give the same bytes as
  grading:
  - `StudentDatasetDelivery`.
  - `NotebookWorkingCopyStore`.
  - `PersonalizationSubstitution`.
- **Rules:**
  - An expression reads the student's slice, not the pool.
  - The server resolves the bytes one time. Nothing samples them again
    (`docs/datasets.md`).
  - `variesPerStudent` is not a wider `hasPersonalization`. Each predicate
    has its own readers. Do not use one in place of the other.

### Dataset transform kinds: `DatasetTransform.Kind`

- **Objects:** the kind of each step in a spec's `transforms`, and the bytes
  `DatasetMaterializer` writes for it.
- **Readers that branch on the kind:**
  - The Files panel edits one `missingValues` step only, in two copies that
    must agree: `datasetTransformsEditable` (`SuiteRowContexts.swift`) and
    `ownsTransforms` (`Public/support-files.js`). Any other spec renders
    disabled and its steps are carried through.
  - The divergence diagnostic folds the columns a `formatNoise` step names
    (`DatasetDivergence.swift`).
  - The MCP `set_dataset` description glosses each kind
    (`DatasetTransformProse.gloss`, an exhaustive switch).
  - The row-set test holds every kind to "a transform never changes which
    rows a student holds" (`DatasetDiagnosticsTests`, an exhaustive switch).
- **Rules:**
  - A new kind updates every reader above, or says why it does not.
  - A kind never changes a delivered byte of an existing kind: each step draws
    from its own stream, keyed on the step's index, kind and column.

### The course dataset library

- **Objects:**
  - `APICourseDataset.isPublished`.
  - A manifest dataset whose `source` names a library slug.
  - The student Data page (`StudentDataRoutes.swift`, `GET /data/:courseKey`)
    and its download of the student's own rows.
- **Rules:**
  - The student download goes through `StudentDatasetDelivery`. It calls
    `DatasetResolver.resolve` with the same inputs as the worker payload, the
    browser seed and the working copy. A new reader must use the same
    resolver.
  - Publishing a dataset controls only the Data page and the links to it. A
    download for an assignment follows the gate of that assignment
    (`isAssignmentEffectivelyOpen` or `studentMayViewClosedAssignment`).

### The result: `TestOutcomeCollection` counts and the grade

- **Parallel paths.** Three places calculate the counts:
  - The native worker (`Sources/Worker/CollectionAssembly.swift`).
  - The browser runner (`buildCollection`). It calculates counts only.
  - The server (`reconcileBrowserCollection`). It calculates the points
    again, but keeps the counts from the browser.
- **Parallel paths.** Two formulas calculate the grade percent:
  - `gradePercent(from:)` in `Utilities/TierFilter.swift`.
  - `CollectionGradeFields` in `Utilities/CollectionGradeFields.swift`.
- **Rules:**
  - `ResultIngestEffects` is the one ingest chokepoint. The worker path, the
    browser path and the tournament arena all use it. Put a new side effect
    of a result there, not in one path (#1708).
  - A browser result is authoritative, and a student can forge it
    (`docs/grading-integrity.md`). A feature that trusts a value in a result
    has the same risk.

### Content versions and restore

- **Rules:**
  - A restore changes content only (`docs/assignment-versioning.md`).
  - After a restore, the assignment is closed, and every submission is graded
    again.
  - A restore changes the cache key. It does not change seeds.
  - The content is three artifacts: the manifest, the zip and the starter
    notebook. A new content artifact needs a decision for capture and for
    restore.

### Grading again and validation

- **Rules:**
  - `retestSubmissionsIfManifestChanged` compares the manifest hash with the
    hash of the last retest. A content edit reaches it through
    `finalizeContentEdit` and `ContentEditEffects`.
  - Runners claim fresh work before retests (#427).
  - Every lookup for "the newest validation row is the solution" filters on
    `.validation`. A `.starterValidation` run never sets `validationStatus`
    (`Sources/APIServer/CLAUDE.md`).
- **Trap:** the web support-file delete did not validate or retest (#2472).

### The ranking metric and class activities

- **Readers:**
  - `LeaderboardEntries`, from `ResultIngestEffects`.
  - `ActivityMatches` and `Tournaments`.
  - `Sources/Worker/MatrixAggregation.swift`.
  - The leaderboard routes.
- **Rules** (`docs/class-activities.md`):
  - A higher metric is better.
  - The metric is never credit, and it is not gated on the grade.
  - Only `.student` rows in the setup's own course get a rank.
  - Connect a new accumulator at both ingest paths. An accumulator on one
    path shows only the half of the class that one substrate grades, as if it
    were the whole class.
  - For an activity that runs per lab group, a leaderboard result goes to
    `group_leaderboard_entries` under the group of the session the student
    submitted in, and a submission with no open joined session does not
    rank (docs/lab-groups.md, slice 3a). A new ranking writer must read
    `ActivitySessionStore.sessionAtSubmission` the same way, or
    `ActivityKind.canRunPerGroup` must stay false for its kind. Every
    reader of the per-group behaviour reads `ClassActivity.isPerGroup`, never
    the raw `runsPerGroup` flag. The `highestMetric` class record stays
    course-wide on purpose: a per-group result can take it from a student in
    another lab.

### Lab groups and per-group sessions: `runsPerGroup`, `activity_sessions`

- **Writers:**
  - `CourseGroupStore`: the Groups tab, the roster import and the Students
    tab's Group column write memberships. `removeGroup` also ends the
    group's open sessions.
  - `ActivitySessionStore.open` and `close`, from the present page's Start
    and End (`WebRoutes+Sessions.swift`).
  - `ActivitySessionStore.join` (`/join`) writes attendance, and places a
    student in no group of a manual set in the session's group. A wrong code
    writes a `login_attempts` row (scope `join_failure`).
  - `ActivitySessionStore.remove`, from the staff attendance page, sets
    `removed_at` on an attendance row.
  - `ActivityAuthoring.setActivity` sets `ClassActivity.runsPerGroup`.
- **Readers:**
  - `requireOpenActivityWindow` in `Routes/StudentAssignmentRequestGates.swift`,
    through `ActivitySessionStore.currentSession`.
  - `GroupSessionPanel` on the present page, and `SessionAttendancePage`.
  - The data export (`gatherGroups`, `gatherSessionJoins`).
- **Rules** (`docs/lab-groups.md`):
  - A per-group activity has no session window: each group's session is its
    clock. `ActivityAuthoring` refuses both together, and refuses a class
    composite.
  - Only attendance counts: membership does not let a student submit. A
    join from before a session's latest start, or a removed one, does not
    count. But membership limits the join: a member joins only their own
    group's session. The gate lets in any student who has ever joined one of
    the activity's sessions; ranking still needs an open joined session at
    the submission's time.
  - The join code is derived from the session's secret and the time; it is
    never stored. A reopen draws a new secret.
  - Remove undoes a group placement that the student's join made
    (`placed_in_group`), and only while that is still their group.
  - The network columns (`presenter_network`, `join_network`) hold the
    network part of an address (`ClientNetwork.prefix`), never the address.
    The "Other network" mark is a flag for staff; no gate reads it.
  - Sessions read the course's first group set only.
  - Staff are never gated, as with the window.
  - Every write that turns `runsPerGroup` off ends the open sessions:
    `ActivityAuthoring.setActivity` and the MCP version restore. A new writer
    of the flag must do the same, or turning it on again brings back an
    earlier lab's code.
  - A clone and a bundle import clear the flag (see Cloning).
- **Gap:** `POST /api/v1/submissions` checks enrollment only, so it skips
  this gate, as it skips the window.

### The client address: `clientIPAddress` and `Request.clientNetwork`

- **Readers:** the login rate limit (`ip` key), the MCP OAuth rate limit,
  the audit log's `remote_addr` (`auditRemoteAddress`), and the lab-group
  session networks (`Request.clientNetwork`).
- **Rules:**
  - `X-Forwarded-For` is read only when `trustForwardedProto` is set.
  - `clientIPAddress` takes the FIRST entry, which the client can choose:
    the deployment's nginx appends the real peer
    (`$proxy_add_x_forwarded_for`) after what the client sent.
  - `Request.clientNetwork` takes the LAST entry, the one nginx appended,
    because a session network is evidence that staff read.
  - A change to either reading changes every reader of it. A front proxy
    other than the repository's nginx can change which entry is real.

### Rate-limit rows: `login_attempts`

- **Writers:** the login rate limit (`LoginRateLimitMiddleware`: scopes `ip`
  and `user_failure`) and `/join` (`ActivitySessionStore`: scope
  `join_failure`, keyed by user id).
- **Readers:** each writer reads its own scope only.
- **Rules:**
  - Every reader filters by `scope`. A new scope is a new string constant in
    `LoginAttempt.Scope`, never a reuse of another feature's.
  - `purgeStale` removes rows of every scope by age (an hour or the lockout
    window, whichever is longer). A window longer than that needs a change
    to the sweep.
  - No row has a foreign key, so a deleted user's rows stay until the sweep
    (`docs/operational-diagnostics.md`).

### Notebook-check kind support

- **Parallel paths:** `notebookCheckKindIsSupported` and
  `validateKindSupport` (`Utilities/NotebookCheckValidator.swift`). Both
  record which kinds each language supports. A change must go to both.

---

## Identity, access and student data

### The per-course role: `CourseRole`

- **Writers:**
  - `saveSeededEnrollment` and `ensureSeededEnrollment`, for every new
    enrollment: login, enrollment, CSV, staff provisioning, bundle import, a
    new term, the MCP account, auto-enrollment in `.auto` courses, and LTI
    launch.
  - The role-change routes.
- **Readers.** All of them go through `courseRole(of:inCourse:db:)`:
  - `requireCourseRole` and `requireCourseEnrollment`.
  - `isCourseStaff` and `isStaffAnywhere`.
  - `evaluateCourseWrite`.
  - The cached versions for each request, such as `cachedCourseRole`.
  - The MCP `ToolContext` checks.
  - `ActiveCourseStaffMiddleware`.
  - `AvatarStore.courseStaff`.
- **Rules:**
  - Every call site states its minimum role. Nothing has a default.
  - A TA authors content and grades. An instructor manages the course.
  - An admin bypasses the role check. But an admin's MCP agent can reach only
    the courses that the MCP account is enrolled in (#1942;
    `docs/multi-course-roles.md`).
  - The server reads the role again on every request. A role change or an
    unenrollment applies on the next request.
- **Trap:** some handlers had comments that said "instructor", but they had
  only the area gate (#1448). `RouteAuthorizationMatrixTests` now finds a
  route under `/instructor` or `/courses` that has no minimum role.
- **Rule:** every caller of `isStaffAnywhere` states `includingArchived`
  (#2663).
  - `false` where a `true` answer opens data that no per-course check guards:
    the user-file namespace and the JupyterLite contents. A TA in a past term
    is a student there, as in `AvatarStore.courseStaff` (#1756).
  - `true` where a per-course check follows: MCP eligibility and the OAuth
    content consent. An instructor whose only course is archived can still
    read it through MCP (`MCPArchivedWriteBlockTests`).

### The deployment role: `UserRole`

- **Rules:**
  - The values are `user`, `admin` and `mcp`. There is no global instructor
    (#417).
  - An LTI launch never gives admin. It never changes an existing enrollment
    (`docs/lti-1-3.md`).

### Course identity: code, term and `urlKey`

- **Resolvers:**
  - The web: `findActiveCourse(byKey:viewer:on:)`.
  - MCP: `resolveMCPCourse`.
  - Uniqueness: `activeCourseCodeIsTaken` and `courseKeysCollide`. Create,
    edit, import and un-archive call them.
- **Rules** (`docs/course-terms.md`):
  - Do not add a lookup by code only.
  - On the web, the viewer's own course wins. Then the newest term wins.
  - MCP refuses a write through a code that names more than one course.
  - Every MCP result names `courseKey` and `courseTerm`.
- **Traps:** key collisions (#2227). Un-archive and the unique index (#1777).

### Cloning: `CourseCloneService.clone` and `cloneAssignment`

- **Rules:**
  - The course clone and MCP `clone_assignment` share
    `AssignmentAuthoringService.cloneAssignment`.
  - A clone starts closed, with no dates and with the reveal off. The course
    clone sets enrollment to closed.
  - A clone does not copy enrollments, LMS, BrightSpace or GitHub bindings,
    submissions or history (`docs/course-terms.md`).
  - A new field on an assignment or a course needs a decision: copy it or
    reset it. Make the decision in both clone functions.
  - A bundle export and import is a full restore (#1737, #2166). A new field
    needs a decision there too.
- **Traps:**
  - `.auto` enrollment let students from the last term in (#1780).
  - An old activity window refused students (#2189).
  - A per-group activity in a course with no groups refuses every student.
    A clone and a bundle import clear `runsPerGroup`, because neither copies
    group sets.
  - The two clones once copied different policies (#1738).
  - A rollback left orphan files (#1743, #2168).

### The AI-feedback gates: `aiFeedbackEnabled`

- **Writers:**
  - The admin course toggle.
  - The instructor assignment toggle. It refuses when the course gate is off.
- **Readers:**
  - `ReflectionFeedbackService.gatesOpen`.
  - `MCPStudentDataBoundary.gatedFeedbackSetup`.
  - Several instructor and student routes.
  - The RLS policies in `deploy/sql/mcp-least-privilege-role.sql`.
- **Rules:**
  - No MCP tool sets either gate (`MCPAIFeedbackGateTests`).
  - The feedback handle is for one student and one assignment. It is not the
    avatar handle (`docs/ai-assisted-feedback.md`).
  - A clone does not copy either gate. Keep it so, unless someone decides
    otherwise.

### The MCP student-data wall: `MCPStudentDataBoundary`

- **Rules:**
  - An MCP tool reaches student submissions only through the boundary. The
    boundary allows validation runs and the gated feedback accessors
    (`Sources/APIServer/MCP/CLAUDE.md`).
  - When you enroll the MCP account in a course, its reach becomes wider.
    When you unenroll it, the reach stops on the next call.
  - A new table that the boundary reads needs its grant and its RLS policy
    (`MCPLeastPrivilegeGrantSyncTests`; #1176).
  - The admin diagnostics MCP returns allowlisted records that the code
    builds by hand. The test for each tool asserts that a seeded student does
    not appear (`docs/admin-mcp.md`). Nothing checks that a new admin tool has
    that test.

### The avatar handle: `users.avatar_handle`

- **Writers:** `AvatarStore.ensureHandle` and `redrawHandle`.
- **Readers:**
  - The leaderboard.
  - The composite board and its snapshot.
  - The account page and the staff student lists.
  - The data export.
- **Rules** (`docs/student-avatars.md`):
  - Only students get a handle.
  - Only course staff (TA and up) can find the student for a handle.
  - A handle never comes from identity data.

### Student data that classmates see

- **Features:** the leaderboard, the class composite, collaborative
  assignments, class goals.
- **Rules** (`docs/class-activities.md`; `docs/class-composite.md`):
  - Classmates see a handle and a bird, never a name.
  - Hidden is the default.
  - Names show only to staff, and never in present mode.
- **No guard:** no generic check finds a new page that shows student data to
  classmates. `RouteAuthorizationMatrixTests` does not cover routes outside
  `/instructor` and `/courses`. So:
  - Use `isCourseStaff` and the `AvatarStore` handles.
  - Add a test that asserts that a classmate's username is not on the page,
    as `LeaderboardPageTests` does.
- **Trap:** a new aggregation set the metric board flag by accident (#1745).

### What reaches GitHub

- **Rule:** nothing sends a grade, a name, an email or a student number. The
  student's login reaches the organization only in the repository name
  (`docs/github-submissions.md`, "What reaches GitHub").

### Course archival: `isArchived`

- **Readers:**
  - `evaluateCourseWrite`. It blocks writes.
  - The course tab strip and `list_courses`.
  - `AvatarStore.courseStaff`.
  - The auto-enroll set.
- **Rule:** an archived course is read-only. It stays readable, through MCP
  too (`MCPArchivedWriteBlockTests`).

### Browser isolation and the CSP

- **Rules:**
  - Every worker that the notebook page starts is in
    `NotebookAssetIsolationMiddleware.isolatedWorkerScripts`. The list comes
    from `AssignmentLanguage.allCases` (`IsolatedWorkerScriptDriftTests`;
    #1274). A new language adds a worker.
  - The CSP permits no inline script (#1516;
    `ContentSecurityPolicyInlineScriptTests`).

---

## Checks that already guard an intersection

These tests fail when a change breaks an intersection. The review agent does
not repeat them. But a change that makes one of them weaker is a finding.

| Intersection | Test |
|---|---|
| A web route under `/instructor` or `/courses` with no minimum role | `RouteAuthorizationMatrixTests` |
| A new MCP tool with no course authorization | `MCPAuthorizationCoverageTests` |
| An MCP tool that reads student data outside the boundary | `MCPStudentDataWallTests` |
| An MCP write to an AI-feedback gate | `MCPAIFeedbackGateTests` |
| A missing grant or RLS policy for the MCP role | `MCPLeastPrivilegeGrantSyncTests` |
| An MCP write to an archived course | `MCPArchivedWriteBlockTests` |
| A grade push outside `requestGradePush` | `GradePushCoverageTests` |
| The native and browser graders interpret output differently | `OutputContractTests`, `output-contract.test.mjs` |
| A new user column with no foreign key | `UserReferenceScanTests` |
| Rows that course deletion does not remove | `DeleteCourseCoverageTests` |
| A notebook worker that is not in the isolation list | `IsolatedWorkerScriptDriftTests` |

---

## Gaps found while mapping

The research for this map found these differences between the code and the
rules above. They are listed here so that the review agent does not report
them on every pull request. Each one has an issue that holds its decision.
When an issue is closed, remove its item and correct the section above.

1. **Failure detail outside the web page (#2662).** The JSON results API
   (`GET /api/v1/submissions/:id/results`) and the data export return the
   full failure text, also for an entry set to `actualOnly` or
   `verdictOnly`. `docs/failure-detail.md` calls the setting a display
   policy, not a secret. But it does not say that these two paths are out of
   scope.
2. **The dashboard copy of the reveal rule (#2665).** `solutionRevealAvailable` in
   `WebRoutes+IndexRows.swift` is a full inline copy of
   `solutionVisibleToStudent` and `postDeadlineRevealDeadline`. It is
   correct now. It is the most likely place for the next drift.
3. **Fixed routes and vanity URLs (#2666).** The vanity routes
   (`VanityURLRoutes.swift`, `/:courseCode/:assignmentSlug`) are registered
   last, so a fixed route with two segments wins. `/data/:courseKey` and
   `/submissions/:submissionID` have that shape. `StudentDataRoutes.swift`
   chose its path so that an assignment slug `data` still works. But a course
   with the code `data` or `submissions` loses its vanity URLs. No list of
   reserved course codes exists.
