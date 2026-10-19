# Chickadee — Project Context

## What This Is

A clean-break rewrite of Marmoset, a student code submission and autograding
system originally built in Java at the University of Maryland. The rewrite is
in Swift using Vapor, targeting both macOS and Linux. No interoperability with
the original Java system is required.

The architecture is new. The original Java source is not in this repository.

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

- **`APIServer` / `chickadee-server`** — Vapor app. REST API + web UI (Elementary views).
  Handles auth, assignment management, submission intake, result storage, the
  JupyterLite notebook workflow, and the MCP server (see `Sources/APIServer/MCP/CLAUDE.md`).
- **`Worker` / `chickadee-runner`** — Daemon process. Polls for jobs, runs
  shell-script test suites in subprocesses (sandboxed or unsandboxed), reports
  structured results back to the server.
- **`RunnerCore`** — The shared, Vapor-free, **Embedded-Swift-compatible**
  grading core, compiled natively (into the worker) and to **WebAssembly** (the
  browser runner). It owns suite execution (`executeSuites`), output
  interpretation (`interpretScriptOutput`), script classification, notebook
  extraction (one `extract<Language>` per language) and the `TestOutcome` /
  `TestTier` / `TestStatus` types, so the two graders cannot drift.
  `Tests/Fixtures/output-contract.json` pins it, against the native build and
  the *real vendored wasm* in CI.
- **`Core`** — Shared models and types. No Vapor dependency; `@_exported import
  RunnerCore` re-exports the grading types. Every other target depends on this.

---

## Where the Area Rules Live

This file holds the rules for the whole repository. Rules for one area are in a
`CLAUDE.md` in that area's directory. Claude Code loads each one when it works
on a file there.

| File | Holds |
|---|---|
| `Sources/APIServer/CLAUDE.md` | REST API, auth and roles in detail, `AppConfig`, runner trust, courses and deadlines, class goals, authoring editors, pattern families, browser isolation |
| `Sources/APIServer/MCP/CLAUDE.md` | MCP server, the student-data wall, derived language and tier prose |
| `Sources/APIServer/Views/CLAUDE.md` | Elementary pages, UI and stylesheet rules (also for `Public/styles.css` and `Public/*.js`), the `ui-review` agent |
| `Sources/Worker/CLAUDE.md` | Sandbox boundary, test setup cache, runner flags |
| `Tools/jupyterlite/CLAUDE.md` | The vendored editor and kernels, kernel traps |

`Public/` has no `CLAUDE.md`, because the server serves every file in it. Before
you change `Public/styles.css` or a page-wiring `Public/*.js` file, read
`Sources/APIServer/Views/CLAUDE.md`.

---

## Key Design Decisions

**Shell scripts, not language runners.** Each test suite is a `.sh` file at the
root of the instructor's test setup zip. The runner runs them with `/bin/sh`
and maps the exit code to a result status. No per-language runners, no runner
JSON protocol. The *grading* path needs no Swift change for a new language.
The runner does normalize uploads (`SubmissionNormalizer`, `NotebookExtractor`)
into a grading workspace before the scripts run. That is a submission-format
concern; the scripts stay language-agnostic.

**Instructor bundles the helper library.** Any helper library (Swift, Python,
etc.) is included in the test setup zip by the instructor. The runner does not
inject anything.

**Build failure lives at the collection level, not the test level.** If the
build fails (e.g. `make` step fails), `buildStatus` is `"failed"` and
`outcomes` is `[]`. There is no `couldNotRun` state on individual test outcomes.

**Test outcomes have four states only:** `pass`, `fail`, `error`, `timeout`.

**Three test tiers:** `public` (shown immediately), `release` (hidden until
deadline), `secret` (never shown). There is no `student` tier, and the MCP
tier prose is derived from `TestTier.allCases` (`Sources/APIServer/MCP/CLAUDE.md`).
Student-contributed tests do not want a tier: the suite is instructor-authored,
and a student's contribution is submission content, not a suite entry — see
[docs/collaborative-class-assignments.md](docs/collaborative-class-assignments.md).

**Gamification fields are present from day one but nullable.** `memoryUsageBytes`,
`attemptNumber`, `isFirstPassSuccess` are in the schema now so we never need a
migration later. They can be null/zero until the feature is built.

**Subprocess boundary for all language execution.** Swift never imports a JVM,
Python interpreter, or any language runtime. Everything goes through
`Process` + sandbox (`ScriptRunner`, `Sources/Worker/CLAUDE.md`).

**Browser grading has four substrates, routed per script (#1271).**
`RoutingExecutor` in `Public/grading-executors.js` sends each script to the xeus
kernel for its language. It classifies with the same `RunnerCore.classifyScript`
that the native worker uses. It boots only the runtimes that the assignment
contains. `RunnerCore` owns the suite loop and output interpretation for all
four; a substrate only runs a script and reports its exit code and streams. See
`docs/architecture.md`. xeus-r is the only route to in-browser R; its masks and
its one-top-level-expression rule are in `docs/r-support.md`. Every worker the
notebook page spawns must be in `NotebookAssetIsolationMiddleware.isolatedWorkerScripts`
(`Sources/APIServer/CLAUDE.md`).

**Assignment languages.** Seven ship. `LanguageDescriptor`
(`Sources/Core/LanguageDescriptor.swift`) holds the facts per language, and MCP
`get_server_info` reports them, with the refused kinds and a reason for each.

| Language | Editor | Generated test | Doc |
|---|---|---|---|
| Python | xeus-python kernel | `.py` | `docs/architecture.md` |
| R | xeus-r kernel | `.R` | `docs/r-support.md` |
| Lua | xeus-lua kernel | `.lua` | `docs/archive/xeus-kernel-postmortems.md` |
| Octave | xeus-octave kernel | `.m` | `docs/archive/xeus-kernel-postmortems.md` |
| C++ | upload-only (a decision) | `.sh` wrapper | `docs/cpp-support.md` |
| Racket | upload-only (no kernel exists) | `.rkt` | `docs/multi-language-audit.md` |
| Java | upload-only (both reasons) | `.sh` wrapper | `docs/java-support.md` |

An upload-only language also sets `submissionMode: "uploadOnly"`. There is no
third "both" value (`TestProperties.swift`). Which check kinds each language
refuses, and why: `docs/authoring-parity.md`. The kernel traps (masking the exit
call, one quirk per kernel) are in `Tools/jupyterlite/CLAUDE.md`.

- **`.sh` carries no language signal.** To ask whether a language generates a
  `.sh` wrapper, read `LanguageDescriptor.generatesLanguagelessWrapper`. Do not
  write `language == .cpp`.

**Every assignment declares its language. Nothing infers one (#1331).**
`resolve(manifest:)` returns `manifest.language` and nothing else. A nil
language means that the author said "none": a suite of hand-written scripts.
**Do not reintroduce inference.** If a call site does not know the language,
ask the author. `AssignmentLanguage.derivedDeclaration` runs only at two
boundaries, and each records the result at once. See
[docs/language-declaration.md](docs/language-declaration.md).

- **No function may default a `language:` parameter.**
  `scripts/no-language-defaults.sh` enforces this in `format-lint`.
- **Fail loudly while authoring. Never fail while grading, rendering a page or
  extracting a student's submission.** Every remaining `?? .python` follows this
  rule; the per-site table is in `docs/language-declaration.md`.

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

**Roles are two-level: a deployment role plus a per-course role (#417).**
The deployment-global `UserRole` on `APIUser` is just `user` | `admin`
(plus the non-human `mcp` service-account role). Teaching authority is
**per-course**: each enrollment row carries a `CourseRole` (`student` < `ta` <
`instructor`), so one account can be an instructor in one course and a student
in another. TAs author content and grade but cannot manage enrollment,
deadlines, archival or staff. `AUTH_MODE` selects local, SSO (OIDC) or both.
The gates, the session rules and the SSO details are in
`Sources/APIServer/CLAUDE.md` and `docs/multi-course-roles.md`.

**A course is one offering: a code plus a year and a term.** A bare code can
name more than one active course. **Do not add a code-only lookup.** See
`Sources/APIServer/CLAUDE.md` and [docs/course-terms.md](docs/course-terms.md).

**No inline script (#1516).** The CSP rule is in `Sources/APIServer/Views/CLAUDE.md`.

**Every env var the server reads flows through `AppConfig`**
(`Sources/APIServer/CLAUDE.md`). The rule against new variables is in "What Not To Do".

**The MCP server never exposes student data, with one gated exception.** The
AI-assisted feedback tools read written answers only behind a course gate and
an assignment gate, and no MCP tool may set either gate. See
`Sources/APIServer/MCP/CLAUDE.md`.

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
(`TestSuiteEntry.failureDetail`: `full` | `actualOnly` | `verdictOnly`). The
server applies it when it shows results. The script never applies it. Staff
always read the full text. See [docs/failure-detail.md](docs/failure-detail.md).

---

## Data Models

The source is the reference; this section names where each type lives and the
rules the code alone does not state.

- `TestStatus` — `Sources/RunnerCore/TestStatus.swift` (the four states in Key
  Design Decisions).
- `TestTier` — `Sources/RunnerCore/TestTier.swift`: `public` (`.pub`),
  `release`, `secret`.
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

## JupyterLite

Chickadee embeds JupyterLite at `Public/jupyterlite/`, which is generated output
and is checked in. Every browser grader and every editor kernel is xeus (#1271,
done). The config and the rules for the vendored kernels are in
`Tools/jupyterlite/CLAUDE.md`; the measurements are in
[docs/jupyterlite.md](docs/jupyterlite.md) and
`docs/archive/xeus-python-grading-*`.

Read `Tools/jupyterlite/CLAUDE.md` before you change `Public/jupyterlite/`,
`Public/vendor/`, a kernel environment file, `scripts/build-jupyterlite.sh`,
`scripts/check-xeus-vendored.sh`, a `scripts/patch-*.py` file or
`.github/workflows/revendor-kernels.yml`. Claude Code does not load it by
itself for those paths.

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

- Swift 6, strict concurrency. Every target also turns on the upcoming
  features `ExistentialAny` (write `any P`), `MemberImportVisibility` (import
  each module whose members a file uses), `InternalImportsByDefault` (write
  `public import` where a public API shows another module's type),
  `InferIsolatedConformances` and `ImmutableWeakCaptures`, through
  `sourceSettings` in `Package.swift`. `NonisolatedNonsendingByDefault` waits
  for the Vapor 5 move (#1523). Import the umbrella modules `Foundation` and
  `NIOFoundationCompat`, not the split `FoundationEssentials` and
  `NIOFoundationEssentialsCompat` modules that a fix-it suggests on Linux. No `@unchecked Sendable`, in `Sources/` or
  `Tests/`, except on a Fluent `Model` class, where the reason is always the same (Fluent's property
  wrappers are what the compiler cannot check). Use an actor or a `Mutex`
  instead. `scripts/check-unchecked-sendable.sh` fails `format-lint` on any
  other site, with or without a comment.
- Strict memory safety (SE-0458) is on for every target, tests included
  (`sourceSettings` in `Package.swift`), so an unsafe construct without an
  `unsafe` mark does not build. Use a safe API first: swift-system
  (`FileDescriptor`, `FilePath`, `Stat`, `Errno`) for POSIX calls, a NIO type for
  addresses. A `String` given to a C function is an unsafe pointer conversion,
  and so is `FileManager.fileExists(atPath:isDirectory:)`. Mark `unsafe` only
  where no safe API exists, with a comment that says why.
- `async/await` throughout. No completion handlers.
- Swift APIs over their Foundation predecessors: a regex literal or `Regex`, not
  `NSRegularExpression`; `FilePath`, not `NSString` path calls;
  `Task.sleep(for:)`, not `Task.sleep(nanoseconds:)`. SwiftLint enforces these in
  `Sources/` and `Tests/`. `Regex` is not `Sendable`, so a shared pattern is a computed
  static property, not a stored one.
- Actors for any shared mutable state (`WorkerSecretStore`, `WorkerActivityStore`,
  `LocalRunnerAutoStartStore`, `LocalRunnerManager`).
- All models in `Core/` must be `Codable`, `Sendable`, and have no Vapor imports.
- Error types are explicit enums, not `String` or generic `Error` where avoidable.
  Every thrown error is a domain enum: not Vapor's `Abort(...)`, not a
  `String`. Declare `throws(E)` where the set of errors is closed: validators,
  parsers, `Core`, `RunnerCore`, the runner's normalizers, and any function
  whose caller catches one error type. Keep untyped `throws` only where
  Fluent, Vapor, Foundation or NIO errors pass through, for example route
  handlers and database code. The LTI validators (`throws(LTILaunchError)`)
  show the shape.
- No force unwraps except in tests.
- Optionals are preferred over sentinel values (no `-1` for "missing").
- File names match the primary type they contain.
- One type per file unless the types are trivially small and closely related.
- `swift-format` owns formatting (`.swift-format`); SwiftLint owns correctness
  (`.swiftlint.yml`, from the `SwiftLintPlugins` dependency). Overlapping rules
  are off in `.swiftlint.yml`. Both apply to `Tests/`, and CI runs both in the
  `format-lint` job. Run `scripts/format.sh` before you commit; `scripts/lint.sh`
  and `scripts/swiftlint.sh` only check.
- Each `.swift-format` names every rule, `true` or `false`. A rule that the
  file omits is off, not at its default. `scripts/check-swift-format-config.sh`
  enforces this.
- `scripts/swiftlint.sh` passes `--strict`: every warning fails the build. If a
  structural threshold (for example `function_body_length` at 100 lines)
  causes real friction, raise it in `.swiftlint.yml`. Do not drop `--strict`.

---

## UI / Stylesheet Conventions

The UI rules are in `Sources/APIServer/Views/CLAUDE.md` and
[docs/ui-design.md](docs/ui-design.md). They include `scripts/check-styles.sh`
before a push and the unconditional `ui-review` run.

---

## Subagents and Hooks

The subagents are in `.claude/agents/`. Each one reports and does not edit.
- After a code change, run `test-runner` with a filter for the suites that the
  change affects. Run it with no filter once before a push.
- After a change to an Elementary view, `Public/styles.css` or a `Public/*.js` file, run `ui-guard`. Run `ui-review` too.
- For the state of the whole UI, run `ui-audit`. It applies the usability
  heuristics in `docs/ui-design.md` across all pages. CI runs it each month
  (`.github/workflows/ui-audit.yml`) and files the report as an issue.
- For drift between the docs and the code, run `docs-audit`. CI runs it each
  month (`.github/workflows/docs-audit.yml`) and files the report as an issue.
- Before a commit, run `diff-reviewer` on the uncommitted diff.
- Before a commit on a change under `Sources/` or to a `Public/*.js` file, run
  `interaction-review`. It checks the change for side effects on other
  features, with the shared-object map in `docs/feature-interactions.md`. CI
  runs it on each such PR (`.github/workflows/interaction-review.yml`). Its
  verdict is advisory for now. When a change adds a shared object, add its
  row to the map.

The hooks in `.claude/hooks/` do three jobs, so you need not:
- `format-swift.py` runs `swift-format` on each Swift file that you edit.
- `pre-push-format-lint.py` runs `scripts/format-lint.sh` (every step of the CI
  `format-lint` job) before `git push`, and stops the push when a step fails.
  `lint-guard` runs the same script when you want the report earlier.
- `ask-before-test-edit.py` asks the maintainer before any change to an
  existing file under `Tests/`, by an edit tool or by a shell command. The
  project settings allow every other tool call, so this is the only prompt.
  `scripts/test-claude-hooks.py` tests all three hooks in CI.

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
  condition, with a comment that says so. The shared traits (`.ciOnly`, `.requires<Tool>`) live once, in
  `Tests/TestSupport/HostConditionTraits.swift`. `scripts/check-no-skipped-tests.sh`
  fails every CI lane on any skip. A broken test setup throws
  `IssueRecorded("...")`.
- **Pattern references:** `COEPMiddlewareTests` (struct suite),
  `ZipArchiverTests` (class suite), `AdminRoutesTests` (stored `app` with
  `withApp`), `WebRoutesIndexTests` (`with*App` helper),
  `MCPModeScopeContractTests` (parameterized) and `DirectorySizeBytesTests`
  (worker class suite).

---

## Versioning

Semantic Versioning in the `0.y.z` phase. The version is in `VERSION` and
`ChickadeeVersion.current` in Core. What each slot means here is in "What the
numbers mean while we are 0.y.z" in [docs/release-process.md](docs/release-process.md).

**Versions are assigned at merge time. Do NOT bump them in a PR.** A PR must
not touch `VERSION`, `Sources/Core/ChickadeeVersion.swift` or `CHANGELOG.md`.
Hand-edits of those three files made every concurrent PR conflict. Instead:

1. Add **one fragment** under `changelog.d/` (see `changelog.d/README.md`).
   Preview with `scripts/assemble-release.sh --dry-run`.
2. On merge to `main`, `.github/workflows/auto-release.yml` computes the next
   version, folds the fragments into `CHANGELOG.md`, bumps `VERSION` and
   `ChickadeeVersion`, commits `chore(release): vX.Y.Z` and pushes the tag. The
   tag triggers `release.yml` and the tag build in `docker-build.yml`.

**Auto-release is patch-only by construction.** No merge can make a minor or
major bump. A minor (for example 0.5.0) is a manual step:
`scripts/assemble-release.sh --version X.Y.0`, committed as
`chore(release): vX.Y.0` (that prefix stops the auto-release) and tagged from a
human account. See [docs/release-process.md](docs/release-process.md), which
also tells how to enable the optional merge queue.

---

## Deployment & CI/CD (production)

**A green merge to `main` reaches production on its own,** in about 10 to 15
minutes, with zero downtime. `auto-release.yml` tags the release,
`docker-build.yml` publishes `:latest` and `:sha-<commit>`, and the host-side
`chickadee-deployer` daemon deploys it blue-green (`scripts/bluegreen-deploy.sh`).
A major bump waits for a human. There is no SSH and no manual deploy step.

**Verify a fix is live with the read-only admin diagnostics MCP**
(`Chickadee_Admin`): `get_deployment_info` for the running version,
`get_deploy_status` / `get_deploy_history` for the daemon, and `list_runners` /
`get_health_alerts` / `query_logs` / `get_browser_diagnostics` for the
behaviour. Deploy control (pause, approve a major, roll back) is host-side by
design. See [docs/zero-downtime-deploy.md](docs/zero-downtime-deploy.md).

---

## Current State

**The 0.4 series is closed.** v0.5.0 marks the end of the first full course
offering on Chickadee. The 0.4 arc is at the top of `CHANGELOG-0.4.md`; the
0.5-boundary cleanup is in the 0.5.0 entry of `CHANGELOG.md`. BrightSpace grade
sync waits for UW IST production credentials. `MCPToolCatalog.live` holds the
MCP tool count.

- **A scanner that cannot tell markup from prose about markup matches its own
  documentation.** This shipped twice in drift guards. Parse structure, and
  describe forbidden syntax instead of quoting it.

**Feature backlog:** more personalization and notebook checks (for example
per-student refs in pattern kinds beyond the three equality kinds); pattern
kinds beyond the ten in `PatternKind`; SSO tests with providers other than
UWaterloo DUO; refresh-token handling; more gamification (badges
beyond First-Try Perfect).

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

[docs/README.md](docs/README.md) is the index of every document in `docs/`.
When you add a document, add its line there.
