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

**Browser grading has four substrates, routed per script (#1271).**
`RoutingExecutor` in `Public/browser-runner.js` sends a `.py` test to the
vendored **xeus-python** kernel (`/python-grading-worker.js`), a `.R` test to
**xeus-r** (`/r-grading-worker.js`), a `.lua` test to **xeus-lua**
(`/lua-grading-worker.js`), and a `.m` test to **xeus-octave**
(`/octave-grading-worker.js`), choosing with the same
`RunnerCore.classifyScript` the native worker uses to pick a subprocess command
— and booting only the runtimes an assignment actually contains, so an R lab
never fetches the Python env. `RunnerCore` still owns the suite loop and output
interpretation for all four; a substrate supplies only "run this script, report
its exit code and streams".

xeus-r is the **only** route to in-browser R (WebR's `jupyterlite-webr` caps at
`jupyterlite-core<0.7` and we pin 0.8.x). Because a kernel has no process
contract, `Public/r-grading-shared.js` masks `quit`/`commandArgs` in the global
environment so `test_runtime.R` stays byte-identical across both runners, and
wraps each script in ONE top-level R expression (xeus-lite yields to the JS
event loop between top-level expressions and does not regain control for
~180ms — a *wait*, not work: one expression summing 8M elements costs less
than one summing 1, and R's own clock reports 0ms across nested expressions vs
~228ms across a bare one. A statement-list wrapper cost ~3.5s per test vs
~0.8s). Only a real kernel proves any of this, so `Tools/browser-grading-smoke` boots
one in a browser in CI. See `docs/r-support.md`.

**Lua is a full assignment language as of the second-half work.**
`chickadee-lua` (19 MB, boot ~2.5s) grades `.lua` scripts in the browser and the
native worker injects `Tools/runner-support/test_runtime.lua` beside the Python
and R helpers, so one file serves `lua script.lua` and the kernel.
`AssignmentLanguage` gained `.lua`, with a Lua literal renderer,
a pattern-family renderer covering all eight kinds, a notebook-check renderer
covering four of ten, and a personalization driver. The six unsupported check
kinds are refused at save time rather than absent: the four data-frame kinds
need a data frame (Lua has no such type and the env ships no packages),
`figureCount` needs a plotting library, and `astStructure` is Python-only as it
is for R. `cellContains` additionally refuses `regex: true`, because Lua
patterns are a different language from PCRE and a Python-authored pattern would
quietly match the wrong thing rather than erroring. Its two per-kernel quirks
are `os.exit` masking (R's `quit()` problem again — if it regresses, every test
reads as a pass) and a per-script wipe of globals added since boot, since `_G`
*is* Lua's standard library and cannot be cleared outright. Crucially, **R's two
expensive lessons did NOT generalise**: xeus-lua costs 5ms for 20 top-level
statements (no ~180ms yield) and its `io.stderr` reaches the kernel stream
directly (no `evaluate` calling-handler trap). Budget one quirk per kernel, not
the same one. Measurements and the full postmortem:
`docs/adding-a-xeus-kernel.md` §"What the Lua run actually cost".

**Octave is the fourth assignment language.** `AssignmentLanguage` is now
`.python | .r | .lua | .octave`: `.m` scripts grade natively (`octave-cli`;
the `octave` package plus `gnuplot-nox` + `fonts-freefont-otf` for headless
figures are on both images) and in the browser via the vendored `xeus-octave`
kernel (`chickadee-octave`, 142 MB on disk — the largest env — xeus 6.0.5,
~5–12 s boot, no per-statement cost). All eight pattern kinds render and
execute; notebook checks cover seven of ten — `figureCount` and regex
`cellContains` are SUPPORTED (both of Lua's opposite answers, re-measured:
plotting is core Octave and Octave's regexp is PCRE), while the four
data-frame kinds (no data-frame type in core Octave, no packages on the
channel) and `astStructure` are refused at save time. The literal rule is the
language's one silent trap: `[65, "bc"]` is the char array `"Abc"`, so
`JSONValue.octaveLiteral` renders arrays as `[...]` only when every element
is a numeric/boolean scalar (null → `NA`) and everything else — any string,
mixed kinds, nesting, objects, empty — as cells, with objects as
`containers.Map` calls. Equality is `isequaln`-based (NA/NaN match
themselves; Octave is already type-blind across logical/int/double) plus a
both-empty rule and shape-blind numeric comparison. `test_runtime.m` loads
submissions by evaluating their text behind a `1;` guard, so notebooks,
scripts and one-function-per-file submissions all register their definitions
(the last under its own name, not its filename). The kernel needed NO
substrate patch (the per-kernel quirk budget went unspent): `fprintf(2,…)`
reaches the stderr stream, `setenv` works, and the `exit`/`quit` masks carry
the status on the `chickadee:exit` error identifier. The scorecard's
prediction that Octave needs `OCTAVE_PATH` was measured wrong — `.` is first
on the default load path in both runners — and the LanguageDescriptor table
records the correction. Postmortem: `docs/adding-a-xeus-kernel.md` §"What
the Octave run actually cost".

**C++ is the fifth assignment language — and the first with NO editor kernel.**
`EditorSupport.uploadOnly` (the `LanguageDescriptor` judgement that folded the
four kernel facts) plus `submissionMode: "uploadOnly"` (a manifest field beside
`gradingMode`; `notebook` mode deliberately keeps the upload form beside the
editor, so there is no third "both" value) make C++ assignments upload-only and
native-worker-only by construction: no xeus kernel is vendored because the
browser would grade a *different compiler* than the course's g++ — the
two-C++s decision in `docs/cpp-support.md`. A generated case is a POSIX shell
wrapper (heredoc C++ source → g++ one translation unit → exec the binary under
the original shell contract): no `ScriptInterpreter` case, no build strategy in
Swift, `generatedScriptExtension` is `"sh"` (the one language whose generated
extension is not its own — pinned, since `.sh` must keep carrying no language
signal). Single-TU inclusion (`#define main ck_student_main` around the
student's file) is what dissolved the memo's declared-type problem: no
prototype is ever declared, literals render CTAD-typed and `ck::equal` in
`test_runtime.hpp` compares cross-type. All 8 pattern kinds execute —
`performanceThreshold` is supportable *because* the language is native-only
(-O2 wrapper), `returnTypeCheck` matches static types via decltype — and all
ten notebook checks are refused categorically (no notebook workflow exists).
Literal refusals are the language's trap-guard: JSON null, mixed arrays,
nested containers have no C++ rendering and are refused at save time
(`cppRenderabilityIssue`), with an undefined-identifier backstop so a leak is
a compile error; the measured trap was `std::cmp_equal` rejecting `bool` by
design (equality promotes bools explicitly). Personalization `=` expressions
are C++, compiled-and-run by an `sh` driver (~0.3s, same Horner seed fold),
delivered as typed `inline const auto` definitions in `_ck_inputs.hpp` where a
missing input is a compile error. Per-test compile ~0.65s at -O0, measured.
g++ rides both images and the runner capability probe.

**Every worker the notebook page spawns must be in
`NotebookAssetIsolationMiddleware.isolatedWorkerScripts`.** The page is
cross-origin isolated on Chromium/Firefox, and a worker created by a
`require-corp` document must ITSELF be served `require-corp` or the browser
refuses the script (`ERR_BLOCKED_BY_RESPONSE`) — at which point `ensureReady`
throws and the submission silently fails over to the native worker: right marks,
none of the speed. The allowlist is per-path, so "same directory, same
middleware" proves nothing about a worker not on it; that reasoning is how #1274
shipped browser-graded R that no isolated engine ever ran.
`IsolatedWorkerScriptDriftTests` reads the spawn sites out of the page scripts
and fails on drift in either direction. It currently lists the four grading
workers (Python, R, Lua, Octave) plus the freeze watchdog.

**Assignments are Python, R, Lua, Octave *or* C++; language is first-class (`AssignmentLanguage`).**
`AssignmentLanguage` (`.python | .r | .lua | .octave | .cpp`, Core) is resolved from the manifest
(any `.R` graded script → `.r`, any `.lua` → `.lua`, any `.m` → `.octave`; else
a notebook kernel in that language's `notebookKernelNames` — `{ir,r,webr,xr}`
for R, `{xlua,lua}` for Lua, `{xoctave,octave}` for Octave; else `.python`) and every language-specific path dispatches through it — literal
rendering (`pythonLiteral`/`rLiteral`), the per-student inputs file
(`_ck_inputs.py`/`_ck_inputs.R` via `renderInputsFile`), and the expression
driver. Personalization is evaluated **per-language on the server**:
`PersonalizationEvaluator` spawns `python3`, `Rscript`, `lua` or `octave-cli`
(all on the server image), preserving the property that expression source +
the solution never reach the runner. Base R has no bignum, so the seed is a deterministic
Horner-fold reduction (`RPersonalizationRuntime.chickadeeSeedRSource`, shared by
the server driver and the grading runtime so they never drift). The default is
`.python` at every call site, so existing Python bytes are byte-for-byte
unchanged. R pattern-family / notebook-check renderers and literal-globals
inlined into hand-authored `.R` scripts shipped in #1207 (v0.4.636);
`astStructure` remains the one Python-only check kind. See `docs/r-support.md`.

**A runner only claims a job it can actually grade — enforced, not authored
(`RunnerLanguageGate`).** Runners are separate hosts that upgrade on their own
schedule, so several `chickadee-runner` builds poll at once and claim order
decides which one grades a job. That used to make an assignment in a newer
language nondeterministic: it validated green because a capable runner happened
to claim it, then failed for the one student whose job an older runner claimed —
with a symptom (exit 127, "interpreter not found") that reads as a broken test
script and gets debugged as one. The claim seam now resolves the assignment's
language from its manifest and refuses a runner whose advertised profile lacks
it, so the job waits for a runner that can grade it. No authoring step: the
manifest already knows the language, and `RunnerProfileDetector` discovers its
probes from `AssignmentLanguage.allCases`, so every runner advertises every
language it has and a runner whose *build* predates one advertises a profile
without it. Two deliberate fail-opens — an assignment with no language (a plain
`.sh` suite) and a runner advertising no profile at all (discovery switched off,
an operator's choice; an old runner still has discovery on and is caught by the
closed path). It catches strictly more than a version gate: a *current* runner
whose host lacks the interpreter never advertises it either. `minimumRunnerVersion`
(MCP `set_minimum_runner_version`, metadata-only) survives for the case this
cannot see — runner behaviour that is not observable as an interpreter — and is
the wrong tool for "this is a new language". Browser-graded assignments are
covered too, since instructor validation is enqueued as a `kind == .validation`
submission and always runs on the **native worker**. See
`docs/runner-capability-profiles.md`.

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
`normalizeNotebookForJupyterLite` (`NotebookContentHelpers.swift`) — for Python
for all three. A Lua notebook resolves to `xlua` and extracts through the
same marker-emitting RunnerCore extractor R uses — vendoring a kernel puts it
in the editor's picker, so a language that can be authored must be one that
can be graded.

**Two places enumerate the kernels rather than discovering them, and both fail
open for one they have never heard of:** the `chickadee-*` glob in
`build-jupyterlite.sh` (which decides who gets a module index) and
`expected_language` in `check-xeus-vendored.sh` (which decides who gets a
vendoring guard). Neither errors — you simply get a kernel nothing checks.
`docs/adding-a-xeus-kernel.md` is the runbook.

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

**Both kernel environments are checked at authoring time, and the check reads
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
went with it. Both editor kernels and both browser graders are xeus.
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
identical un-patched polyfill, in the kernel Chickadee actually runs, for both
languages. A per-extension scope is how that went unseen for two releases; the
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
The system is a working client–server autograder: Python, R and Lua assignments;
browser (Pyodide/wasm) and native worker grading paths sharing one RunnerCore
implementation; per-student personalization; pattern-generated test families
(8 kinds) and notebook checks (10 kinds); achievements; student slip days;
per-course roles; BrightSpace grade sync (awaiting UW IST prod credentials);
an MCP authoring surface of 54 tools plus a read-only admin-diagnostics MCP
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
- **Consolidating on xeus (#1271) — R done, Python open.** Browser grading is
  now two substrates: R runs the vendored xeus-r kernel (shipped here), Python
  still runs Pyodide. Moving Python across would restore one authoring/grading
  environment and let the ~465 MB `Public/pyodide` go, but it is gated on the
  package-set question the issue flags as unresolved: Pyodide resolves imports
  at runtime via `loadPackagesFromImports`, while a xeus env is fixed at build
  time with no escape hatch under `connect-src 'self'` — forgiving for an author
  who can ask for a package, unforgiving for a student whose submission imports
  something unanticipated at grade time. R had none of this risk: its env is
  bare `xeus-r` and is already the editor's. **Spiked 2026-08 —
  `docs/xeus-python-grading-spike.md`:** xpython boots on the same standalone
  path (one extra `bootstrapPython` export), and R's ~180ms-per-expression
  yield does NOT generalise — xeus-python's floor is 5ms per cell vs Pyodide's
  ~0ms, and boot is a wash once Pyodide's on-demand numpy/pandas fetch is
  counted. The gate is purely the package set: the env has numpy/pandas/
  matplotlib/PIL, while the vendored Pyodide resolves scipy/sklearn/sympy/
  statsmodels/networkx/requests at run time. Chickadee's generated tests import
  none of those, and students are already held to the env by the editor, so the
  residual risk is hand-authored scripts. Two other consumers would have to
  move before `Public/pyodide` could go — `pyodide-worker.js` (the
  pattern-family editor's auto-compute) and the vendored
  `jupyterlite-pyodide-kernel` that anchors `check-pyodide-parity.sh`. NOT
  `/validate`: instructor validation is enqueued as a `kind == .validation`
  submission and graded by the **native worker**
  (`WorkerJobRoutes.collectClaimCandidates`), so it never loads Pyodide at all.
  Earlier notes here and in #1271 claimed otherwise, citing an
  `assignment-validate.js` that does not exist.
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
- `docs/xeus-python-grading-spike.md` — whether Python browser grading should move to xeus-python (#1271): measured Pyodide-vs-xeus-python execution and boot cost, the package-set gap, and the accidental CSP dependency that currently makes Pyodide load at all in a classic worker
- `docs/xeus-python-grading-migration-plan.md` — the executable handoff for that migration: the package-set decision that gates it, the slices, which R lessons do NOT carry over (the stderr trap and the one-expression rule are both xeus-r-only), staged rollout behind the existing failover, and what must be true before `Public/pyodide` can go
- `docs/cpp-assignment-language-decision.md` — why C++ stays on the shell-script + makefile path rather than becoming an `AssignmentLanguage`: the one-file-one-command invocation mismatch, the typed-literal impossibility, and the Clang-REPL-vs-course-toolchain pedagogy problem; the priced revisit condition
- `docs/adding-a-xeus-kernel.md` — runbook for teaching Chickadee another in-browser language: which xeus kernels exist on emscripten-forge (with sizes and xeus-ABI pins), why availability is not the same as working, the browser-half steps and the check that proves each, the traps that have cost a day each, and where the irreducible per-language work begins — plus "What the Lua run actually cost", the measured postmortem of doing it once (what held, and which of R's expensive lessons turned out to be xeus-r properties that do not generalise). Now covers BOTH halves end to end: the 26 compiler-named sites measured on the Lua run, the **seven** the compiler cannot see (the fifth being boolean sniffs like `isRNotebook(nb) ? .r : .python`, which type-check forever and route the new language to Python; the sixth runner capability matching, which fails in both directions and whose worse direction queues an assignment's jobs forever; the seventh the submission policy), the browser half's own checklist, the one judgement (`moduleResolution`) that replaced three and the scorecard that sized it against Octave/Java/C++ — including the two axes the model cannot see (interpreted-vs-compiled, and dynamically-vs-statically-typed literals) and the reframe that a language need not be an `AssignmentLanguage` to be graded at all, the submission-guarantee policy (a policy value with named exemptions rather than a protocol, because a protocol makes opting out invisible), and a done test that requires the generated code be executed rather than parsed
- `docs/kernel-boot-cost.md` — what a kernel boot costs, measured per package and per environment; the failure-driven on-demand install design and why predicting the package set cannot work; why cross-user caching is unavailable; why the editor is deliberately excluded
- `docs/r-support.md` — first-class R support: `AssignmentLanguage` resolution + strategy, per-language personalization (`Rscript` expression driver, base-R `chickadee_seed()`, `_ck_inputs.R` delivery, R-literal notebook substitution), the R grading runtime, and the R renderers for pattern families / notebook checks (#1207; `astStructure` stays Python-only)
- `docs/language-handling-review.md` — second-opinion design review of the assignment-language dispatch surface: verdicts on R extraction in RunnerCore, the Swift↔JS drift-guard hierarchy, the resolution API surface, the third-language census, and process rules. Written before Lua existed, so §4's prediction is now **scored against the real third language** — what held (bucket A never changed; every bucket-B site failed to compile) and what did not (the compiler-invisible surface is a recurring shape, not a checklist)
- `docs/multi-course-roles.md` — per-course roles design (#417 arc): enrollment-row `CourseRole`, gates, staff invites
- `docs/assignment-versioning.md` — content version history: snapshot capture, read/restore, lifecycle
- `docs/slip-days.md` — student-managed slip days (#1228): per-course bank, self-serve extensions
- `docs/datasets.md` — per-student datasets (#1083): `DatasetSpec`, deterministic per-seed slices
- `docs/admin-mcp.md` — the read-only admin diagnostics MCP surface (19 tools)
- `docs/compliance/` — the UW approval package: student-data audits of both MCP surfaces, per-tool inventory, data-flow inventory, Policy 46 classification, trust boundary
- `docs/unlockable-labs.md` — locked design for assignment prerequisites + sticky per-student unlocks (#59/#62 under epic #49): edge table, unlock semantics, enforcement chokepoints, drag authoring, slice plan
- `docs/ci-flakiness.md` — CI flake families, evidence, and attack order (2026-07 snapshot; start here before chasing a red check on an unrelated PR)
- `docs/archive/` — finished-era investigations, superseded plans, and point-in-time audits (kept for the record; nothing in there describes current behaviour)
- `CHANGELOG.md` — release history from 0.5.0; `CHANGELOG-0.4.md` — the archived 0.1.0–0.4.x history
