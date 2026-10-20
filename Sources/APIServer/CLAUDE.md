# APIServer — Area Rules

Claude Code loads this file when it works under `Sources/APIServer/`. The rules
for the whole repository are in the root `CLAUDE.md`. The MCP server and the
views have their own files: `MCP/CLAUDE.md` and `Views/CLAUDE.md`.

---

## REST API

Base path: `/api/v1`

```
# Runner endpoints (HMAC-signed)
POST /worker/request                    — Runner polls for a pending job
POST /worker/results                    — Runner reports TestOutcomeCollection
GET  /worker/artifacts/:submissionID    — Runner downloads submission zip

# Test setups (instructor upload; download available to all authenticated users)
POST /api/v1/testsetups                 — Instructor uploads test setup zip (multipart)
GET  /api/v1/testsetups/:id/download    — Stream zip to runner

# Submissions
POST /api/v1/submissions                — Accept student submission zip
GET  /api/v1/submissions                — List submissions (?testSetupID= filter)
GET  /api/v1/submissions/:id            — Submission status
GET  /api/v1/submissions/:id/results    — Full TestOutcomeCollection (?tiers= filter)

# Web / browser results
GET  /results/:id                       — Browser-rendered result view

# Instructor suite editor (server-authoritative, v0.4.79+)
GET  /instructor/:assignmentID/suite    — Author-facing view of the ordered suite list
PUT  /instructor/:assignmentID/suite    — Persist drag-reorder, tier/points/displayName edits
PUT  /instructor/:assignmentID/families — Save a pattern family (add/edit/delete)

# Notebook authoring from the embedded editor (course staff, TA+)
POST /testsetups/:id/notebook/save      — Write the notebook open in JupyterLite
                                          back to the assignment
                                          (?file=assignment|solution)

# The student guide beside each task in the editor (docs/notebook-guide.md)
GET  /testsetups/:id/notebook-guide.json — The viewer's own guide: public
                                          results only, anchors, starter sources
GET  /instructor/:assignmentID/suite-outline.json — Staff only: the suite by
                                          section, anchors, solution results
PUT  /instructor/:assignmentID/suite-anchor — TA and above: pin a hand-written
                                          test to a cell name ({script, anchor|null})
GET  /instructor/:assignmentID/preview-guide.json?as=<token> — TA and above:
                                          a student's guide with no attempt (NB6b)
```

Web routes (Elementary views, session auth required) live under `/` and handle
login, registration, the student dashboard, assignment pages, submission
history, instructor assignment CRUD, and the admin panel.

All JSON endpoints use `application/json`. The test setup upload is multipart.

---

## Auth & Roles

Deployment roles: `user` < `admin` (plus the non-login `mcp` service role).
Per-course roles on the enrollment row: `student` < `ta` < `instructor`
(#417 — there is no global student/instructor anymore).

- **Unauthenticated:** login, register, runner endpoints (HMAC-signed separately)
- **Authenticated (any user):** web UI, submission queries, result views,
  JupyterLite content routes, notebook download — visibility scoped to
  enrolled courses
- **Course staff (per-course `ta`+):** assignment content editing, grading
  actions (retest/reset/grade-override), all-tier/result visibility for that
  course
- **Per-course `instructor`:** everything a TA can do, plus enrollment/roster/
  staff management, assignment lifecycle (create/delete/open/close/deadlines),
  course sections (but not their reorder: every reorder kind is TA+,
  `SortOrderRenumbering.roleFloor`), archival, BrightSpace binding
- **Admin:** admin panel, course creation, worker secret/autostart management,
  runner dashboard (admins bypass per-course role checks, but MCP agents
  acting for them stay enrollment-scoped)

Enforcement chokepoints: `requireCourseRole(atLeast:)` / `evaluateCourseWrite`
in `CourseAccessHelpers.swift` (web + MCP share the policy); the `/instructor`
area gate is `ActiveCourseStaffMiddleware` (staff in the *active* course), with
per-resource gates on every parameterized route. See `docs/multi-course-roles.md`.

Session auth uses Vapor's `SessionAuthenticator`. Sessions are persisted
via the Fluent driver (v0.4.46), so they survive restarts and work across
multi-process deployments. Session cookie is `HttpOnly; SameSite=Lax`; `Secure`
flag is set automatically when `PUBLIC_BASE_URL` is `https://` or `AUTH_MODE`
is non-local.

**Auth is pluggable.** `AUTH_MODE` env var selects `.local` (username/password),
`.sso` (OIDC/OAuth), or `.dual` (both active simultaneously). `APIUser` carries
`authProvider` + `externalSubject` for SSO identity. Both `.local` and `.sso`
are fully implemented. The OIDC flow uses Authorization Code + PKCE; the
discovery document and JWKS are fetched at startup from `OIDC_AUTH_SERVER`.
Role assignment uses the `SSO_ADMIN_USERS` env var (a comma-separated identity
allowlist checked against JWT claims on every login); instructor authority is
per-course (assigned from the course roster), so there is no SSO instructor
allowlist (`SSO_INSTRUCTOR_USERS` was retired in the multi-course-roles work).
The current implementation is tested against UWaterloo DUO; claim names
(`winaccountname`, `user_id`) are in `OIDCIDTokenClaims.swift` and can be
adjusted for other providers.

---

## Configuration and Runner Trust

**HTTPS enforcement is optional and proxy-aware.** `AppSecurityConfiguration`
reads `ENFORCE_HTTPS`, `PUBLIC_BASE_URL`, `TRUST_X_FORWARDED_PROTO`, and
`SESSION_COOKIE_SECURE`. `HTTPSRedirectMiddleware` handles the enforcement and
respects `X-Forwarded-Proto` from reverse proxies.

**Environment configuration is centralized (v0.4.168+).** Every env var read
by the server flows through `AppConfig` (`Sources/APIServer/Configuration/`).
At startup `configure(_:)` calls `AppConfig.fromEnvironment(workDir:)` once,
stashes the result on `Application.appConfig`, and emits a redacted summary
to the log. Subsystems read typed substructs (`appConfig.auth`, `.security`,
`.workers`, `.oidc`, `.database`, `.lockout`, `.diagnostics`, `.alerts`,
`.brightspace`, `.scanMode`) rather than calling `Environment.get` directly.
Tests can preload an `AppConfig` via `Application.preloadedAppConfig` (the
seam `configure(_:)` checks first) or pass one to `makeTestApp(appConfig:)`.
Do not add a new variable (root `CLAUDE.md`, "What Not To Do").

**Worker secret is auto-generated.** If no secret is provided at startup, a
random three-word diceware passphrase is generated from the EFF wordlist and
persisted to `.worker-secret`. The runner reads it from `RUNNER_SHARED_SECRET`.
All runner↔server requests are HMAC-signed (`WorkerHMACAuthMiddleware`).

**Local runner autostart.** The server can spawn a `chickadee-runner` subprocess
automatically if `.local-runner-autostart` exists (or is toggled via the admin
dashboard). This is a development convenience; production runs the runner
separately.

---

## Courses, Deadlines and Goals

**Assignment vanity URLs (v0.4.71).** Each assignment gets a per-course
unique slug. Student links prefer `/:courseCode/:assignmentSlug` routes while
the canonical `/testsetups/:id/submit` handlers remain active for
compatibility. The first segment is the course's `urlKey`: the code, or
"CS135-F26" for a course with a term (see the next entry).

**A course is one offering: a code plus a year and a term
([docs/course-terms.md](../../docs/course-terms.md)).** Every door that creates
a course declares a term, and nothing infers one. A bare code can name more than
one active course. **Do not add a code-only lookup.** Use
`findActiveCourse(byKey:viewer:on:)` on the web or `resolveMCPCourse` in MCP;
MCP refuses a write through an ambiguous code. A clone for a new term starts
every copied assignment closed, with no dates and the solution reveal off.

**Post-deadline reveals wait for the slip-day claim window, not just the
deadline.** `postDeadlineRevealDeadline` (`AssignmentDeadlineService`) is the one
resolver for that moment. Release-tier output and the solution reveal both use
it. See [docs/solution-visibility.md](../../docs/solution-visibility.md).

**A class goal counts one of three things, and the sweep evaluates no fourth.**
`isSweepEvaluableClassGoal` admits exactly four shapes: no conditions, or a
single `grade`, `itemsCovered` or `classCoverage` `atLeast`. Every other shape
is refused at save time and skipped with a log by the sweep, so a hand-authored
manifest cannot mis-grade a bonus. A union or corpus goal grades on the smaller
of coverage and breadth. See
[docs/collaborative-class-assignments.md](../../docs/collaborative-class-assignments.md)
§"Class goals in force".

---

## Authoring

**Pattern-generated test families (v0.4.75+).** Instructors can define a
`PatternFamily` (Core/) — one function, shared defaults, a table of cases —
and Chickadee expands each enabled case into an ordinary test script in the
assignment's language at save time. Families live in
`TestProperties.patternFamilies`; generated entries in `testSuites` carry
`generatedBy: <familyID>` so the raw-script edit endpoints refuse to mutate
them (you edit the family instead). Ten kinds ship; `PatternKind` lists them.
Generated filenames are deterministic (`{tier}test_{familyID}_{caseKey}`, with
the language's generated extension) and embed a `spec_hash` header so manifest
bytes change when any case changes.

**The authoring editors ([docs/authoring-editors.md](../../docs/authoring-editors.md)).**

- The suite editor is server-authoritative. `PUT /instructor/:assignmentID/suite`
  and `PUT /instructor/:assignmentID/families` persist each edit and return the
  reconciled state. `dependsOn` accepts `family:<id>` tokens, which the server
  expands before it persists them.
- `POST /testsetups/:id/notebook/save` is a live-edit endpoint, like `PUT /suite`.
  It never changes visibility. Re-validation still runs.
- The authoring pages read the language from one seed, `AuthoringLanguageFacts`,
  and every value in the seed is derived from the code that owns the answer. A
  new language needs zero JavaScript edits. A new fact is a new field, derived
  from its owner. `AuthoringLanguageFactsTests` asserts the derivation.
- Auto-compute of a case's expected value runs on the server
  (`PersonalizationEvaluator`) for every language but Python.

**`makeWorkerManifestJSON(preserving:)` copies the decoded manifest.** Do not
build a fresh dict: it drops `languageDeclared`.

**Personalization runs per language on the server**
(`PersonalizationEvaluator`). Expression source and the solution never reach
the runner. See `docs/personalization-eval-runtime.md`.

Instructor validation is a `kind == .validation` submission, graded by the
**native worker** (`WorkerJobRoutes.collectClaimCandidates`). It never runs a
kernel. There is no `assignment-validate.js`.
Each validation also queues a **starter run**, a `kind == .starterValidation`
submission that grades the assignment notebook with the same seed
(`StarterValidationRun`, NB8). A runner claims it after every solution run. It
never sets `validationStatus`, so it never blocks opening; it only feeds the
workbench's "passes on the starter" warnings. Do not treat it as a solution
run: every "newest validation row is the solution" lookup filters on
`.validation`.

---

## Browser Isolation and CSP

**Every worker the notebook page spawns must be in
`NotebookAssetIsolationMiddleware.isolatedWorkerScripts`.** If it is not, an
isolated engine refuses the script. The submission then fails over to the native
worker with no error. `IsolatedWorkerScriptDriftTests` guards the list. See
`docs/adding-a-xeus-kernel.md` step 8.

**The CSP `script-src` permits no inline execution (#1516).** The page-level
rule is in `Views/CLAUDE.md`. Do not suppress a coarse third-party scanner rule
to accept one of its findings. What the policy keeps, and why, is in the
`scripts/check-security-headers.sh` header.
