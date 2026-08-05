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
  classification, notebook extraction (`extractPython` / `extractR`), and the
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

**Four test tiers:** `public` (shown immediately), `release` (hidden until
deadline), `secret` (never shown), `student` (student-written tests).

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

**Assignments are Python *or* R; language is first-class (`AssignmentLanguage`).**
`AssignmentLanguage` (`.python | .r`, Core) is resolved from the manifest (any
`.R` graded script → `.r`; else an R notebook kernel in `{ir,r,webr,xr}` → `.r`;
else `.python`) and every language-specific path dispatches through it — literal
rendering (`pythonLiteral`/`rLiteral`), the per-student inputs file
(`_ck_inputs.py`/`_ck_inputs.R` via `renderInputsFile`), and the expression
driver. Personalization is evaluated **per-language on the server**:
`PersonalizationEvaluator` spawns `python3` or `Rscript` (r-base is on the
server image), preserving the property that expression source + the solution
never reach the runner. Base R has no bignum, so the seed is a deterministic
Horner-fold reduction (`RPersonalizationRuntime.chickadeeSeedRSource`, shared by
the server driver and the grading runtime so they never drift). The default is
`.python` at every call site, so existing Python bytes are byte-for-byte
unchanged. R pattern-family / notebook-check renderers and literal-globals
inlined into hand-authored `.R` scripts shipped in #1207 (v0.4.636);
`astStructure` remains the one Python-only check kind. See `docs/r-support.md`.

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

**MCP server (`Sources/APIServer/MCP/`).** Chickadee is its own MCP server *and*
its own OAuth 2.1 authorization server, so an agent (e.g. the Claude connector)
can manage course content on an instructor's behalf. Gated by `MCP_MODE`
(`off` / `read_only` / `read_write`). The server is **dual-era** (#1218): the
era is resolved *per request* — a body whose `_meta` carries
`io.modelcontextprotocol/protocolVersion` gets the modern 2026-07-28 semantics
(mandatory `server/discover`, `resultType` + server `_meta` on every result,
mirrored `MCP-Protocol-Version`/`Mcp-Method`/`Mcp-Name` header validation,
HTTP-visible protocol errors), anything else keeps the legacy `initialize`
behaviour unchanged. `initialize` negotiates only among the legacy revisions,
so a handshake client is never handed a protocol it cannot speak. See
`Transport/MCPModernTransport.swift` and `docs/mcp-2026-07-28-revision.md`. The browser OAuth flow is Authorization
Code + PKCE (S256); codes, consent tokens, and refresh tokens are stored only as
SHA-256 hashes and are strictly single-use — consumption is an **atomic
conditional `UPDATE … WHERE consumed = false RETURNING`** so concurrent
exchanges can't replay a code. Refresh tokens rotate with prior-hash theft
detection; the human's role is re-checked at consent and on every refresh.
Scopes are clamped to the mode ceiling (`MCPMode.advertisedScopes`, the single
source for discovery + DCR). Access tokens are short-lived ES256 JWTs minted by
`MCPTokenAuthority`; bearer auth + per-request scope clamping live in
`MCPBearerAuthMiddleware`. An hourly reaper drops dead OAuth rows. The consent
POST is deliberately cookie-independent (identity + CSRF ride the single-use
consent token) so it survives Safari/ITP cross-site cookie blocking.
The `initialize` instructions end with the default **authoring-voice guide**
(`MCPServerInstructions.authoringVoice` — see "Voice and Register" below).
Every course inherits that guide; a course's instructors can take it over on
the `/instructor` MCP tab, which seeds one editable box with the default and
stores the edited copy in `courses.mcp_instructions` (nil = still inheriting).
A customized course's guide **replaces** the default for that course's content
and is appended as a labelled block at initialize (`MCPCourseGuidance.swift`);
an inheriting course adds nothing, since the default is already in the base
text. Both are live MCP resources too (`chickadee://docs/authoring-voice`,
`chickadee://course/<code>/authoring-guidance` — which serves whichever guide
is in force) so agents can re-read them mid-session; the initialize copy is
frozen per connection. Advisory text only — it never alters tools, scopes, or
the admin surface.

**Pattern-generated test families (v0.4.75+).** Instructors can define a
`PatternFamily` (Core/) — one function, shared defaults, a table of cases —
and Chickadee expands each enabled case into an ordinary Python test script
at save time. Families live in `TestProperties.patternFamilies`; generated
entries in `testSuites` carry `generatedBy: <familyID>` so the raw-script edit
endpoints refuse to mutate them (you edit the family instead). Two kinds
ship: `.boundaryEquality` (single-arg equality) and `.approximateEquality`
(float tolerance, v0.4.80). Generated filenames are deterministic
(`{tier}test_{familyID}_{caseKey}.py`) and embed a `spec_hash` header so
manifest bytes change when any case changes.

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

**Assignment vanity URLs (v0.4.71).** Each assignment gets a per-course
unique slug. Student links prefer `/:courseCode/:assignmentSlug` routes while
the canonical `/testsetups/:id/submit` handlers remain active for
compatibility.

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

**stderr:** Captured verbatim as `longResult` (nil if empty).

---

## Data Models (Core/)

### TestOutcomeStatus
```swift
enum TestOutcomeStatus: String, Codable {
    case pass, fail, error, timeout
}
```

### TestTier
```swift
enum TestTier: String, Codable {
    case pub       // "public"
    case release
    case secret
    case student
}
```

### TestOutcome
Single test case result.
```swift
struct TestOutcome: Codable {
    let testName: String
    let testClass: String?          // always nil (shell scripts have no class)
    let tier: TestTier
    let status: TestOutcomeStatus
    let shortResult: String
    let longResult: String?
    let executionTimeMs: Int
    let memoryUsageBytes: Int?      // nullable until measured
    let attemptNumber: Int
    let isFirstPassSuccess: Bool
}
```

### TestOutcomeCollection
Complete result for one submission run.
```swift
struct TestOutcomeCollection: Codable {
    let submissionID: String
    let testSetupID: String
    let attemptNumber: Int
    let buildStatus: BuildStatus
    let compilerOutput: String?
    let outcomes: [TestOutcome]
    let totalTests: Int
    let passCount: Int
    let failCount: Int
    let errorCount: Int
    let timeoutCount: Int
    let executionTimeMs: Int
    let runnerVersion: String       // "shell-runner/1.0"
    let timestamp: Date
}
```

### TestProperties
Stored as `test.properties.json` inside the instructor-uploaded test setup zip.

```json
{
  "schemaVersion": 1,
  "requiredFiles": ["warmup.py"],
  "testSuites": [
    { "tier": "public",  "script": "test_bit_count.sh"  },
    { "tier": "release", "script": "test_first_digit.sh",
      "dependsOn": ["family:bmi"] },
    { "tier": "public",  "script": "publictest_bmi_01.py",
      "generatedBy": "bmi" },
    { "tier": "student", "script": "test_student.sh" }
  ],
  "patternFamilies": [
    {
      "id": "bmi",
      "function": "classify_bmi",
      "kind": "boundaryEquality",
      "defaults": { "tier": "public", "points": 1 },
      "cases": [
        { "key": "01", "args": [18.49], "expected": "underweight" }
      ]
    }
  ],
  "timeLimitSeconds": 10,
  "makefile": null
}
```

`makefile` is optional. When present, a `make` step runs before the test
scripts. If `target` is `null`, bare `make` is invoked; otherwise
`make <target>` is used.

`patternFamilies` is the canonical spec for generated test families; each
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

---

## Vendored browser libraries

Pyodide, jszip, and CodeMirror are vendored under `Public/` rather than
pulled from third-party CDNs at runtime, so student / instructor IPs
aren't leaked to `cdn.jsdelivr.net` and `esm.sh` on every page load
(FIPPA / PIPEDA concern surfaced in the v0.4.171 audit).

```
Public/pyodide/              — the ONE canonical Pyodide distribution (~465 MB)
Public/vendor/jszip.min.js   — jszip browser-runner uses for zip extraction
Public/vendor/codemirror.js  — bundled CodeMirror 6 ESM
```

**One canonical Pyodide.** There is exactly one vended Pyodide, served at
`/pyodide`, and *both* consumers load it: the JupyterLite editor kernel (via
`pyodideUrl` in `Tools/jupyterlite/jupyter-lite.json`) and Chickadee's own
browser paths (`browser-runner.js`, `assignment-validate.js`,
`pyodide-worker.js`, `notebook.js`).  The editor and grader
therefore run the identical Python environment.  (Historically the editor
loaded a *second* Pyodide from `cdn.jsdelivr.net`; #574's CSP cleanup dropped
that allowance and broke the editor — see `SecurityHeadersMiddleware`.)

**The Pyodide version is not hardcoded — it is derived from the kernel.**
The only version pin is `jupyterlite-pyodide-kernel` in
`Tools/jupyterlite/requirements.txt`; its bundled core wheels are ABI-locked
to a specific Pyodide release, so `scripts/setup-vendor.sh` reads that version
out of the built bundle and vends exactly it.  One pin, one version, no drift.

Rebuild order matters:

```bash
scripts/setup-jupyterlite.sh     # build the .venv-jlite toolchain
scripts/build-jupyterlite.sh     # rebuild the bundle (kernel version baked in)
scripts/setup-vendor.sh          # derives Pyodide version from the kernel, re-vendors
```

`scripts/check-pyodide-parity.sh` fails the build (and CI, via
`jupyterlite.yml`) if the vended Pyodide ever drifts from the kernel's pinned
version — the guard against repeating #574.  jszip is fetched by
`setup-vendor.sh`; CodeMirror is bundled via `npm` + `esbuild` from
`Tools/vendor/{package.json, codemirror-entry.js}`.  `Public/pyodide` and
`Public/vendor` are checked in for the same reason `Public/jupyterlite` is —
every contributor and CI runner sees the same bytes without a build-time
network fetch.

**Extra packages + nb_mypy (currently DISABLED).** Pure-Python packages not
in the upstream Pyodide distribution are declared in
`Tools/vendor/pyodide-extra-packages.json` (pinned URL + sha256) and injected
into the one lock by `scripts/add-pyodide-extras.py` (run from
`setup-vendor.sh`); `check-pyodide-parity.sh` then asserts they're present so
a re-vendor can't silently drop them.  This is how the `nb_mypy` (+ `astor`)
wheels get into the editor bundle — but **nb_mypy type-checking is disabled**
(see the `scripts/patch-pyodide-kernel.py` docstring): its IPython
`pre_run_cell` hook ran a synchronous compiled-WASM mypy on every cell
execute, on the kernel's single thread, and wedged the first cell in the real
editor.  The wheels stay vended (harmless, unloaded) and the patch keeps an
empty activation block so re-enabling is a one-line change; revisit
type-checking only as a feature that never runs on the cell-execute path.
The same kernel-wheel patch is what carries the v0.4.526 chdir fix; patching
a bundled wheel means a sha cascade (wheel → `all.json` digest →
`pipliteUrls` sha); `verify-jupyterlite.sh` asserts that chain is consistent
so a mismatch (which would make piplite reject the kernel) is a build
failure, not a browser surprise.

**Xeus extension parselmouth stub.** The vendored `@jupyterlite/xeus-extension`
(the xeus-r kernel's UI wiring) upstream fetches a conda→PyPI name mapping from
`raw.githubusercontent.com` at module load — on every editor boot, for every
kernel, though only xeus's unused runtime pip-install path consults it.
`scripts/patch-xeus-extension.py` (run from `build-jupyterlite.sh`, asserted by
`verify-jupyterlite.sh`) stubs it to a resolved empty mapping: the CSP blocks
the request by policy anyway, and un-patched it emitted a `csp_violation` +
`unhandledrejection` diagnostics pair on every boot. The same patch
cache-busts the extension's chunk and remoteEntry URLs (`?v=ck1<hash>` in the
loader template, `?ck1` on the federated `load` in the built
`jupyter-lite.json`): the stub changed bytes in place under immutable-cached
hashed names, and only a URL change reaches browsers that loaded the editor
pre-stub.

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

- Swift 6, strict concurrency. No `@unchecked Sendable` without a comment explaining why.
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

Run `scripts/check-styles.sh` locally before pushing UI changes (it runs the
css-vars + design-token guards too — same as the CI `format-lint` job).

---

## Testing Conventions

- **Framework: Swift Testing only.** All ~340 Swift test files / ~3,000
  tests (plus the 13 `.mjs` frontend test files in
  `Tests/BrowserRunnerJSTests/`) are on Swift Testing as of the migration
  completion (PRs #597–#608). `scripts/no-new-xctest.sh`
  blocks any new `import XCTest` under `Tests/`.
- **Approved Swift Testing vocabulary.** `@Suite`, `@Test`, `#expect`,
  `#require`, `.serialized`, `.tags(...)`, `.disabled(if:)`,
  `@Test(arguments:)`, and `.timeLimit(.minutes(n))` (put it on any suite
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
    so shutdown is deterministic; the next test's `init` builds a
    fresh app.
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
  records a failure. Either `guard condition else { return }` (silent)
  or `throw IssueRecorded("...")` (fails with a clear message) — pick
  based on whether the unmet condition is "expected on this platform"
  (silent) or "test setup is broken" (failure).
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

**The 0.4 series is closed.** v0.5.0 marks the conclusion of the first full
course offering run on Chickadee and the pivot to next year's feature work.
The system is a working client–server autograder: Python and R assignments;
browser (Pyodide/wasm) and native worker grading paths sharing one RunnerCore
implementation; per-student personalization; pattern-generated test families
(8 kinds) and notebook checks (10 kinds); achievements; student slip days;
per-course roles; BrightSpace grade sync (awaiting UW IST prod credentials);
an MCP authoring surface of 52 tools plus a read-only admin-diagnostics MCP
of 19 (`MCPToolCatalog.live` in
`Sources/APIServer/MCP/Transport/MCPServerRegistration.swift` is the count's
source of truth); OIDC SSO; and zero-downtime auto-deploys.

Per-release history for 0.1.0–0.4.x lives in `CHANGELOG-0.4.md` (split out of
`CHANGELOG.md` at the 0.5.0 cut). The 0.4 arc, one line per theme:

- **Grading core.** Shell-script contract → sandboxing → browser grading →
  the RunnerCore extraction (#764–#775): one Swift grading core compiled
  natively and to wasm, pinned by `Tests/Fixtures/output-contract.json`;
  R became first-class in #1207.
- **Authoring.** Instructor editor → server-authoritative suite editor →
  pattern families + notebook checks → suite sections, hints, datasets,
  per-student personalization (the #461 arc) → assignment versioning with
  restore (#1223–#1225) → the MCP authoring surface with per-course
  authoring-voice guides.
- **Course management.** Courses/enrollment/archival → `.chickadee` course
  bundles → per-course enrollment roles (#417 arc: `student` < `ta` <
  `instructor` per course; deployment roles collapsed to `user`/`admin`) →
  course sections, content items, activity timeline (#1227), slip days
  (#1228).
- **Identity & compliance.** Local auth → OIDC/PKCE SSO (UWaterloo DUO) →
  lockout/rate-limit/audit hardening → the UW approval package under
  `docs/compliance/` (student-data audits of both MCP surfaces, tool and
  data-flow inventories).
- **Operations.** Docker Compose → HMAC runner auth → capability profiles,
  runner-side LRU setup cache, health alerts, diagnostics tables →
  blue-green zero-downtime auto-deploy (`chickadee-deployer`) → CI
  hardening (the #1139 fork/exec postmortem, the #1233 pool-saturation
  wedge fix, the prebuilt swift-ci test image #1238/#1239, a
  real-Postgres test lane).
- **Editor reliability.** Embedded JupyterLite → kernel-boot telemetry +
  watchdog → the exec_hang root cause (v0.4.526 chdir patch) → JupyterLite
  0.8, service-worker-free/SAB-only isolation, the xeus-r kernel for R
  notebooks, the parselmouth CSP stub (#1241/#1243).

The 0.5-boundary cleanup pass additionally: put R execution and
pandas/matplotlib on the CI image (their suites were silently skipped
everywhere); deduplicated the browser grading semantics into
`Public/grading-shared.js` (one copy for the grading worker and the
main-thread fallback — the bespoke drift test is gone); ran the second
migration consolidation (post-#502 increments folded into `Create*` files,
removing the #1077 boot-order hazard class); retired the pre-0.5 shims
(`WORKER_SHARED_SECRET` alias, `/admin/workers` alias, the two per-boot
legacy sweeps, the bundle `isOpen` write side, the scanner realignment
shim); and archived finished-era docs under `docs/archive/`.

**Near-term roadmap:**

- **Leaf partial decomposition — DONE (2026-08, #1266 + #1269). The
  long-standing "multi-extend parser bug" was a misdiagnosis.** Multiple inline
  partial includes work fine on LeafKit 1.14.3. The real cause of
  `LeafError.500: extend only supports one or two parameters []` is that
  **Leaf's lexer has no notion of an HTML comment.** `<!-- ... -->` is raw text
  to it, so tag syntax written inside one is lexed exactly as if it stood in
  the markup. A bare structural tag name lexes to a tag with *no* parameter
  list, and `Extend.init` rejects that — hence the empty `[]` in the message.

  Verified against a control (a probe comment inserted into an otherwise
  untouched `notebook.leaf` — 7 lines, one include — with a no-probe baseline
  proving the harness measured anything at all):

  | In a comment | Result |
  |---|---|
  | bare `extend` / `if` / `else` / `elseif` / `endif` / `for` / `endfor` / `import` / `export` / `endextend` | **500 at render** |
  | `#(someField)` | **silently interpolated** — the real context value lands in the served HTML |
  | `#someTag()` | parens consumed, name left as literal text |
  | a *complete* `extend("_partial")` | **resolves the partial**, exactly as if uncommented |
  | unknown `#word` (`#wb-single-edit`, `#jl-frame`), `C#`, `id="#main"` | genuinely inert |

  That last row is why existing comments naming CSS ids are safe, and why the
  rule is narrower than "never write `#` in prose".

  **Practical rule:** never write Leaf *tag* syntax in template prose or
  comments — not a bare structural tag name, not `#(field)`, not a complete
  include. Say "the extend" or "an `extend(...)` include" instead. Commenting a
  tag out does not disable it.

  The historical bisection was almost certainly toggling heavily-commented
  blocks whose prose named a tag, which is why the failure looked template-wide
  and size-dependent rather than like a one-line typo.

  Inline partial includes themselves are unrestricted, and the **sub-context
  form** `extend("_partial", subObject)` works — that is what lets one partial
  serve both a standalone page (flat context) and a composite page (nested), as
  `_assignment-edit-body` / `_notebook-body` do for the workbench. Note the
  syntax: a bare second parameter, **not** the labelled `with:` form, which
  does not lex (`invalidParameterToken(":")`).

  **What the corrected rule actually unblocked, measured (#1269).** Less than
  the old rule appeared to be holding up. Diffing the two authoring templates
  rather than counting marker strings, the shared-markup opportunity was **one
  block of ~70 lines**, now `_suite-sections.leaf` — parameterized on a
  per-page endpoint base, a trailing query string, and whether its forms carry
  `data-ck-inplace`. The files table only *looks* shared and stays in two
  honest copies: its notebook rows differ structurally (optional-notebook
  draft actions vs. a guaranteed notebook plus workbench hooks).

  The duplication that was actually costing correctness was **JavaScript**,
  which the Leaf rule never blocked, and in every case the create page was the
  stale fork. Fixing it removed three live defects: per-student `=` expressions
  degrading to literal strings in section inputs, section drag-reorder
  persisting nothing while showing a failure alert, and a double confirmation
  dialog on section delete. `assignment-new.leaf` went 1,059 → 711 lines,
  `_assignment-edit-body.leaf` 918 → 811. Full analysis and the slice plan:
  [docs/leaf-decomposition-review.md](docs/leaf-decomposition-review.md).

  A corollary of the comment finding, learned twice more while doing it: the
  same blindness applies to *any* scanner that cannot tell markup from prose
  about markup. Two new drift guards matched their own documentation — one
  quoting the pattern it forbade, one naming an attribute it asserted absent.
  Prefer parsing structure (as `InstructorWorkbenchRoutesTests` does with form
  open tags) over searching the document, and describe forbidden syntax rather
  than quoting it.

  (Render tests catch all of this — they prove templates *resolve*; they don't
  exercise page JS, so a JS-driven widget still wants a manual check.)
- **Feature backlog:** continued personalization / notebook-check
  expansion (e.g. per-student refs in pattern kinds beyond the three
  equality kinds); pattern kinds beyond the eight shipped
  (`boundaryEquality` / `approximateEquality` / `variableEquality` /
  `returnTypeCheck` / `exceptionExpected` / `performanceThreshold` /
  `stdoutEquality` / `unorderedEquality`); multi-provider SSO testing beyond UWaterloo DUO;
  refresh-token handling; gamification expansion (leaderboards, more
  badges beyond First-Try Perfect).

---

## What Not To Do

- Do not import Vapor in `Core/`.
- Do not add `CouldNotRun` as a `TestOutcomeStatus`. Build failures are
  represented at the collection level (`buildStatus: "failed"`).
- Do not write a runner JSON protocol — the runner interprets exit codes directly.
- Do not add per-language build strategies in Swift — test suites are plain shell scripts.
- Do not use `@unchecked Sendable` without a comment.

---

## Reference Material

- `docs/architecture.md` — system architecture: targets, grading pipeline, auth, sandboxing, deployment
- `docs/brightspace-setup.md` — BrightSpace grade-sync operator runbook: Valence credential handshake (`scripts/brightspace-valence-auth.py`), env wiring, org-unit/grade-item binding, end-to-end testing against `learntest`
- `docs/operational-diagnostics.md` — observability tables, structured log events, metrics endpoint, ops runbook
- `docs/zero-downtime-deploy.md` — production CI/CD: blue-green swap (`scripts/bluegreen-deploy.sh`), the `chickadee-deployer` auto-deploy daemon (GitHub-release SemVer gate, snapshot, auto-rollback), and the read-only admin-MCP deploy-oversight tools
- `docs/runner-capability-profiles.md` — runner capability matching, assignment requirements, rollout rules
- `docs/runner-wasm-migration.md` — plan to share one Swift grading core (RunnerCore) between the worker + browser runner via SwiftWasm; staging, the ScriptExecutor protocol, type-hoist
- `docs/personalization-phase1.md` — per-(student, assignment) seed contract (`CHICKADEE_ASSIGNMENT_SEED`), worked hand-written example
- `docs/inputs.md` — Global + section inputs: literal variables, per-student `=` expressions, `$name` references, save-time inlining vs. notebook substitution
- `docs/personalization-pattern-families.md` — per-student pattern families: `$name`/`expectedVarRef` → server-resolved values delivered via `_ck_inputs.py` (worker) / browser seed endpoint
- `docs/personalization-eval-runtime.md` — design note + deferred 0.5+ future work: where/in-what-language personalization expressions are evaluated; the trilemma, the per-language-on-server decision (`python3` + `Rscript`), and the direction to move eval to the runner/browser per-language
- `docs/r-support.md` — first-class R support: `AssignmentLanguage` resolution + strategy, per-language personalization (`Rscript` expression driver, base-R `chickadee_seed()`, `_ck_inputs.R` delivery, R-literal notebook substitution), the R grading runtime, and the R renderers for pattern families / notebook checks (#1207; `astStructure` stays Python-only)
- `docs/language-handling-review.md` — second-opinion design review of the Python-or-R dispatch surface: verdicts on R extraction in RunnerCore, the Swift↔JS drift-guard hierarchy, the resolution API surface, the third-language census, and process rules
- `docs/multi-course-roles.md` — per-course roles design (#417 arc): enrollment-row `CourseRole`, gates, staff invites
- `docs/assignment-versioning.md` — content version history: snapshot capture, read/restore, lifecycle
- `docs/slip-days.md` — student-managed slip days (#1228): per-course bank, self-serve extensions
- `docs/datasets.md` — per-student datasets (#1083): `DatasetSpec`, deterministic per-seed slices
- `docs/admin-mcp.md` — the read-only admin diagnostics MCP surface (19 tools)
- `docs/compliance/` — the UW approval package: student-data audits of both MCP surfaces, per-tool inventory, data-flow inventory, Policy 46 classification, trust boundary
- `docs/unlockable-labs.md` — locked design for assignment prerequisites + sticky per-student unlocks (#59/#62 under epic #49): edge table, unlock semantics, enforcement chokepoints, drag authoring, slice plan
- `docs/ci-flakiness.md` — CI flake families, evidence, and attack order (2026-07 snapshot; start here before chasing a red check on an unrelated PR)
- `docs/leaf-decomposition-brief.md` — handoff brief on the Leaf "multi-extend bug" (a misdiagnosis — the lexer does not know HTML comments), the control-first method that corrected it, and the template decomposition it was holding up
- `docs/archive/` — finished-era investigations, superseded plans, and point-in-time audits (kept for the record; nothing in there describes current behaviour)
- `CHANGELOG.md` — release history from 0.5.0; `CHANGELOG-0.4.md` — the archived 0.1.0–0.4.x history
