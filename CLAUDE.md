# Chickadee — Project Context

## What This Is

A clean-break rewrite of Marmoset, a student code submission and autograding
system originally built in Java at the University of Maryland. The rewrite is
in Swift using Vapor, targeting both macOS and Linux. No interoperability with
the original Java system is required.

The architecture has been redesigned from scratch; the original Java source is
not in this repository. (A couple of code comments cite Marmoset behaviours —
e.g. `chickadee.py`'s exit-code 3 — and are self-contained.)

---

## Shell Snippets (maintainer environment)

The maintainer runs **zsh with `interactive_comments` off**. When giving shell
commands meant to be pasted into a terminal — in chat or in `docs/` runbooks:

- **No inline `#` comments on a command line** — zsh parses `#` as a normal
  argument, so `cmd value  # note` fails with "too many arguments".
- **No apostrophes in explanatory text inside a code block** — an unmatched `'`
  drops zsh into a `quote>` continuation prompt and nothing runs.
- **One plain command per line.** Keep all explanation in prose *outside* the
  code block; never rely on `#` to annotate inside it.

---

## Architecture Overview

Swift targets share a clean dependency boundary:

- **`APIServer` / `chickadee-server`** — Vapor app. REST API + Leaf web UI.
  Handles auth, assignment management, submission intake, result storage, the
  JupyterLite notebook workflow, and the MCP server (see below).
- **`Worker` / `chickadee-runner`** — Daemon process. Polls for jobs, runs
  shell-script test suites in subprocesses (sandboxed or unsandboxed), reports
  structured results back to the server.
- **`RunnerCore`** — The shared, Vapor-free, **Embedded-Swift-compatible**
  grading core. Compiled two ways: natively (linked into the worker) and to
  **WebAssembly** (the in-browser runner). It owns suite execution
  (`executeSuites`), output interpretation (`interpretScriptOutput`), script
  classification, notebook extraction (one `extract<Language>` per language), and the
  `TestOutcome` / `TestTier` / `TestStatus` types — so the native and browser
  graders run one implementation and cannot drift. Pinned by the shared
  `Tests/Fixtures/output-contract.json` contract, asserted against both the
  native build and the *real vendored wasm* in CI.
- **`Core`** — Shared models and types. No Vapor dependency; `@_exported import
  RunnerCore` re-exports the grading types. Every other target depends on this.

Test suites are **shell scripts** bundled by the instructor inside the test
setup zip. The runner executes them generically. Adding a new language means
writing a new shell script; no Swift changes are required for the *grading*
path. The runner does include Python/notebook-specific submission normalization
(`SubmissionNormalizer`, `NotebookExtractor`) that pre-processes uploads before
handing them to the shell scripts.

---

## Key Design Decisions

**Shell scripts, not language runners.** Each test suite is a `.sh` file at the
root of the instructor's test setup zip. The runner runs them with `/bin/sh`
and maps the exit code to a result status. No per-language runners, no runner
JSON protocol. The runner does contain a Python/notebook normalization layer
(`SubmissionNormalizer`) that pre-processes uploaded files into a grading
workspace before the shell scripts run. This is a submission-format concern,
not a grading concern — the shell scripts themselves remain language-agnostic.

**Instructor bundles the helper library.** Any helper library (Swift, Python,
etc.) is included in the test setup zip by the instructor. The runner does not
inject anything.

**Build failure lives at the collection level, not the test level.** If the
build fails (e.g. `make` step fails), `buildStatus` is `"failed"` and
`outcomes` is `[]`. There is no `couldNotRun` state on individual test outcomes.

**Test outcomes have four states only:** `pass`, `fail`, `error`, `timeout`.

**Three test tiers:** `public` (shown immediately), `release` (hidden until
deadline), `secret` (never shown). A fourth, `student`, was documented here and
advertised by the MCP schema for most of the project's life while `TestTier`
never had it — so `author_script` accepted it into its JSON schema and then
rejected it at `TestTier(rawValue:)`, and the web suite editor silently coerced
it to `.pub`. It is gone from the schema, and the tier prose is now DERIVED from
`TestTier.allCases` (`MCPTierProse`, guarded by `MCPTierCoverageTests`) so
neither a phantom nor a truncated list can reappear. Student-contributed tests
do not want a tier: the suite is instructor-authored, and a student's
contribution is submission content, not a suite entry — see
[docs/collaborative-class-assignments.md](docs/collaborative-class-assignments.md).

**Gamification fields are present from day one but nullable.** `memoryUsageBytes`,
`attemptNumber`, `isFirstPassSuccess` are in the schema now so we never need a
migration later. They can be null/zero until the feature is built.

**`ScriptRunner` is the sandbox boundary.** `UnsandboxedScriptRunner` is the
default in development. `SandboxedScriptRunner` implements the same protocol
using platform sandboxing (macOS: `sandbox-exec`; Linux: `unshare` user/net
namespaces). Enable with `--sandbox` on the runner.

**Subprocess boundary for all language execution.** Swift never imports a JVM,
Python interpreter, or any language runtime. Everything goes through
`Process` + sandbox.

**Browser grading has four substrates, routed per script (#1271).**
`RoutingExecutor` in `Public/grading-executors.js` sends each script to the xeus
kernel for its language. It classifies with the same `RunnerCore.classifyScript`
that the native worker uses. It boots only the runtimes that the assignment
contains. `RunnerCore` owns the suite loop and output interpretation for all
four; a substrate only runs a script and reports its exit code and streams. See
`docs/architecture.md`. xeus-r is the only route to in-browser R; its masks and
its one-top-level-expression rule are in `docs/r-support.md`.

**Every worker the notebook page spawns must be in
`NotebookAssetIsolationMiddleware.isolatedWorkerScripts`.** If it is not, an
isolated engine refuses the script. The submission then fails over to the native
worker with no error. `IsolatedWorkerScriptDriftTests` guards the list. See
`docs/adding-a-xeus-kernel.md` step 8.

**Assignment languages.** Seven ship. `LanguageDescriptor`
(`Sources/Core/LanguageDescriptor.swift`) holds the facts per language, and MCP
`get_server_info` reports them, with the refused kinds and a reason for each.

| Language | Editor | Generated test | Doc |
|---|---|---|---|
| Python | xeus-python kernel | `.py` | `docs/architecture.md` |
| R | xeus-r kernel | `.R` | `docs/r-support.md` |
| Lua | xeus-lua kernel | `.lua` | `docs/adding-a-xeus-kernel.md` §"What the Lua run actually cost" |
| Octave | xeus-octave kernel | `.m` | `docs/adding-a-xeus-kernel.md` §"What the Octave run actually cost" |
| C++ | upload-only (a decision) | `.sh` wrapper | `docs/cpp-support.md` |
| Racket | upload-only (no kernel exists) | `.rkt` | `docs/multi-language-audit.md` |
| Java | upload-only (both reasons) | `.sh` wrapper | `docs/java-support.md` |

An upload-only language also sets `submissionMode: "uploadOnly"`. There is no
third "both" value (`TestProperties.swift`). Which check kinds each language
refuses, and why: `docs/authoring-parity.md`. Per-language literal traps:
`docs/adding-a-xeus-kernel.md` §"Traps".

- **Mask the exit call.** The kernels mask R `quit()`, Lua `os.exit`, and
  Octave `exit` and `quit`. The Java wrapper requires a sentinel line, because
  `System.exit(0)` cannot be masked. If a mask regresses, every test reads as a
  pass.
- **Budget one quirk per kernel, not the same one.** R's per-expression wait and
  its stderr trap did not occur on Lua or Octave.
- **`.sh` carries no language signal.** To ask whether a language generates a
  `.sh` wrapper, read `LanguageDescriptor.generatesLanguagelessWrapper`. Do not
  write `language == .cpp`.

**Every assignment declares its language. Nothing infers one (#1331).**
`resolve(manifest:)` returns `manifest.language` and nothing else. A nil
language means that the author said "none": a suite of hand-written scripts.
**Do not reintroduce inference.** If a call site does not know the language,
ask the author. `AssignmentLanguage.derivedDeclaration` runs only at three
boundaries, and each records the result at once. See
[docs/language-declaration.md](docs/language-declaration.md).

- **No function may default a `language:` parameter.**
  `scripts/no-language-defaults.sh` enforces this in `format-lint`.
- **Fail loudly while authoring. Never fail while grading, rendering a page or
  extracting a student's submission.** Every remaining `?? .python` follows this
  rule; the per-site table is in `docs/language-declaration.md`.
- **`makeWorkerManifestJSON(preserving:)` copies the decoded manifest.** Do not
  build a fresh dict: it drops `languageDeclared`.
- **Personalization runs per language on the server**
  (`PersonalizationEvaluator`). Expression source and the solution never reach
  the runner. See `docs/personalization-eval-runtime.md`.

**A declared language is not exclusive. Shell is the substrate.** The
declaration controls what Chickadee generates. A script's own extension controls
how it runs, so a `.R` helper in a Python assignment runs under `Rscript`.
Content does not change the declaration. Only an explicit change does: the
language dropdown, or MCP `set_assignment_language`. "None" means "nothing is
generated". Do not add a `.shell` language case. See
`docs/language-declaration.md` §"A declared language is not exclusive".

**A runner claims only a job it can grade (`RunnerLanguageGate`).**
`AssignmentLanguage.languagesRequiredToGrade(manifest:)` unions the declared
language with every language that the suite's extensions imply. A runner whose
advertised profile lacks one of them does not claim the job. There is no
authoring step. `minimumRunnerVersion` is the wrong tool for a new language.
Validation runs on the native worker, so browser-graded assignments are gated
too. See `docs/runner-capability-profiles.md`.

**A class goal counts one of three things, and the sweep evaluates no fourth.**
`isSweepEvaluableClassGoal` admits exactly four shapes: no conditions, or a
single `grade`, `itemsCovered` or `classCoverage` `atLeast`. Every other shape
is refused at save time and skipped with a log by the sweep, so a hand-authored
manifest cannot mis-grade a bonus. A union or corpus goal grades on the smaller
of coverage and breadth. See
[docs/collaborative-class-assignments.md](docs/collaborative-class-assignments.md)
§"Class goals in force".

**Post-deadline reveals wait for the slip-day claim window, not just the
deadline.** `postDeadlineRevealDeadline` (`AssignmentDeadlineService`) is the one
resolver for that moment. Release-tier output and the solution reveal both use
it. See [docs/solution-visibility.md](docs/solution-visibility.md).

**Roles are two-level: a deployment role plus a per-course role (#417).**
The deployment-global `UserRole` on `APIUser` is just `user` | `admin`
(plus the non-human `mcp` service-account role) — the legacy global
`student`/`instructor` roles were retired by the #417 multi-course-roles
series (`CollapseUserRoles` migration). Teaching authority is **per-course**:
each enrollment row carries a `CourseRole` (`student` < `ta` < `instructor`),
so one account can be an instructor in one course and a student in another.
TAs author content and grade but cannot manage enrollment/deadlines/
archival/staff. Enforcement chokepoints: `requireCourseRole(atLeast:)` /
`evaluateCourseWrite` in `CourseAccessHelpers.swift` (web + MCP share the
policy); the `/instructor` area gate is `ActiveCourseStaffMiddleware`
(staff in the *active* course), with per-resource gates on every
parameterized route. See `docs/multi-course-roles.md`.

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

**The CSP `script-src` permits no inline execution (#1516).** An inline
`<script>` in a template does not run, and an `onclick=` / `onchange=` attribute
never fires. Neither failure is loud. Put page JS in a `Public/*.js` file and
use the delegated data attributes at the foot of `app.js` (`docs/ui-design.md`
§"Page-local scripts"; `check-styles.sh` rules 3b, 3b-2 and 3b-3). Do not
suppress a coarse third-party scanner rule to accept one of its findings. What
the policy keeps, and why, is in the `scripts/check-security-headers.sh`
header.

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

**Worker secret is auto-generated.** If no secret is provided at startup, a
random three-word diceware passphrase is generated from the EFF wordlist and
persisted to `.worker-secret`. The runner reads it from `RUNNER_SHARED_SECRET`.
All runner↔server requests are HMAC-signed (`WorkerHMACAuthMiddleware`).

**Local runner autostart.** The server can spawn a `chickadee-runner` subprocess
automatically if `.local-runner-autostart` exists (or is toggled via the admin
dashboard). This is a development convenience; production runs the runner
separately.

**MCP server (`Sources/APIServer/MCP/`).** Chickadee is its own MCP server and
its own OAuth 2.1 authorization server. `MCP_MODE` (`off` / `read_only` /
`read_write`) gates it. The protocol era is resolved per request (#1218), and
`initialize` never negotiates up to the modern revision. OAuth codes and tokens
are stored only as hashes and are consumed by an atomic conditional `UPDATE`,
so a code cannot be replayed. See `docs/architecture.md` §"MCP surfaces" and
`docs/mcp-2026-07-28-revision.md`. The `initialize` instructions end with the
authoring-voice guide, and a course's instructors can replace it for their
course (see "Voice and Register" below).

**The MCP surface holds no language names (#1290).** Every language list in
agent-facing copy derives from `allCases` (`MCPLanguageProse`), and
`get_server_info` reports a `languages` payload. `MCPLanguageCoverageTests`
fails on any list that stops short. A new language needs no edit to MCP prose.
See `docs/adding-a-xeus-kernel.md`, compiler-invisible item 8.

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

**Server-authoritative suite editor (v0.4.79+).** The instructor assignment
edit page is wired to `PUT /instructor/:assignmentID/suite` and
`PUT /instructor/:assignmentID/families` — drag-reorder, tier/points edits,
and family edits persist live with the server returning the reconciled state.
The legacy client-side `#suite-config-field` JSON blob and the
`/edit/save` suite-rebuild path are gone; the main Save button only handles
name, due date, notebook uploads, and the validation enqueue. Dependencies
accept `family:<id>` tokens which the server expands to concrete filenames
before persistence; cycle detection runs on the authored graph.

**The embedded editor writes back (`POST /testsetups/:id/notebook/save`).**
JupyterLite keeps the live document in the browser, so authoring edits used to
reach the server only via an upload on the new-assignment page or the MCP
`update_notebook` / `update_solution` tools. Course staff (TA+) now get a
"Save to assignment" button on the notebook page that POSTs the open notebook
back through the same server-side steps those tools use —
`AssignmentAuthoringService.writeAssignmentNotebook` for the starter, a fresh
`kind == .validation` submission for the solution — plus the author's working
copy so a reload shows the save, and the version snapshot every authoring write
gets. It is a **live-edit** endpoint: like `PUT /suite` and unlike the MCP
tools, it never changes visibility, so fixing a typo mid-lab does not close the
assignment out from under students. Re-validation still runs (debounced for the
starter, always for a solution, since the new solution *is* what validates).

**The authoring UI reads the assignment's language from ONE seed (v0.5.36).**
The browser editors had no notion of language at all: `pattern-family-editor.js`
contained the string "language" zero times, and `inputs-editor-core.js` had the
identical defect, so both parsed instructor input by Python's rules — `True` /
`False` / `None` plus a Python-repr rewrite — on every assignment. An R author
typing the boolean true stored the **string**, silently, in a value a generated
test then compares.

`AuthoringLanguageFacts` is now encoded into an `#assignment-language-seed`
script tag on both authoring pages, and `Public/authoring-language.js`
(`window.ChickadeeLanguage`) is the single reader. **Every value in the seed is
derived, never tabulated:** the scalar spellings come from
`JSONValue.literal(_:)` — the same call that renders the real generated test, so
the editor cannot show one spelling while the renderer emits another — kind
availability from `notebookCheckKindIsSupported` (the predicate the save-time
refusal uses, so the Add Test menu and the rejection cannot disagree), scan
support from `notebookFunctionScanSupport`, and evaluation support from
`PersonalizationEvaluator`.

The consequence worth knowing before touching this: **a seventh language needs
zero JavaScript edits.** There is no per-language list in any authoring JS, and
the invariant is greppable (see the runbook's "The authoring UI: what you do NOT
have to do"). If a new *fact* is needed, add a field to `AuthoringLanguageFacts`
and derive it from whatever already owns the answer — do not answer it twice.
Both mistakes were made and undone here: the literals were nearly generated into
a JS table, and two capability flags shipped as hand-written bools before being
pointed at their real owners. `AuthoringLanguageFactsTests` asserts the
derivation.

**Auto-computing a case's expected value runs on the SERVER for every language
but Python** (`POST /instructor/:id/compute-expected`). The in-page evaluator is
a Python kernel; on another language it did not fail, it computed a *Python*
answer for a value compared against that language's result.
`PersonalizationEvaluator` already evaluates in every language behind an
exhaustive switch, so the fix was to route to it rather than grow a kernel per
language into the page. Python keeps the in-page path (faster, and its `None`-return and
non-round-trippable-type handling is behaviour existing assignments rely on).
Two stated limits: the drivers report values as their language's REPR (base R and
Lua have no JSON to serialize with), so a scalar round-trips into the Expected
cell and a composite may not — the client decides, using the same language-aware
reader hand-typed values go through; and automatic stdout capture is offered
where one expression expresses it (R's `capture.output`, Octave's `evalc`) and
reported unavailable where it does not.

**Assignment vanity URLs (v0.4.71).** Each assignment gets a per-course
unique slug. Student links prefer `/:courseCode/:assignmentSlug` routes while
the canonical `/testsetups/:id/submit` handlers remain active for
compatibility. The first segment is the course's `urlKey`: the code, or
"CS135-F26" for a course with a term (see the next entry).

**A course is one offering: a code plus a year and a term
([docs/course-terms.md](docs/course-terms.md)).** Every door that creates a
course declares a term, and nothing infers one. A bare code can name more than
one active course. **Do not add a code-only lookup.** Use
`findActiveCourse(byKey:viewer:on:)` on the web or `resolveMCPCourse` in MCP;
MCP refuses a write through an ambiguous code. A clone for a new term starts
every copied assignment closed, with no dates and the solution reveal off.

**Runner-side LRU test setup cache (v0.4.41).** `TestSetupCache` (Swift actor,
default 16 entries) keeps fully-prepared test setup directories keyed by
`testSetupID`. Cache key hashes manifest + zip content, so any suite edit
busts the entry. Concurrent jobs for the same setup share one in-flight
population task.

---

## Test Script Contract

Each test suite is a shell script run with `/bin/sh <script>` from the test
setup directory as the working directory.

| Exit code | Meaning |
|-----------|---------|
| 0 | pass |
| 1 | fail |
| 2 | error |
| killed (SIGKILL after timeout) | timeout |

**stdout:** Everything is ignored except the last non-empty line, which is
attempted as JSON:
```json
{ "score": 0.75, "shortResult": "3/4 cases passed" }
```
If the last line is not valid JSON, it is used as the plain-text `shortResult`.
If stdout is empty, `shortResult` is synthesized from the exit code
("passed" / "failed" / "error").

`score` carries partial credit: a `Double` clamped to `0...1` giving the
fraction of the test's points the submission earned, so the test contributes
`points × score` to the collection's `earnedPoints`. It is orthogonal to the
exit code — the exit code drives the pass/fail badge, `score` drives the credit
— so a script may report a partial `score` on either. A script that emits no
`score` grades exactly as before: full credit on a pass, none otherwise. A test
skipped because a `dependsOn` prerequisite failed scores 0.

`metric` is an optional, unclamped `Double` for **ranking**, never credit: a
class activity's leaderboard sorts on it, highest first, and nothing reads it
for a grade (`docs/class-activities.md`). Orthogonal to both `score` and the
exit code; a script that reports none has no ranking position. A non-numeric
value is ignored.

**stderr:** Captured verbatim as `longResult` (nil if empty).

**How much of a failure the student sees is a per-entry display setting**
(`TestSuiteEntry.failureDetail`: `full` | `actualOnly` | `verdictOnly`),
applied by the server at results-display time and never by the script.
`actualOnly` keeps only the student's own side of a generated message (the
`input:` / `got:` / `error:` labels and a recognised headline) and withholds
`expected:`, a diff, a tolerance or a budget; a hand-written script degrades
to the verdict under it, because nothing in its output says which half is
the answer. Staff always read the full text, and the hint shows at every
level. Family defaults, per-case values and notebook checks write their
resolved level onto the entries they generate. See
[docs/failure-detail.md](docs/failure-detail.md).

---

## Data Models

The source is the reference; this section names where each type lives and the
rules the code alone does not state.

- `TestStatus` — `Sources/RunnerCore/TestStatus.swift`: `pass`, `fail`,
  `error`, `timeout`. There is no `couldNotRun`; a build failure is
  `buildStatus: "failed"` on the collection.
- `TestTier` — `Sources/RunnerCore/TestTier.swift`: `public` (`.pub`),
  `release`, `secret`. There is no student tier (see Key Design Decisions).
- `TestOutcome` — `Sources/RunnerCore/TestOutcome.swift`: one test's result,
  including `score` (0...1 credit), `points`, and the optional ranking `metric`.
- `TestOutcomeCollection` — `Sources/Core/Models/TestOutcomeCollection.swift`:
  one submission run, with the counts and `buildStatus`.
- `TestProperties` — `Sources/Core/TestProperties.swift`: the manifest
  (`test.properties.json`), with `testSuites`, `patternFamilies`,
  `timeLimitSeconds` and the optional `makefile`.
- `PatternFamily` and `PatternKind` — `Sources/Core/Models/PatternFamily.swift`.

Two manifest rules worth knowing:

- `makefile` is optional. When present, a `make` step runs before the test
  scripts: bare `make` when `target` is `null`, else `make <target>`.
- `patternFamilies` is the canonical spec for generated test families; each
  enabled case expands to a `testSuites` entry with `generatedBy: <familyID>`.
  `dependsOn` entries in authored form accept `family:<id>` tokens, which the
  server expands to the family's concrete generated filenames before
  persisting.

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
```

Web routes (Leaf-rendered, session auth required) live under `/` and handle
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
  course sections, archival, BrightSpace binding
- **Admin:** admin panel, course creation, worker secret/autostart management,
  runner dashboard (admins bypass per-course role checks, but MCP agents
  acting for them stay enrollment-scoped)

Session auth uses Vapor's `SessionAuthenticator`. Sessions are persisted
via the Fluent driver (v0.4.46), so they survive restarts and work across
multi-process deployments. Session cookie is `HttpOnly; SameSite=Lax`; `Secure`
flag is set automatically when `PUBLIC_BASE_URL` is `https://` or `AUTH_MODE`
is non-local.

---

## JupyterLite

Chickadee embeds a full JupyterLite instance at `Public/jupyterlite/`. This
enables in-browser notebook editing for both students (submit) and instructors
(create/validate assignments).

Source-of-truth config lives in `Tools/jupyterlite/`. Rebuild:

```bash
scripts/setup-jupyterlite.sh
scripts/build-jupyterlite.sh
```

`Public/jupyterlite` is generated output and is checked in; rebuild only when
updating kernel versions or config.

**Every vendored kernel is a xeus kernel, one env each.**
`Tools/jupyterlite/environment-python.yml`, `environment-r.yml`,
`environment-lua.yml` and `environment-octave.yml` declare one
emscripten-forge environment each, yielding `xpython` (Python, xeus-python),
`xr` (R, xeus-r), `xlua` (Lua, xeus-lua) and `xoctave` (Octave, xeus-octave);
`jupyter lite build` compiles them all into
`Public/jupyterlite/xeus/`. They are **separate envs on purpose** — a kernel
fetches its whole env at boot, so a shared env makes every Python boot pull
r-base and every R boot pull numpy/pandas/matplotlib (slow enough to time out
the editor probes). `check-xeus-vendored.sh` asserts they stay distinct. Python moved
off the Pyodide kernel in the 0.5 series, so the editor runs one kernel
technology for every language. Notebook metadata is normalized to those names by
`normalizeNotebookForJupyterLite` (`NotebookContentHelpers.swift`) — for every
vendored kernel. A Lua notebook resolves to `xlua` and extracts through the
same marker-emitting RunnerCore extractor R uses — vendoring a kernel puts it
in the editor's picker, so a language that can be authored must be one that
can be graded.

**One place still enumerates the kernels rather than discovering them, and it
fails open for one it has never heard of:** the `chickadee-*` glob in
`build-jupyterlite.sh`, which decides who gets a module index. It does not error
— you simply get a kernel nothing checks. Its twin is closed: `expected_language`
in `check-xeus-vendored.sh` derives the expected set from each language's
`editorSupport.notebookKernel(kernelName:)`, so a kernel is guarded the day its
descriptor names it.

**Deriving it did not make it safe.** That derivation reads Swift with a regex
and paired language to kernel by line PROXIMITY, so when #1330 hoisted the
descriptors into their own `static let`s it went silently partial — one kernel,
mapped to the wrong language — and `main` was red for five releases while every
PR showed green, because the workflow's path filter reported the job green when
it skipped it and only `push` counted as relevant. Three rules came out of it: a
derivation must assert its own **completeness** (only an empty one used to fail,
and a partial one is indistinguishable from a correct one); read the mapping the
compiler already forces to be exhaustive rather than inferring one from
proximity; and **a guard whose answer depends on the event it runs under is not
a guard**. `docs/adding-a-xeus-kernel.md` is the runbook.

The channel is **`emscripten-forge-4x`**. The older `emscripten-forge-dev` alias
serves the 3x (emscripten 3.x ABI) channel, which stopped receiving builds of
any kind on 2026-04-09 — frozen, not merely older. Do not point the env file
back at it.

Anything a student imports must be baked into the matching env: the editor's CSP is
`connect-src 'self'`, so there is no runtime pip/piplite escape hatch and a
missing package is an ImportError with no recovery. The Python set is currently
numpy / pandas / matplotlib / scipy / sympy / scikit-learn / statsmodels / PIL;
the R side is the tidyverse core (dplyr, tidyr, readr, stringr, tibble, purrr,
forcats).

**The kernel environments are checked at authoring time, and the check reads
the VENDORED bytes, never the environment YAML.**
Since browser grading moved onto this env, saving a browser-graded `.py` whose
imports the kernel cannot satisfy is rejected at the write
(`PythonImportGuard`, wired into the web create/update handlers, `PUT /suite`,
and MCP `author_script`) — which matters because instructor validation is graded
by the *native* worker on a full CPython, so such a test validates green and then
fails for the first student who submits. The available set comes from
`importable-modules.json`, derived from `kernel_packages/*.tar.gz` by
`scripts/derive-kernel-modules.py`. Adding a name to the env file changes
nothing until `build-jupyterlite.sh` runs, so a check derived from the env file
would accept imports the shipped kernel cannot serve — the exact failure it
exists to prevent. Reading the tarballs also means there is no
distribution-name-to-import-name table to maintain. The check applies to
browser-graded assignments only (worker grading runs a real interpreter) and
resolves every ambiguity toward reporting nothing, since a false positive blocks
an instructor from saving with no self-service fix. `KernelImportGuard` dispatches on file
extension; R is scanned by `RLibraryScanner` for `library()`/`require()`/`::`.
It declines `.lua` on purpose: emscripten-forge ships no Lua library packages,
so the `chickadee-lua` inventory is empty and a guard against it would reject
every `require`, starting with the `require("test_runtime")` that opens every
generated Lua test.

**A kernel env has TWO costs, and they fall on different people. Be sparing.**
*Boot* — fetching and mounting the whole env — is paid by everyone on every
notebook open and every browser-graded submission, whether or not they touch the
package. *Import/attach* is paid only by a script that uses it, but is charged
against the default **10-second** per-test limit. Measured in real kernels:

| | R | Python |
|---|---|---|
| boot | ~5-10s (52-91 MB; single runs, noisy) | ~8-10s (85 MB) |
| worst single import | `ggplot2` **193s**, `lubridate` 32s | `scikit-learn` **10.8s**, `sympy` 5.9s, `pandas` 4.8s |

Attach costs are **not independent**: the R tidyverse shares a dependency graph,
so whichever package attaches first pays for all of it (~26s cold, ~58s for the
set) and the rest come cheap. `ggplot2` and `lubridate` are excluded from the
default R env on that basis despite solving fine; `scikit-learn` already exceeds
the default limit in Python. `Tools/browser-grading-smoke` prints per-package
timings and asserts every declared package actually loads — measure there rather
than reasoning about package counts, and treat single boot numbers as a trend
only.

Building the kernels needs **micromamba on PATH plus network to
repo.prefix.dev**. This was long documented as something *CI cannot do*, and
that was simply **wrong** — a hosted runner has unrestricted network and
micromamba is a single ~7 MB download. Re-vendoring is now a workflow:
`.github/workflows/revendor-kernels.yml`, on demand or when a PR changes an
environment file. It does not run unattended, because the output is ~100 MB of
content-hashed binary assets and an automatic rebuild would bury unrelated work
in unreviewable diffs.

That false belief had a cost worth remembering. Adding a name to
`environment-*.yml` changes nothing until the kernel is rebuilt, so
"maintainer-machine only" meant env files drifted from the shipped bytes:
scipy/sympy/scikit-learn/statsmodels were declared, announced in a changelog,
and absent from the kernel — an unrecoverable `ImportError` waiting for the
first student who imported one. Every existing guard compared the vendored tree
to *itself*, so none of them could see it.
`scripts/check-env-vendored-sync.sh` is the one that compares **declared intent
to shipped bytes**, costs two file reads, and fails the PR pointing at the
workflow.

The committed `Public/jupyterlite/xeus/` bytes remain authoritative for every
other job (`scripts/check-xeus-vendored.sh` guards their integrity; the
reproducibility check excludes that path) — the rebuild is a deliberate act, not
part of the normal build.

**The vendored `pyodide-http` is patched, and must stay patched.**
`xeus-python → xeus-python-shell-lite → pyodide-http` is an unavoidable
dependency chain, and `pyodide-http` selects a Pyodide-specific streaming
implementation whenever `crossOriginIsolated` is true. It is not pyjs-compatible,
so un-patched the kernel never leaves `kernel_starting` on an isolated engine and
the editor sits on "Kernel Connecting" forever.
`scripts/patch-xeus-python-http.py` (run from `build-jupyterlite.sh`, asserted by
`check-xeus-vendored.sh`) forces the library's own XHR fallback on every engine.
The guard matters more than usual because this failure is invisible in the
JupyterLite REPL (no Drive-backed file, so no HTTP call) *and* on WebKit (not
isolated, so it takes the fallback anyway) — only isolated engines hit it.

**Synchronous stdin uses a different transport per engine — check the
middleware, not the static config.** `input()` works on both, but not the same
way, and reading `Tools/jupyterlite/jupyter-lite.json` alone gives the wrong
answer:

| engine | isolation | stdin transport |
|---|---|---|
| Chromium / Firefox | isolated (`COEPMiddleware`) | `SharedArrayBuffer`; service worker disabled as redundant |
| WebKit (Safari) | **non-isolated on purpose** | **service worker**, which `JupyterLiteConfigFlagMiddleware` re-enables *per request* for this engine |

So "the service worker is disabled" is true of Chromium only. Both paths are
covered by a blocking `SMOKE_KERNEL=xpython` probe in `editor-smoke.yml`, run on
both engines because the transports fail independently.

---

## Vendored browser libraries

jszip and CodeMirror are vendored under `Public/` rather than pulled from
third-party CDNs at runtime, so student / instructor IPs aren't leaked to
`cdn.jsdelivr.net` and `esm.sh` on every page load (FIPPA / PIPEDA concern
surfaced in the v0.4.171 audit). The editor kernels are vendored under
`Public/jupyterlite/xeus/` for the same reason.

```
Public/vendor/jszip.min.js       — jszip the browser runner uses for zip extraction
Public/vendor/codemirror.js      — bundled CodeMirror 6 ESM
Public/vendor/xeus-bootstrap.js  — mambajs slice that boots a xeus kernel
Public/vendor/xeus-unpack.wasm   — untarjs unpacker the bootstrap drives
```

**Pyodide is gone (v0.5.19).** `Public/pyodide` was ~465 MB of vendored bytes;
`check-pyodide-parity.sh`, `add-pyodide-extras.py`,
`Tools/vendor/pyodide-extra-packages.json`, `patch-pyodide-kernel.py`, the
nb_mypy/astor wheels and the `jupyterlite-pyodide-kernel` federated extension
went with it. Every editor kernel and every browser grader is xeus.
`verify-jupyterlite.sh` fails if any `pyodide` federated extension or plugin
setting reappears, because re-adding the kernel means re-vendoring that payload
and restoring its CSP allowances.

**Two things the retirement did NOT deliver, both measured:**

- **`'unsafe-eval'` cannot be narrowed to `'wasm-unsafe-eval'`.** The plan
  assumed Pyodide was the only thing needing it. It is not: with Pyodide fully
  removed, `wasm-unsafe-eval` leaves JupyterLab unable to activate its plugins —
  the editor loads, reports `crossOriginIsolated`, fetches both kernel manifests,
  then never renders a console. Restoring `'unsafe-eval'` with no other change
  makes the same smoke pass. JupyterLab compiles JSON-schema validators at run
  time. Do not retry without a plan for that.
- **Kernel packages still revalidate on every boot.** They are `no-cache`
  because conda filenames are stable across an in-place patch
  (`patch-xeus-python-http.py` rewrites bytes under the same name), so immutable
  caching would pin an unpatched copy — the #574 failure class. Making them
  immutable needs content-addressed filenames, because
  `empackLockToMambajsLock` builds package URLs as `pkgRootUrl + '/' + filename`
  inside the vendored bundle, leaving no seam for a `?v=` cache-buster.
  `/jupyterlite/xeus/` IS now on `EditorAssetFastPathMiddleware`, so those ~50
  revalidations per boot no longer each cost a Fluent session lookup.

**The waitAsync polyfill patch covers every extension, not one.**
`scripts/patch-waitasync-worker.py` (was `patch-pyodide-waitasync-worker.py`)
rewrites the `Atomics.waitAsync` polyfill's helper worker from a CSP-blocked
`data:` URL to a `blob:` one. It was scoped to the pyodide-kernel extension —
and when Pyodide was retired it turned out the **xeus** extension shipped the
identical un-patched polyfill, in the kernel Chickadee actually runs, for every
language. A per-extension scope is how that went unseen for two releases; the
glob and the matching `verify-jupyterlite.sh` assertion are how it stays seen.

---

## Voice and Register (assignment content)

Instructional prose in assignment/course content — starter notebooks, hints,
content items, generated-test messages — follows the house authoring-voice
guide below, whether authored by hand, from a Claude Code session, or by an
agent through the MCP tools. The guide is served verbatim to MCP agents in the
`initialize` instructions (`MCPServerInstructions.authoringVoice` in
`Sources/APIServer/MCP/Protocol/InitializeTypes.swift`); this section and that
constant are deliberately identical — keep them in sync when editing either.
It is the **default**, not a floor: a course's instructors can take it over on
the instructor MCP tab (`/instructor/mcp`), which seeds the editor with this
text; the edited copy then replaces it for that course's content.

```text
Authoring voice for Chickadee assignments

Assignments authored through this server are university course materials. Write
instructional prose in the register of a well-written textbook: clear, direct, and
addressed to capable students as adults. State what each task is and why it matters.
Do not narrate the student's experience of the task, and do not cheerlead.

Required:
- Use the imperative and the declarative. Write "Compute the standard deviation of
  `systolic`." rather than "Now it's time to find the standard deviation!"
- Motivate with specifics. Name what a technique accomplishes in a health-data
  context rather than reaching for adjectives like "powerful," "exciting," or
  "useful."
- Keep the register professional but not cold. Warmth belongs in how difficulty is
  acknowledged — that a concept is genuinely hard, that beginners commonly struggle
  with a particular step — not in punctuation or filler. Clear and respectful is the
  target, not stiff or joyless.

Prohibited in instructional text:
- Exclamation marks.
- Emoji.
- Second-person emotional narration: "Now it's time to…", "That's all there is to
  it", "Your turn!", "Don't worry".
- Chatty parentheticals and winking qualifiers: "(reasonably) easy (with practice)".
- Vague enthusiasm as motivation: "incredibly powerful", "super useful".

Example.
Before: "A tradition in computing is to write 'Hello, World!' as your first program.
That's all there is to it!"
After: "By convention, the first program written in a new language prints a fixed
greeting. The example below does so in R."
```

---

## Coding Conventions

- Swift 6, strict concurrency. No `@unchecked Sendable` except on a Fluent
  `Model` class, where the reason is always the same (Fluent's property
  wrappers are what the compiler cannot check). Use an actor or a `Mutex`
  instead. `scripts/check-unchecked-sendable.sh` fails `format-lint` on any
  other site, with or without a comment.
- `async/await` throughout. No completion handlers.
- Actors for any shared mutable state (`WorkerSecretStore`, `WorkerActivityStore`,
  `LocalRunnerAutoStartStore`, `LocalRunnerManager`).
- All models in `Core/` must be `Codable`, `Sendable`, and have no Vapor imports.
- Error types are explicit enums, not `String` or generic `Error` where avoidable.
- No force unwraps except in tests.
- Optionals are preferred over sentinel values (no `-1` for "missing").
- File names match the primary type they contain.
- One type per file unless the types are trivially small and closely related.
- Formatting is enforced by `swift-format` in CI (`.swift-format` at repo root).
  Run `scripts/format.sh` before committing, or `scripts/lint.sh` to check
  without modifying.
- Quality rules (force unwraps, `.filter{}.first` antipatterns, oversized
  functions, etc.) are enforced by SwiftLint (`.swiftlint.yml` at repo root,
  delivered via the `SwiftLintPlugins` SwiftPM dependency — no separate
  install). Run `scripts/swiftlint.sh` to check. The two tools are
  complementary: swift-format owns formatting, SwiftLint owns correctness;
  overlapping rules are disabled in `.swiftlint.yml`. CI enforces SwiftLint
  as a step in the `format-lint` job (alongside `scripts/lint.sh`).
  `scripts/swiftlint.sh` passes `--strict` (every reported issue, warning
  or error, fails the build), keeping the codebase at zero violations
  going forward. If a structural-rule warning threshold (e.g.
  `function_body_length` at 100 lines) starts causing legitimate
  friction, raise the threshold in `.swiftlint.yml` rather than dropping
  `--strict`.

---

## UI / Stylesheet Conventions

The web UI is Leaf templates + one stylesheet (`Public/styles.css`). The
render tests assert pages *render*, not how they look, so the following
invariants are enforced statically by `scripts/check-styles.sh` (wired into
the `format-lint` CI job) — keep them green:

- **No inline `style=""` in templates** except a JS-toggled `display:none`
  initial state, or a CSS custom-property assignment (e.g.
  `style="--filter-width:220px"`). Everything else belongs in a class.
- **Shared styling lives in `Public/styles.css`;** page-unique styling lives
  in a page-local `<style>` block with **role-named** classes (e.g.
  `.section-header`, not `.mt-1`). Don't paste the same rule into multiple
  templates — hoist it to the global sheet. (`scripts/check-styles.sh` fails
  if a page block re-defines a global selector or the same selector appears
  in more than one page block; `.main` is an allowlisted page override.)
- **Every `var(--x)` must resolve.** Declare new custom properties in
  `styles.css` (with a `prefers-color-scheme: dark` value if it's a colour).
  Never reference an undeclared var, and never use a hardcoded colour
  fallback `var(--x, #hex)` — define the var so it routes through the palette
  and adapts to dark mode. (`scripts/check-css-vars.sh` enforces both.)
- **No native `alert()` in templates** — surface errors with the inline
  `.form-error` banner pattern. The guard ratchets a baseline down only.
- **Design tokens are mandatory** (`scripts/check-design-tokens.sh`): raw
  colour literals (`#hex`/`rgb(a)`/`hsl(a)`) may appear only as `--token:`
  declarations in `styles.css` (palette + dark-mode mirror); every
  `font-size` uses the `--text-*` type scale (em/`inherit` allowed for
  relative sizing); every `border-radius` uses the `--radius-*` scale
  (`0`/`50%`/multi-corner allowed); every rem component of
  `padding`/`margin`/`gap` sits on the shrink-only spacing lattice
  (`SPACING_STEPS`); pop-out shadows use `--shadow-pop`. Pick the nearest
  step — never introduce a new literal. Full principles, the token tables,
  and the component vocabulary live in [docs/ui-design.md](docs/ui-design.md).
- **Pages follow a named archetype** (docs/ui-design.md "Page archetypes"):
  tab bars are the `_admin-tabs`/`_instructor-tabs` partials, flash banners
  render only through the `_flash` partial (ARIA roles included), sections
  are `.page-section`, page headers are `.page-titlebar`. Assemble new pages
  from the component vocabulary — the page `<style>` total is a shrink-only
  ratchet (`PAGE_STYLE_BASELINE`), so a private re-implementation of a
  shared concept fails CI on growth.
- **Start a new page by copying its archetype's exemplar.** Every archetype
  row names one — `alerts` / `instructor-mcp` / `admin-user` / `account` /
  `register` / `assignment-edit` / `workbench`. The component vocabulary and
  the idiom table say what to *reach for*; this is the only rule naming a
  **starting artifact**, and it exists because the skeleton column describes
  a shape without providing one, so an author imitating whichever page they
  opened inherited its private habits too. `PageArchetypeTests` reads the
  exemplar column out of the table (so doc and guard cannot drift) and
  re-checks each exemplar against its own row — the exemplars and **nothing
  else**; no page fails for not being one. Do not answer this with a
  scaffold generator: a `new-page.sh` is a second source of truth that
  drifts from the exemplar the moment either moves.
- **Every assigned class name must resolve to a stylesheet rule**
  (`scripts/check-class-resolution.sh`). Behaviour-only hooks take the `js-`
  prefix (pre-existing ones live in a shrink-only allowlist). Leaf-
  interpolated families (`status-…` etc.) are pinned by
  `StatusClassStylesheetTests` iterating the enum instead.
- **JS makes no styling decisions** — it toggles classes or sets a custom
  property (`--wb-left-width` pattern). Two absolute rules: no colour or
  typography property written via `.style`, and a `style="…"` in a JS-built
  HTML string may only assign a custom prop or `display:none`. The residue
  (computed geometry, `setProperty`, `.style` reads) ratchets down only
  (`JS_STYLE_DECISION_BASELINE`).
- **The nginx maintenance page mirrors the palette by value** —
  `scripts/check-maintenance-palette.sh` fails when a colour there stops
  existing in `styles.css`.
- **Do not invent a second way to say something the UI already says.** The
  token guards prove a value is on the palette and the class-resolution guard
  proves a name has a rule; neither can see a component that duplicates one in
  the vocabulary under a different name, and until v0.5.137 the *global* sheet
  had no budget at all — so the cheapest way to add a second spelling was to
  skip the page block and put it in `styles.css`. That is how a pair of
  estimate chips shipped as chips in the changelog, the commit message and
  their own CSS comment, under a name sharing nothing with `.chip`, past a
  fully green `format-lint`. `scripts/check-ui-vocabulary.sh` now prices it:
  the count of global classes [docs/ui-design.md](docs/ui-design.md) does not
  name is a shrink-only ratchet, `cursor` and `text-decoration` values are a
  closed **affordance registry** (a new one is a rulebook edit, not a CSS
  line), and hover text written in a template is capped at 20 words.
- **Chrome is not prose, and a tooltip is not a disclosure.** Labels and chips
  are two-or-three-word noun phrases; a `title` is one phrase; a note under a
  control is one sentence; **anything longer goes in `docs/` and the UI links
  there**. A hover title is invisible on touch, unsearchable, and read
  inconsistently by screen readers, so it may never hold the only copy of
  something a reader needs. The rules and the cheapest-first table of
  interaction idioms — on the page → `<details>` → row popover → modal — are
  in ui-design.md under "Interaction idioms" and "UI copy". The script only
  reads templates, so prose assembled in Swift or JS needs its own budget
  assertion (`datasetEstimateTitleWordCap` is the worked example).
- **Run the `ui-review` agent on any change touching `Resources/Views/`,
  `Public/styles.css`, or a page-wiring `Public/*.js`.** It reviews the layer
  the guards structurally cannot: whether a construct duplicates the
  vocabulary, whether the idiom is the lightest that fits, and whether the
  copy is at house length. Green guards are necessary, not sufficient — every
  style regression so far has been mechanically legal.

  **This is unconditional and needs no confirmation.** The agent is checked in
  at `.claude/agents/ui-review.md`, so every Claude Code session has it. Run it
  as part of doing the work, the same way you run `scripts/check-styles.sh` —
  do not ask whether to, do not offer merging without it as an option, and do
  not skip it because a general instruction elsewhere discourages spawning
  agents. CI runs the same brief on every pull request that touches those paths
  (`.github/workflows/ui-review.yml`): it posts the report on the PR and the
  job fails on a `changes requested` verdict, so a session where the agent
  cannot run needs no note in the PR — the workflow is the review, and its
  findings are handled like any other bot finding. The workflow needs one
  repository secret (`ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN`) and
  passes with a warning when neither is set. A UI change that has not been
  through `ui-review`, by either route, is not finished.

Run `scripts/check-styles.sh` locally before pushing UI changes (it runs all
of the above — same as the CI `format-lint` job). The visual-regression
harness (`Tools/visual-regression/`, page list in `pages.mjs` shared with
the axe scan) covers one page per archetype; a page captured without a
committed baseline bootstraps loudly — commit the CI capture in the same PR.

---

## Testing Conventions

- **Framework: Swift Testing only.** Every Swift test (plus the `.mjs`
  frontend tests in `Tests/BrowserRunnerJSTests/`, run by `node --test`) has
  been on Swift Testing since the migration completed (PRs #597–#608). `scripts/no-new-xctest.sh`
  blocks any new `import XCTest` under `Tests/`. The nightly
  `test-coverage.yml` run measures line coverage over all four targets
  (87 % on 2026-09-20) against an 80 % floor.
- **Approved Swift Testing vocabulary.** `@Suite`, `@Test`, `#expect`,
  `#require`, `.serialized`, `.tags(...)`, `.enabled(if:)` / `.enabled { }` /
  `.disabled(if:)`, `@Test(arguments:)`, `#expect(processExitsWith:)` (an exit
  test: the body runs in a child process, for a path that ends the process or
  writes process-global state such as `setenv` — see
  `WedgeWatchdogAbortTests` and the WorkerTests env tests; the body cannot
  capture `self`, so the helpers it calls are static or file-scope), and
  `.timeLimit(.minutes(n))` (put it on any suite
  that spawns subprocesses or awaits daemons/network, so a stall fails
  with a named test instead of holding the CI job to its 20-minute kill —
  see the #1139 postmortem in `docs/ci-flakiness.md`). Avoid
  `CustomExecutionTrait`, hand-rolled trait types, and anything still
  labelled experimental in the Swift Testing source — the API is still
  evolving.
- **Struct vs class suites.**
  - **`@Suite struct Foo`** — default. Per-test instance is cheap.
  - **`@Suite final class Foo`** with `init()` / `deinit` — when the
    suite needs expensive shared state per-test instance (temp
    directories, Vapor app fixtures). For Vapor apps, store `let app`
    and wrap each `@Test` body in `try await withApp(app) { _ in ... }`
    so teardown is deterministic (`withApp` runs the full
    `tearDownTestApp`: shutdown plus removal of the app's temp
    directories and sqlite-kit's fake-memory database file — #1298);
    the next test's `init` builds a fresh app.
- **`with*App` helpers** for DB-backed suite clusters
  (`withWebRoutesApp`, `withAssignmentRoutesApp`, `withPatternFamilyFixture`).
  See `Tests/APITests/WebRoutesHelpers.swift` etc. for the pattern.
- **`.serialized` on DB- or env-touching suites.** Swift Testing runs
  tests in parallel within a suite by default; `.serialized` gates
  within-suite parallelism. For cross-suite serialization (e.g. tests
  that mutate process env vars), use the actor-backed
  `withAsyncEnvLock { ... }` in `Tests/APITests/EnvTestLock.swift` or
  `withMockURLProtocolLock { ... }` in
  `Tests/WorkerTests/Support/WorkerTestSkip.swift`.
- **No force unwraps in tests.** The corpus cleanup finished in the 0.5
  pass — `Tests/.swiftlint.yml` no longer exempts `!` / `try!` / `as!`
  (its only remaining relaxation is `type_body_length`). Use
  `try #require(value)` — the idiomatic Swift Testing replacement for
  `XCTUnwrap`.
- **Skipping a test at runtime.** Don't use `Issue.record` to skip — it
  records a failure. A condition the host may not meet (an interpreter on
  PATH, a Python module, CI itself) is a `ConditionTrait` on the test:
  `@Test(.requiresLua)`, `@Test(.ciOnly)`, `@Test(.requiresRscript)`, each a
  `static let` built with `.enabled("requires lua on PATH") { … }`. The
  traits more than one file needs live in one `HostConditionTraits.swift` per
  test target (`WorkerTestSkip.swift` in WorkerTests): `.ciOnly` and one
  `.requires…` per interpreter or tool (`Rscript`, `Octave`, `Gpp`, `Javac`,
  `Racket`, `Lua`, `Python3`, `ZipTools`, `Sandbox`, `Make`). Add a new one
  there, not in a suite. The probes behind them
  (`cachedToolIsAvailable`) are in `ChickadeeTestSupport`, which also holds
  `IssueRecorded` and `testURL` for all three targets. Swift Testing then
  reports the test as skipped with that reason, in the log and in the xUnit report, and
  `scripts/check-no-skipped-tests.sh` fails every CI test lane on any skip,
  because the CI image carries every interpreter. That closed the silent-skip
  trap: a `guard condition else { return }` kept a lane green having executed
  nothing in a language, three times. The guard form survives only where a
  trait cannot express the condition — per-argument availability in a
  parameterized test, or a body whose first half runs without the tool — and
  each such site says so in a comment. "Test setup is broken" is still
  `throw IssueRecorded("...")`, which fails with a clear message.
- **Pattern references.**
  - Standalone struct suite:
    [Tests/APITests/COEPMiddlewareTests.swift](Tests/APITests/COEPMiddlewareTests.swift)
  - Class suite with sync `init`/`deinit`:
    [Tests/APITests/ZipArchiverTests.swift](Tests/APITests/ZipArchiverTests.swift)
  - Class suite with stored `app` + per-test `withApp`:
    [Tests/APITests/AdminRoutesTests.swift](Tests/APITests/AdminRoutesTests.swift)
  - `with*App` helper-driven suite:
    [Tests/APITests/WebRoutesIndexTests.swift](Tests/APITests/WebRoutesIndexTests.swift)
  - Parameterized + `try #require`:
    [Tests/APITests/MCP/MCPModeScopeContractTests.swift](Tests/APITests/MCP/MCPModeScopeContractTests.swift)
  - Worker-side class suite:
    [Tests/WorkerTests/DirectorySizeBytesTests.swift](Tests/WorkerTests/DirectorySizeBytesTests.swift)

---

## Versioning

Follows Semantic Versioning in the `0.y.z` phase. The version lives in the
`VERSION` file + `ChickadeeVersion.current` in Core. What each slot means
here — patches never remove compatibility surface; minors are deliberate
era/removal boundaries; majors are deployer-gated — is documented in
"What the numbers mean while we are 0.y.z" in
[docs/release-process.md](docs/release-process.md).

**Versions are assigned at merge time — do NOT bump them in a PR.** A PR must
not touch `VERSION`, `Sources/Core/ChickadeeVersion.swift`, or `CHANGELOG.md`
(hand-editing those three to a hardcoded next number is what used to make every
concurrent PR conflict). Instead:

1. Add **one fragment** under `changelog.d/` describing the change
   (see `changelog.d/README.md`). Preview with
   `scripts/assemble-release.sh --dry-run`.
2. On merge to `main`, `.github/workflows/auto-release.yml` computes the next
   version, folds the fragments into `CHANGELOG.md`, bumps `VERSION` +
   `ChickadeeVersion`, commits `chore(release): vX.Y.Z`, and pushes the tag —
   which triggers `release.yml` + the tag build in `docker-build.yml`.

**Auto-release is patch-only by construction** — fragment categories carry no
bump semantics, so no merge can ever produce a minor/major bump. Cutting one
(e.g. 0.5.0) is a deliberate manual step: `scripts/assemble-release.sh
--version X.Y.0` committed as `chore(release): vX.Y.0` (that prefix suppresses
the redundant auto-release) and tagged from a human account. See "Cutting a
minor (or major) release" in
[docs/release-process.md](docs/release-process.md).

Full details, plus how to enable the optional merge queue, are in
[docs/release-process.md](docs/release-process.md).

---

## Deployment & CI/CD (production)

**Prod is full CI/CD with zero-downtime deploys — a green merge to `main`
reaches production on its own.** The pipeline:

1. Merge to `main` → `auto-release.yml` tags `vX.Y.Z` and `docker-build.yml`
   publishes `ghcr.io/jimwallace/chickadee:latest` (the build does **not**
   publish a per-release `:X.Y.Z` image tag — only `:latest` and
   `:sha-<commit>`, because auto-release pushes the tag with `GITHUB_TOKEN`,
   which by design can't trigger the tag build).
2. A host-side daemon, **`chickadee-deployer`** (systemd;
   `deploy/chickadee-deployer.sh`), polls GitHub Releases and **blue-green-deploys
   each new release automatically** via `scripts/bluegreen-deploy.sh`: a new
   "color" container boots beside the live one, is health-gated, then the host
   nginx upstream is flipped to it (zero dropped requests), the old color is
   drained and kept for instant rollback. Non-major bumps deploy unattended;
   **major bumps are held for human approval** (SemVer gate). Each deploy is
   snapshotted first and auto-rolls-back if the new version degrades after cutover.

**Implication for working here:** once a change is merged and CI is green, you
can **rely on it being deployed to prod** within ~10–15 min (image build + the
daemon's poll). No SSH, no manual deploy step.

**Verify a fix is live via the admin diagnostics MCP** (`Chickadee_Admin`,
read-only): `get_deployment_info` (the running version — confirms your release
shipped), `get_deploy_status` / `get_deploy_history` (the daemon's state + recent
deploy/rollback events), and `list_runners` / `get_health_alerts` / `query_logs`
/ `get_browser_diagnostics` to confirm the fix's *behaviour*. If a brand-new
admin tool isn't visible, reconnect the MCP client to pick up the new catalog.

**Deploy control is host-side, by design.** The admin-MCP deploy tools are
strictly read-only; pause / approve-a-major / rollback are operator actions on
the host (`systemctl`, or writing `command.json` in the deploy state dir). The
app container never holds the Docker socket.

Full design, runbook, and host steps:
[docs/zero-downtime-deploy.md](docs/zero-downtime-deploy.md).

---

## Current State

**The 0.4 series is closed.** v0.5.0 marks the end of the first full course
offering run on Chickadee. The system is a working client–server autograder:
Python, R, Lua, Octave, C++, Racket and Java assignments; browser (xeus/wasm)
and native worker grading that share one RunnerCore; per-student
personalization; pattern-generated test families (10 kinds) and notebook checks
(10 kinds); achievements; student slip days; per-course roles; BrightSpace grade
sync (awaiting UW IST prod credentials); an MCP authoring surface of 57 tools
plus a read-only admin-diagnostics MCP of 19 (`MCPToolCatalog.live` in
`Sources/APIServer/MCP/Transport/MCPServerRegistration.swift` is the source of
truth for the count); OIDC SSO; and zero-downtime auto-deploys. The 0.4 arc is
summarised at the top of `CHANGELOG-0.4.md`. The 0.5-boundary cleanup is in the
0.5.0 entry of `CHANGELOG.md`. Every browser grader and every editor kernel is
xeus (#1271, done); the measurements are in `docs/archive/xeus-python-grading-*`.

Instructor validation is a `kind == .validation` submission, graded by the
**native worker** (`WorkerJobRoutes.collectClaimCandidates`). It never runs a
kernel. There is no `assignment-validate.js`.

**Leaf templates: rules that fail silently.** A render test proves that a
template resolves, not that it resolves right. The evidence is in
`docs/leaf-decomposition-review.md` §0. `scripts/check-leaf-semantics.sh`
enforces the first three rules.

- **No Leaf tag syntax in a template comment or in template prose.** Leaf's
  lexer has no notion of an HTML comment. In a comment, a bare structural tag
  name fails at render (`extend only supports one or two parameters []`), a
  field interpolation prints the real value, and a complete include resolves.
  Commenting a tag out does not disable it. Write "the extend" instead.
- **Leaf has no line-comment syntax.** A `#` followed by a slash is raw text,
  so the "comment" prints into the page. Use an HTML comment.
- **Use the `count` tag, not `.isEmpty`.** Leaf resolves no Swift properties,
  so `rows.isEmpty` on an array is nil: the plain form never fires and the
  negated form always fires. Write `#if(count(rows) == 0)` or
  `#if(count(rows) > 0)`. Two struct properties are allowlisted in the script.
- **The sub-context include takes a bare second parameter:**
  `extend("_partial", subObject)`. The labelled `with:` form does not lex.
- **A scanner that cannot tell markup from prose about markup matches its own
  documentation.** This shipped twice in drift guards. Parse structure, and
  describe forbidden syntax instead of quoting it.

**Feature backlog:** continued personalization / notebook-check expansion
(e.g. per-student refs in pattern kinds beyond the three equality kinds);
pattern kinds beyond the ten shipped (`PatternKind`); multi-provider SSO
testing beyond UWaterloo DUO; refresh-token handling; gamification expansion
(leaderboards, more badges beyond First-Try Perfect).

---

## What Not To Do

- Do not import Vapor in `Core/`.
- Do not add `CouldNotRun` as a `TestStatus`. Build failures are
  represented at the collection level (`buildStatus: "failed"`).
- Do not write a runner JSON protocol — the runner interprets exit codes directly.
- Do not add per-language build strategies in Swift — test suites are plain shell scripts.
- Do not use `@unchecked Sendable` outside a Fluent `Model` class
  (`scripts/check-unchecked-sendable.sh` enforces it).
- **Do not introduce new environment variables.** This is a standing rule, not a
  per-case judgement, and it applies to the server (`AppConfig`) and the runner
  (`RunnerDaemonConfig`) alike. Every new env var is another thing that must be
  set correctly in `.env.example`, `docker-compose.yml`, the systemd units, the
  deploy runbook and the operator's head — and one that is silently absent
  everywhere it was not added, which is the failure mode env vars are worst at
  surfacing. Configure new runner behaviour with a **CLI flag** on
  `chickadee-runner` (as `--sandbox` and `--max-jobs` do), derive it from
  something already known, or make the code detect the condition at runtime.
  If a new variable ever looks genuinely unavoidable, ask first — do not add it
  and mention it afterwards.

---

## Reference Material

One line per document. Each document holds its own rules and evidence.

- `docs/architecture.md` — system architecture: targets, grading pipeline, auth, sandboxing, MCP, deployment
- `docs/lti-1-3.md` — LTI 1.3 tool support, additive to everything above, and why a launch opens a new window
- `docs/github-submissions.md` — submitting from GitHub and course repositories, with the "What reaches GitHub" data table
- `docs/brightspace-setup.md` — BrightSpace grade-sync operator runbook
- `docs/operational-diagnostics.md` — observability tables, log events, metrics endpoint, ops runbook
- `docs/zero-downtime-deploy.md` — blue-green deploys, the `chickadee-deployer` daemon, read-only deploy oversight
- `docs/runner-capability-profiles.md` — runner capability matching, the language gate, `minimumRunnerVersion`
- `docs/swift-toolchain-upgrades.md` — the semi-annual Swift upgrade: where the pins live, its traps, the verification gauntlet
- `docs/runner-wasm-migration.md` — the plan that made RunnerCore one grading core for the worker and the browser
- `docs/runner-wasm-swift-6-4-review.md` — what the Swift 6.4 move changed for the browser wasm, measured
- `docs/personalization-phase1.md` — the per-student seed contract (`CHICKADEE_ASSIGNMENT_SEED`)
- `docs/inputs.md` — global and section inputs: literals, `=` expressions, `$name` references
- `docs/personalization-pattern-families.md` — per-student values in pattern families
- `docs/personalization-eval-runtime.md` — where, and in which language, personalization expressions run
- `docs/archive/xeus-python-grading-spike.md`, `docs/archive/xeus-python-grading-migration-plan.md` — the finished Pyodide-to-xeus migration (#1271), measured; the live state is in the JupyterLite section above
- `docs/cpp-support.md` — first-class C++: upload-only, the `.sh` wrapper, single-TU inclusion, the literal refusals
- `docs/cpp-assignment-language-decision.md` — the C++ memo, superseded in part; it still governs why C++ has no browser kernel
- `docs/authoring-parity.md` — what a non-Python author can and cannot do, and which gaps are correct refusals
- `docs/multi-language-audit.md` — the Lua-to-Racket audit, with a "Status at merge" section
- `docs/java-support.md` — first-class Java: why upload-only, the `.sh` wrapper, the three measured traps
- `docs/program-io.md` — the `programIO` pattern kind: stdin in, stdout graded, per language
- `docs/adding-a-xeus-kernel.md` — the runbook for a new language: both halves, the compiler-invisible list, the parity checklist, the per-language postmortems
- `docs/kernel-boot-cost.md` — what a kernel boot costs, and on-demand package loading
- `docs/r-support.md` — first-class R: runtime, personalization, renderers
- `docs/language-declaration.md` — language is declared, never inferred, and the per-site `?? .python` table
- `docs/language-handling-review.md` — design review of language dispatch, scored against the real third language
- `docs/ui-consistency-audit.md` — the 2026-08 widget-layer UI audit and its consolidation plan
- `docs/multi-course-roles.md` — per-course roles (#417): enrollment-row `CourseRole`, gates, staff invites
- `docs/assignment-versioning.md` — content version history: capture, read, restore
- `docs/slip-days.md` — student-managed slip days (#1228)
- `docs/course-terms.md` — course year and term, the two course-code resolvers, cloning for a new term
- `docs/solution-visibility.md` — the post-deadline solution reveal and its slip-day ceiling
- `docs/datasets.md` — per-student datasets (#1083)
- `docs/admin-mcp.md` — the read-only admin diagnostics MCP surface
- `docs/compliance/` — the UW approval package: student-data audits, tool and data-flow inventories
- `docs/collaborative-class-assignments.md` — contribution assignments and class goals; opens with a Status table
- `docs/class-activities.md` — leaderboards, bots, round robins, hills and brackets (#1508); opens with a Status table
- `docs/unlockable-labs.md` — assignment prerequisites and sticky per-student unlocks
- `docs/student-wardrobe.md` — cosmetic choices for the avatar, kept apart from earned status
- `docs/student-avatars.md` — generated avatars and the per-course pseudonymous handle
- `docs/browser-freeze-investigation.md` — the 2026-08 editor freeze, its root cause, the freeze tracer
- `docs/ci-flakiness.md` — CI flake families; start here before chasing a red check on an unrelated PR
- `docs/grading-integrity.md` — what a submission can do to its own grade today, the decisions, and the four-phase plan (#2223)
- `docs/archive/` — finished-era documents; nothing there describes current behaviour
- `CHANGELOG.md` — release history from 0.5.0; `CHANGELOG-0.4.md` — the 0.1.0–0.4.x history
