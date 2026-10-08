# Abstraction survey — October 2026

This report answers #2259. It finds places where two or more code paths do the
same job and have not yet drifted, or have drifted only a little. For each
place, it says whether a shared abstraction added now prevents a future bug.

This report changes no code. The maintainer selects the candidates to do. Each
change that follows must obey `CLAUDE.md`: no new environment variables, no
`@unchecked Sendable`, and test coverage for each change.

## Status and method

Read this section first. It says what was measured and what was not.

| Area from #2259 | Done | How |
|---|---|---|
| Web vs. MCP write paths | yes | read both seams and every web write handler; compared post-edit steps per handler |
| Native vs. browser grading | yes | compared the two result routes, the per-language browser grading files and the retry paths |
| Per-language code | yes | read all 32 `switch` sites over a language in `Sources/` |
| External integrations | yes | compared token caches, 401 handling and grade-sync triggers for BrightSpace, LTI and GitHub |
| Background services and reapers | yes | checked each service for `PeriodicSweepMonitor` and compared the sweep bodies |
| Leaf view-model builders | yes | compared the dashboard row builder with `AssignmentDeadlineService` |

All references are to `main` at v0.5.583. Each line reference was read in that
tree. No test was run. Where a finding is a possible bug, the first step of its
PR is a failing test that proves it.

## Summary

| # | Candidate | Drift now | Recommendation |
|---|---|---|---|
| 1 | Post-edit effects: web vs. MCP | yes — one web path skips revalidation | do now |
| 2 | LMS grade-push fan-out | no — three sites, each calls both LMSes | do now |
| 3 | Solution-reveal rule: dashboard vs. serving route | no — a hand copy | do now |
| 4 | Version capture scope: web vs. MCP | small | do now |
| 5 | Result-row write: worker vs. browser | yes, fixed once | do now |
| 6 | Open-for-user inputs: dashboard vs. service | no — a hand copy | do now, with #3 |
| 7 | Notebook-check kind support: two encodings | small | do now |
| 8 | Lua function-target rule | yes — a latent bug | fix now; no abstraction |
| 9 | Token caches: GitHub and LTI | no | wait |
| 10 | Browser result-post retry | not drift | no action |
| — | Reapers, per-language switches, R run-output parser | — | no action |

Items 1, 2 and 3 have the highest value. A miss in each is silent: a broken
suite stays open to students, a grade in LEARN stays wrong, or a solution is
shown before a student can still buy time.

## 1. Post-edit effects: web vs. MCP

**Duplicated paths.**

- MCP has one chokepoint: `finalizeContentEdit`
  (`Sources/APIServer/MCP/Tools/ContentEditClose.swift:100`). It closes an open
  assignment, retests submissions when the edit can change a grade, and
  schedules revalidation. `MCPContentEditCoverageTests` pins the classification
  of every MCP write tool.
- The web side has no server-side equivalent. `putSuite`
  (`Sources/APIServer/Routes/Web/PublishedAssignmentRoutes+Suite.swift:43`) does
  the retest and the revalidation inline. `createScript` and `deleteScript`
  (`PublishedAssignmentRoutes+ScriptCRUD.swift:97`, `:148`) do neither.
- The browser closes part of the gap. After a delete, the suite table calls
  `schedulePush` (`Public/suite-table.js:799`), which sends `PUT /suite`, which
  retests and revalidates. Thus the browser, not the server, owns the step.

**Evidence of drift.**

- The support-file delete in `Public/support-files.js:430` sends
  `DELETE /instructor/:id/scripts/:filename` and then only refreshes the page
  (`Public/assignment-edit-page.js:207`). It sends no `PUT /suite`. Thus a web
  support-file delete does not revalidate or retest. The MCP
  `delete_support_file` tool does both
  (`DeleteSupportFileTool.swift:159`, `retest: true`). A test that imports a
  deleted helper file now fails for every student, and the assignment stays
  open with a stale `validationStatus`.
- This step drifted before. The comment at
  `PublishedAssignmentRoutes+Suite.swift:58` records that the v0.4.93
  auto-retest was lost when suite editing moved off the Save button. #1115 is a
  second example.

**Proposed abstraction.** One `ContentEditEffects` service, shaped like
`ResultIngestEffects`. It takes the assignment, the setup, the acting user and
an edit kind:

- `.gradeAffecting` — retest and revalidate.
- `.placementOnly` — revalidate only (today's `retest: false`).
- `.environmentOnly` — nothing (time limit, datasets, achievements).

Closing stays a parameter, because the web live editor does not close and MCP
does. That difference is a stated decision
(`ContentEditClose.swift`, header). The parameter makes it visible at each call
site. `finalizeContentEdit` becomes a thin MCP wrapper. The web script handlers
call the service, so the browser no longer has to remember a follow-up request.

This is the smallest change that removes the duplication. A protocol is not
necessary: there is one implementation and two callers.

**Recommendation: do now.** First, write a failing test for the support-file
delete. Then move the steps to the server. Then extend the coverage test to the
web write handlers that use `loadAssignmentAndSetupForWrite`.

## 2. LMS grade-push fan-out

**Duplicated paths.** Each place that changes a grade must request a push to
both LMS integrations. It does this with two separate calls:

| Trigger | LTI call | BrightSpace call |
|---|---|---|
| New result | `ResultIngestEffects.flagForGradeSync` → `LTIGradeSyncQueue.queue` (`ResultIngestEffects.swift:35`) | `flagResultForBrightSpaceSync` (`ResultIngestEffects.swift:33`) |
| Grade override set or cleared | `LTIGradeSyncQueue.queue(userIDs:)` (`GradeOverrideHelpers.swift:193`) | `brightspaceSyncPending = true` on results or on the override row (same function, `:186`) |
| Class-goal bonus freezes | `LTIGradeSyncQueue.queueAllStudents` (`AchievementEvaluationService.swift:212`) | `requeueFrozenClassGoalBonusPushes` (`:213`) |

**Evidence of drift.** Today all three triggers call both. But this fan-out has
failed before. The browser result path did not set the BrightSpace flag, so
notebook labs never pushed to LEARN automatically
(`BrowserResultRoutes.swift:139`). The comment at
`AchievementEvaluationService.swift` before line 212 also says that a push
starts only from a result, an override or a manual "Push all". A fourth trigger
(for example, a slip-day change that alters a late grade) would have to find
and copy two calls.

**Proposed abstraction.** One function, for example
`requestGradePush(_ scope: GradePushScope, testSetupID:, on:)`, with
`GradePushScope` as `.result(APIResult)`, `.students([UUID], override:)` or
`.allStudents`. It calls the two existing backends. A protocol over the two
LMSes is not necessary: each backend keeps its own queue, sweep and data.

**Recommendation: do now.** The change is small. A miss is silent and puts a
wrong grade in the institution's system of record.

## 3. Solution-reveal rule: dashboard vs. serving route

**Duplicated paths.**

- `solutionVisibleToStudent`
  (`Sources/APIServer/Services/AssignmentDeadlineService.swift:333`) with
  `postDeadlineRevealDeadline` (`:258`) is the gate that serves the solution.
- `solutionRevealAvailable`
  (`Sources/APIServer/Routes/Web/WebRoutes+IndexRows.swift:507`) decides if the
  dashboard shows "View solution". Its comment says it applies "the same rule
  the serving routes enforce". It is a hand copy of the five guards, rebuilt
  from preloaded row data so that the dashboard runs no per-row queries.

**Evidence of drift.** None found. The two agree today, including the
archived-course case (`WebRoutes+IndexLoading.swift:57` disables the
dashboard's slip-day policy). The risk is the next guard. A guard added to
`solutionVisibleToStudent` only makes the dashboard offer a link that returns
403, or hide a link that works. `CLAUDE.md` names `postDeadlineRevealDeadline`
as "the one resolver" for this moment, but the dashboard does not call it.

**Proposed abstraction.** Split each function into a pure core and a
database-resolving shell. The pure core takes the assignment, the extension
date, the slip-day claim ceiling and `now`. `solutionVisibleToStudent` loads
those inputs and calls the core. The dashboard passes its preloaded inputs to
the same core. `slipDayClaimWindowCeiling` already has this shape
(`SlipDayStore.swift:425` and `:453`), so this follows an existing pattern.

**Recommendation: do now.** Add a parameterized test that runs both callers on
the same cases.

## 4. Version capture scope: web vs. MCP

**Duplicated paths.**

- `AssignmentVersionCaptureScope`, `beginAssignmentContentEdit` and the
  middleware's `capture`
  (`Sources/APIServer/Middleware/AssignmentVersionCaptureMiddleware.swift:29`,
  `:71`, `:105`).
- `MCPVersionCaptureScope`, `beginContentWrite` and `finishContentWrites`
  (`Sources/APIServer/MCP/Tools/MCPVersionCapture.swift:35`, `:67`, `:86`).

The register, drain, baseline and re-read-then-record code is the same in both.
Only the origin label and the database differ.

**Evidence of drift.** Small. Only the web scope has `isEmpty` (`:46`). Only the
web path drains the scope when the request fails (`:98`). The MCP path does not
need that drain today, because each JSON-RPC request gets a new `ToolContext`.
If a context ever spans a batch, a failed call's setup is snapshotted by the
next successful call.

**Proposed abstraction.** One scope type and one
`recordRegistered(origin:actor:testSetupsDirectory:logger:on:)` function. Each
side keeps its own seam and passes its origin and database.

**Recommendation: do now.** The change is small and the existing coverage tests
continue to apply.

## 5. Result-row write: worker vs. browser

**Duplicated paths.** Both result routes encode the collection to JSON, build
an `APIResult`, call `ResultIngestEffects.flagForGradeSync` and call
`saveWithCollection`:

- `ResultRoutes.persistToDB` (`Sources/APIServer/Routes/ResultRoutes.swift:131`).
- `submitBrowserResult` (`Sources/APIServer/Routes/BrowserResultRoutes.swift:134`).

The course-bundle import (`CourseBundleRoutes+Import.swift:805`) also writes a
result row. It does not flag for grade sync, which is correct for imported
history.

**Evidence of drift.** This code drifted once. The browser copy did not set the
grade-sync flag (`BrowserResultRoutes.swift:139`). The copies still differ in
transaction shape: the worker path writes the result and the status change in
one transaction (`ResultRoutes.swift:68`); the browser path uses
`withTransientDatabaseLockRetry` (`BrowserResultRoutes.swift:150`). That
difference has a reason (the browser path creates the submission row), so the
shared function must not decide it.

**Proposed abstraction.** One `ResultIngestEffects.storeResult(_:source:testSetupID:on:)`
that encodes, flags and saves on the database it receives. Each route keeps its
own transaction or retry around the call.

**Recommendation: do now.**

## 6. Open-for-user inputs: dashboard vs. service

**Duplicated paths.** Both callers use the shared pure core
`isAssignmentOpenForUser`. But each builds its six inputs by hand:

- `isAssignmentEffectivelyOpenResolved`
  (`AssignmentDeadlineService.swift:225`) — the submit gate.
- The dashboard row (`WebRoutes+IndexRows.swift:368` to `:386`) — the Submit
  button.

**Evidence of drift.** None. The two input lists match today. If a new input is
added to the service only, the dashboard shows a Submit button that the server
refuses.

**Proposed abstraction.** One pure function that takes the assignment, the
staff bit, the extension date and `now`, and returns the decision. Both callers
use it. This is the same split as candidate 3.

**Recommendation: do now, in the same PR as candidate 3.**

## 7. Notebook-check kind support: two encodings

**Duplicated paths.** In `Sources/APIServer/Utilities/NotebookCheckValidator.swift`:

- `notebookCheckKindIsSupported` (`:103`) is the support table that the Add Test
  menu and `get_server_info` read.
- `validateKindSupport` (`:168`) encodes the same table again for R, Lua and
  Octave, with the language name and the hand-written extension typed as
  literals (`"R"`, `".R"`, `".lua"`, `".m"`).

The C++, Racket and Java arm already uses the shared predicate,
`notebookCheckKindUnsupportedReason` and `handWrittenTestExtension` (`:247`).
Its comment explains why: three copies of one sentence.

**Evidence of drift.** Small. The save-time refusal and the discoverable answer
are built in two ways. The language names duplicate `displayName`.

**Proposed abstraction.** No new type. The R, Lua and Octave arms call
`notebookCheckKindIsSupported`, `language.displayName` and
`handWrittenTestExtension(language)`. The Lua regex refusal stays.

**Recommendation: do now.** The refusal text can change. Check with the
maintainer before any test that pins the message is changed.

## 8. Lua function-target rule

**Paths.** In `Sources/APIServer/Utilities/IdentifierValidation.swift`,
`isValidIdentifier` (`:117`) uses `isValidLuaIdentifier` for Lua, but
`isValidFunctionTarget` (`:167`) uses Python's rule for Lua. The comment at
`:161` says Lua "has a sanitizer rather than a validator". That is no longer
true: `isValidLuaIdentifier` exists (`LuaScriptHelpers.swift:26`) and rejects
Lua reserved words.

**Evidence of drift.** This is a latent bug. Python's rule accepts Lua reserved
words such as `end`, `local` and `then`. The Lua renderer looks the target up as
a string key (`PatternFamilyRendererLua.swift`, `rawget(student, function_name)`),
so the test renders. But no student can define a function with that name, so
the test can never pass. The author gets no error at save time.

**Proposed change.** Use `isValidLuaIdentifier` for Lua in
`isValidFunctionTarget`, and correct the comment. No abstraction is necessary.
`identifierKindName` (`:130`) is a parallel switch that could move to
`LanguageDescriptor`, but it has not drifted.

**Recommendation: fix now, with a new test.**

## 9. Token caches: GitHub and LTI

**Paths.** `GitHubInstallationTokenCache` (`GitHub/GitHubInstallationTokenCache.swift:13`)
and the token dictionary inside `LTIServiceClient` (`LTI/LTIServiceClient.swift:158`).
Both keep a token until a margin before expiry and drop it on HTTP 401
(`GitHubSubmissionAccess.swift:183`, `LTIServiceClient.swift:193`). BrightSpace
signs each request with HMAC and has no token.

**Evidence of drift.** None that matters. The margins differ (300 s and 60 s),
but each fits its platform.

**Proposed abstraction.** A generic `ExpiringTokenCache<Key>` actor. It removes
about 30 lines.

**Recommendation: wait.** There are two small, correct copies with different
owners. Do this when a third token-based integration arrives.

## 10. Browser result-post retry

**Paths.** The worker retries its result upload with backoff
(`Worker/RunnerNetworkResilience.swift:43`). The browser posts once and shows
an error on failure (`Public/browser-runner.js:819`).

**Why this is not drift.** The worker report is keyed by an existing submission
ID, so a resend is safe. A browser post creates a new submission, so a retry can
make a duplicate attempt. A shared retry policy is wrong until the browser post
has an idempotency key.

**Recommendation: no action.** If a browser retry is wanted later, add the
idempotency key first.

## Areas with no candidate

- **Background services and reapers.** All 18 periodic services use
  `PeriodicSweepMonitor`, which owns scheduling, the lease, shutdown and error
  logging. The sweep bodies (for example `reapStaleAuditLogEntries`,
  `reapStaleActivityEvents`) are five-line delete queries. A generic "delete
  rows older than" helper saves little, and `reapStaleSessions` has a
  database-specific branch that such a helper must not hide.
- **Per-language switches.** Of the 32 `switch` sites over a language, almost
  all answer one question each (a code generator, a probe program, a runtime
  helper file) and are exhaustive on purpose, so the compiler finds each site
  for a new language. File extensions are not repeated outside
  `LanguageDescriptor`. The two exceptions are candidates 7 and 8.
- **R browser run-output parser.** `parseRunOutput` in
  `Public/r-grading-shared.js` differs from the shared `parseStatusRunOutput` in
  `Public/grading-shared.js`. This is deliberate: R replays the captured stdout
  after the status line, so it needs an end marker. The other copies already use
  the shared parser (#1963).
