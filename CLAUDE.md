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

**The authoring editors ([docs/authoring-editors.md](docs/authoring-editors.md)).**

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

Chickadee embeds JupyterLite at `Public/jupyterlite/` for in-browser notebook
editing. The config is in `Tools/jupyterlite/`. `Public/jupyterlite` is generated
output and is checked in. The measurements and the history behind each rule
below are in [docs/jupyterlite.md](docs/jupyterlite.md).

- **Every vendored kernel is a xeus kernel, one environment each**
  (`Tools/jupyterlite/environment-<language>.yml`). The environments are
  separate on purpose, because a kernel fetches its whole environment at boot.
  `check-xeus-vendored.sh` asserts that they stay distinct. A vendored kernel
  appears in the editor's picker, so a language that can be authored must be
  one that can be graded.
- **The channel is `emscripten-forge-4x`.** The `emscripten-forge-dev` alias
  serves the frozen 3x channel. Do not point an environment file at it.
- **A student can import only what the environment contains.** The CSP is
  `connect-src 'self'`, so there is no runtime install.
- **Import checks read the vendored bytes, never the environment YAML.**
  `KernelImportGuard` refuses a browser-graded script whose imports the kernel
  cannot satisfy, from `importable-modules.json`.
- **A name in an environment file changes nothing until the kernel is rebuilt.**
  Re-vendor with `.github/workflows/revendor-kernels.yml`.
  `check-env-vendored-sync.sh` compares the declared packages with the shipped
  bytes.
- **A package has two costs: boot, paid by everyone, and attach, charged to the
  10-second test limit. Be sparing.** Measure with `Tools/browser-grading-smoke`.
- **A guard derivation must assert its own completeness, and a guard whose
  answer depends on the CI event it runs under is not a guard.** The
  `chickadee-*` glob in `build-jupyterlite.sh` still fails open for a kernel it
  does not know.
- **The vendored `pyodide-http` and the waitAsync polyfill worker are patched,
  and must stay patched** (`scripts/patch-*.py`, asserted by
  `check-xeus-vendored.sh` and `verify-jupyterlite.sh`).
- **Synchronous stdin uses a different transport per engine.** Read the
  middleware, not `jupyter-lite.json`: Chromium and Firefox are isolated and use
  `SharedArrayBuffer`; WebKit is not isolated and uses the service worker.
- **jszip, CodeMirror and the xeus bootstrap are vendored under `Public/vendor/`**,
  so no page load reaches a third-party CDN. Pyodide is gone (v0.5.19).
  `'unsafe-eval'` cannot be narrowed to `'wasm-unsafe-eval'`, because JupyterLab
  compiles JSON-schema validators at run time.

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

The web UI is Leaf templates and one stylesheet (`Public/styles.css`). The
render tests prove that a page renders, not how it looks, so
`scripts/check-styles.sh` enforces these rules statically in `format-lint`. The
rules, the token tables, the component vocabulary and the page archetypes are
in [docs/ui-design.md](docs/ui-design.md).

- No inline `style=""` in a template, except a JS-toggled `display:none` or a
  custom-property assignment.
- Shared styling goes in `styles.css`. Page-unique styling goes in a page
  `<style>` block with role-named classes. The page `<style>` total is a
  shrink-only ratchet.
- Every `var(--x)` resolves, with no hardcoded fallback (`check-css-vars.sh`).
- Design tokens are mandatory for colours, font sizes, radii, spacing and pop-out
  shadows (`check-design-tokens.sh`).
- Pages follow a named archetype. Start a new page by copying its archetype's
  exemplar (`PageArchetypeTests`).
- Every assigned class name resolves to a rule (`check-class-resolution.sh`).
  Behaviour-only hooks take the `js-` prefix.
- JS makes no styling decisions. It toggles a class or sets a custom property.
- Do not invent a second name for a component the vocabulary already has
  (`check-ui-vocabulary.sh`). `cursor` and `text-decoration` values are a closed
  affordance registry.
- Chrome is not prose. Text longer than one sentence goes in `docs/`, and the UI
  links there. No native `alert()`.
- The nginx maintenance page mirrors the palette by value
  (`check-maintenance-palette.sh`).
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

Run `scripts/check-styles.sh` before you push a UI change. The
visual-regression harness (`Tools/visual-regression/`) covers one page per
archetype. A page with no committed baseline bootstraps loudly: commit the CI
capture in the same PR.

---

## Subagents

The subagents are in `.claude/agents/`. Each one reports and does not edit.
- After a code change, run `test-runner`. It reports only the failing tests.
- After a change to a Leaf template, `Public/styles.css` or a `Public/*.js` file, run `ui-guard`. Run `ui-review` too.
- Before a commit, run `diff-reviewer` on the uncommitted diff. Before a push, run `lint-guard`.

---

## Testing Conventions

The reason for each rule is in
[docs/testing-conventions.md](docs/testing-conventions.md).

- **Swift Testing only.** `scripts/no-new-xctest.sh` blocks a new `import XCTest`.
  The `.mjs` frontend tests run under `node --test`.
- **Use the approved vocabulary:** `@Suite`, `@Test`, `#expect`, `#require`,
  `.serialized`, `.tags(...)`, `.enabled` / `.disabled`, `@Test(arguments:)`,
  `#expect(processExitsWith:)` and `.timeLimit(.minutes(n))`. Put a time limit on
  any suite that spawns a subprocess or waits on a daemon or the network. Do not
  use `CustomExecutionTrait`, a hand-rolled trait, or an experimental API.
- **`@Suite struct` by default.** Use a `final class` with `init` / `deinit` for
  expensive per-test state, and wrap each Vapor test body in `withApp(app)`.
  DB-backed suite clusters use the `with*App` helpers.
- **`.serialized` on a suite that touches the database or the environment.**
  Across suites, use `withAsyncEnvLock` or `withMockURLProtocolLock`.
- **No force unwraps in tests.** Use `try #require(value)`.
- **Skip with a `ConditionTrait`, never with `Issue.record`.** A bare
  `guard … else { return }` is allowed only where a trait cannot express the
  condition, with a comment that says so. The shared traits (`.ciOnly`, `.requires<Tool>`) live in one
  `HostConditionTraits.swift` per target. `scripts/check-no-skipped-tests.sh`
  fails every CI lane on any skip. A broken test setup throws
  `IssueRecorded("...")`.
- **Pattern references:** `COEPMiddlewareTests` (struct suite),
  `ZipArchiverTests` (class suite), `AdminRoutesTests` (stored `app` with
  `withApp`), `WebRoutesIndexTests` (`with*App` helper),
  `MCPModeScopeContractTests` (parameterized) and `DirectorySizeBytesTests`
  (worker class suite).

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
- `docs/jupyterlite.md` — the vendored editor and kernels: environments, import checks, re-vendoring, patches, stdin transports
- `docs/authoring-editors.md` — the suite editor, the notebook write-back, the language seed and server-side auto-compute
- `docs/testing-conventions.md` — the test rules in full, with the reason for each
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
