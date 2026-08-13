# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project follows Semantic Versioning.

Releases before 0.5.0 (the 0.1.0 – 0.4.669 history, ~660 releases across the
first course offering) are archived in [CHANGELOG-0.4.md](CHANGELOG-0.4.md).

## [Unreleased]

## [0.5.91] - 2026-08-13

### Security

- **A C++ submission that calls `exit(0)` no longer passes every test.** C++ was
  the only language with no exit guard: `ck::passed` is a bare `std::exit(0)`
  and the wrapper `exec`'d the binary, so a student's own `exit(0)` — in an
  error path, which is where an intro submission puts one — exited with status 0
  and every case in the assignment reported a silent pass with no verdict at
  all. The C++ runtime now prints the sentinel line every other compiled
  language's runtime prints, and the wrapper refuses a run that did not emit it.
  The ceiling is stated in both files: student code and the grading runtime
  share one process, so a submission that prints the sentinel itself and exits
  is still a pass — a deliberate act, not the error-path `exit(0)` this catches,
  and the same limit Java's sentinel has.


## [0.5.90] - 2026-08-13

### Changed

- **The notebook page stops repeating its per-request queries.** The
  (user, course) role lookup — asked four times per notebook page load by
  the enrollment guard, the staff check, the effectively-open check, and the
  closed-assignment gate — is now memoized on the request, the same
  per-request caching `resolveActiveCourse` already had; the submit form and
  the submission gate share it (#1382 item 3). Per-student dataset files are
  no longer re-sliced and rewritten on every visit: an unchanged seed, spec,
  and source with all files present skips the work, while a re-seed, a spec
  edit, a re-uploaded source, or a deleted file still re-materializes.


## [0.5.89] - 2026-08-13

### Fixed

- **The runner's compile-and-exec capability probe asks the language for its
  probe program** instead of hardcoding a C++ source file. The old form was
  correct while C++ was the only language needing it and a silent failure for
  the next: C++ source handed to a different compiler fails, the language is
  never advertised, and its jobs queue forever with no error — the worse
  direction of the capability gate. The mapping is exhaustive, so an eighth
  language must answer.
- **The probe now has tests**, in both directions: a usable work root advertises
  C++, and one the probe cannot use withholds C++ while leaving every other
  language advertised.
- **The custom-script scaffold's comment no longer claims a generality it does
  not have.** `capabilityRequiresExecutableOutput` means "grading execs a file
  it just produced", which is C++ alone — Java is compiled and answers `false`,
  so it takes the interpreted branch. Recorded rather than guessed at, and the
  C++ compile line now passes `-std=c++20` to match what generated cases use.


## [0.5.88] - 2026-08-13

### Changed

- **The student dashboard no longer loads the full submission history to render.**
  The per-setup grade/submission maps are now computed by the database — a
  window-function pick for the latest submission + attempt count, and a
  `MAX` over the same grade fraction `gradePercentValue` reads for the best
  grade — instead of materializing every submission and every result the
  student ever made and folding them in Swift, two reads that grew all term
  (#1382 item 2). Badge evaluation now fetches results only for the latest
  and prior attempt per assignment, and the achievements helper reuses the
  setup rows the dashboard already loaded rather than re-selecting them,
  manifest blobs included.


## [0.5.87] - 2026-08-13

### Added

- **`JavaNativeGradingTests`** — Java is upload-only, so the native worker is its
  only grading path, and it was the one language with no test on that path. The
  suite drives the real chain (`scriptInvocation` → `NativeScriptExecutor` →
  `executeSuites` → `interpretScriptOutput`) for a generated `.sh` case, the
  exit-code contract through the sentinel check, and a hand-written `.java`
  suite entry, which is a documented instructor path that nothing pinned.
- **Classification coverage for `.m`, `.rkt` and `.java`**, and for the
  node-before-java shebang ordering — which the classifier's own comment calls
  load-bearing ("javascript" contains "java") and which no test held down.


## [0.5.86] - 2026-08-13

### Changed

- **Docs and comments across the extraction and capability surfaces now name all
  seven languages** rather than the two or three that existed when they were
  written. The operationally important one is
  `docs/runner-capability-profiles.md`, which listed three probed languages out
  of eight — the page an operator reads to answer "why doesn't this runner
  advertise `racket`".
- **The unreachable `.python` arm in the marker-extractor switch is a trap
  rather than a silent alias for R.** It was folded in with `.r`, so a later
  cleanup that merged Python into that group would have extracted every Python
  notebook as R.


## [0.5.85] - 2026-08-13

### Fixed

- **Six shipped UI defects no guard could see.** Section drag-and-drop showed
  no drop indicator (the classes were assigned but styled nowhere); the
  account page's badges, admin-audit's filter form and its `btn--secondary`,
  and admin-brightspace's `tier-public` all referenced classes that exist in
  no stylesheet, rendering unstyled; and a dead `test-output-row-*` class
  family shipped on every submission page.

### Changed

- **Page rendering rules now live in one place and are enforced.**
  `docs/ui-design.md` gains page archetypes and a closed component
  vocabulary; flash banners render only through the new `_flash` partial
  (with ARIA roles — the second, role-less banner dialect is gone); the
  admin/instructor tab bars are shared partials instead of fourteen
  copy-pasted copies; `.admin-section` is renamed `.page-section`; five
  bespoke page-header families collapse onto `.page-titlebar`; and the
  idle-logout dialog's JS-injected stylesheet (nine hardcoded colours, a
  private dark-mode block) moves onto the palette in `styles.css`.

### Added

- **Three new UI drift guards** in the `check-styles.sh` family: every
  assigned class name must resolve to a stylesheet rule (`js-` prefix for
  behaviour-only hooks; interpolated families pinned by a Swift
  `CaseIterable` test), page `<style>` totals and JS styling decisions
  ratchet down only, and the nginx maintenance page's colours must stay a
  subset of the app palette. Visual-regression + axe coverage grows from 6
  to 13 pages — one per archetype — with a shared page list and per-page
  baseline bootstrap.


## [0.5.84] - 2026-08-13

### Fixed

- **`client_diagnostics` is now pruned like every other diagnostics table.** It
  takes a row per browser error, kernel boot failure and grading failover, each
  carrying a message and a full JS stack, from what is the highest-volume
  endpoint the server serves — and nothing ever deleted them. Every neighbouring
  table (`job_execution_metrics`, `runner_snapshots`, `request_metrics`,
  `submission_diagnostics`) already went through the 24-hour observability
  prune; `client_diagnostics` now does too, on the same retention window, using
  the index already present on `created_at`.
- **Indexed the session reaper's sweep column.** The hourly reaper runs
  `DELETE FROM _fluent_sessions WHERE created_at < cutoff`, but the migration
  that added `created_at` added no index — so once an hour the reaper scanned
  and locked the table with the highest read volume in the schema. Added
  `idx_fluent_sessions_created_at`.


## [0.5.83] - 2026-08-13

### Fixed

- **The Python submission path now goes through `SubmissionPolicy` like every
  other language.** The policy file says it is "the shared implementation of the
  notebook guarantees, so both the Python normalizer and the generic extractor
  enforce one standard rather than two" — but Python used a private second
  implementation, so the exemption table governed six languages and Python
  answered to nothing. The two agreed only by coincidence.
- **A skipped guarantee is logged.** The policy documented that an exemption
  "appears in the runner's structured log"; nothing logged it, so an operator
  diagnosing a missing error could find no trace and conclude the check had run.
  Skipping now emits `submission_guarantee_skipped` with the guarantee, the
  language and the stated reason.
- **The Python compatibility copy refuses a non-Python source.** Any `text/*`
  upload classifies as a Python script, so a student who submitted
  `solution.lua` to a Python assignment had it copied to `solution.py` and was
  shown Python syntax errors against Lua source — under a warning claiming a
  copy had been made "from the single detected Python source file".


## [0.5.82] - 2026-08-13

### Fixed

- **Student submission uploads no longer block a cooperative-pool thread on
  disk I/O.** The web upload form and all three notebook submit routes
  (browser-graded result, runner-submit, browser-failover) wrote their file with
  a synchronous `Data.write(to:)`. Vapor handlers run on the Swift cooperative
  pool, which has roughly one thread per core and never grows, so each write
  pinned a thread for its duration while the handler still held the whole body
  in memory — during a deadline burst, which is exactly when these routes are
  hot. They now use `req.fileio.writeFile`, matching the API submission path
  that was already fixed.


## [0.5.81] - 2026-08-13

### Fixed

- **An unparseable runner env var is now reported instead of silently falling
  back.** `RunnerDaemonConfig` documented failing fast on a bad value and did
  the opposite, so `RUNNER_MIN_FREE_DISK_MB=2GB` quietly became the 128 MB
  default and the runner kept claiming jobs onto a nearly-full volume — the
  ENOSPC failure that setting exists to prevent. A value that is set but
  unparseable now emits `runner_config_parse_failed` naming the variable, the
  raw text and the default being used.
- **The retry delays are clamped at the boundary.** `RUNNER_RETRY_BASE_DELAY_MS`
  feeds an unchecked `base * 2^attempt` that trapped the runner on its first
  retry for a large enough value, and a negative `RUNNER_RETRY_MAX_DELAY_MS`
  produced a negative sleep, turning the retry loop into a spin against the API
  server.


## [0.5.80] - 2026-08-13

### Fixed

- **The nginx body cap no longer sits below the app's own upload limits.**
  Both sample vhosts capped request bodies at 50 MB while the app declares 300
  MB for test-setup zip upload, so a large test setup was rejected by nginx with
  a bare 413 before the app saw it — and the app-side limit read as though it
  were in force. Raised to 512 MB, including in the commented HTTPS block that
  operators uncomment in production, which carried the same cap. Course-bundle
  import's 2 GB backstop is deliberately not matched, and both sides now say so.
- **The systemd unit runs the server in production mode.** It invoked
  `chickadee-server serve` with no `--env`, so a bare-metal deploy took Vapor's
  `development` default and ran with Leaf's template cache disabled, re-reading
  and re-parsing every template on every page render. The Docker entrypoint
  already passed `--env production`; the unit file now does too.
- **Corrected the nginx compression comment.** It claimed Chickadee serves
  pre-compressed `.br`/`.gz` variants for the largest assets. It does not —
  there is no `gzip_static`, no build step producing them, and the only `.gz`
  files shipped are conda kernel tarballs. The comment now describes what
  actually happens, including that a cold multi-MB wasm fetch is gzipped on the
  fly each time.


## [0.5.79] - 2026-08-13

### Fixed

- **Java assertions now run in generated tests.** `javaGuarded` documents
  catching a student's `assert`, but the JVM was launched without `-ea`, so
  assertions were disabled and a submission proceeded with its precondition
  unchecked — the opposite of what the comment promised.
- **A Java verdict message keeps its non-ASCII characters.** `System.out` uses
  the host's `native.encoding` (ASCII on a container with no `LANG`), so a
  failure quoting a student's accented output reached the runner with `?` in
  place of every non-ASCII character. Verdicts are written through an explicit
  UTF-8 stream on the real stdout. Comparisons were never affected.
- **`javac` is given `-encoding UTF-8`** in the personalization driver as well
  as the test wrappers. Generated Java source is unconditionally non-ASCII, and
  while javac defaults to UTF-8 on JDK 18+ regardless of locale, the repo
  supports Java 11+, where it does not.


## [0.5.78] - 2026-08-13

### Fixed

- **Two pattern families can no longer claim the same generated filename.** Only
  family-vs-hand-written collisions were checked, so a squashed stem — the stem
  is `<familyID>_<caseKey>`, and family `a_b`/case `c` collides with family
  `a`/case `b_c` — let one family's generated files silently replace the
  other's on apply, losing a family's cases with no error. Refused at save time
  now, naming both families.
- **A reference implementation containing the generated wrapper's heredoc
  delimiter is refused at save time.** The heredoc is quoted, so `$`, backticks
  and backslashes in an instructor's reference are already inert — but a line
  reading exactly `CHICKADEE_GENERATED_SOURCE` ended it early and ran the
  remainder as shell.
- **The generated C++ wrapper quotes its own filenames**, and drops a `.ck_*`
  case arm that never matched anything (POSIX `*` does not match a leading dot,
  so the wrapper's own dotfile artefacts were never candidates) rather than
  leaving it reading as a guard.

### Fixed

- **Lua and Octave kernel boots now take the editor asset fast path.** The
  fast path's allowlist was a hand-written list naming Python and R, so a Lua
  (19 MB) or Octave (142 MB, the largest env shipped) kernel boot sent every one
  of its ~50 package tarballs through the full middleware chain — session
  lookup, user lookup, activity middleware — that the fast path exists to skip.
  It failed open, so nothing broke and no test noticed; the boot was just
  needlessly expensive. The prefixes are now derived from
  `AssignmentLanguage.allCases`, so a seventh language needs no edit here, and a
  new test reads the vendored tree on disk and fails if any shipped kernel is
  missing from the list.


## [0.5.77] - 2026-08-13

### Fixed

- **A Java submission whose method is not `static` (or is `private`) now fails
  the existence guard with a message saying so.** The guard matched on name
  alone, so it passed — and then every scored case failed to compile with
  "non-static method cannot be referenced from a static context", reporting
  `error`. The one test whose job is to explain the problem said everything was
  fine.
- **A missing C++ submission is a graded failure, not a harness error.** The
  0-point existence guard reported `error` where Java reported `fail` for the
  same student state, because C++'s no-submission check ran before the compile
  step that Java routed through.
- **Compiler warnings no longer appear in a passing test's output.** Both
  wrappers sent the build stream straight to stderr, so javac's "unchecked or
  unsafe operations" note and any g++ warning rode a *successful* compile into
  the student's `longResult`. The build log is now emitted only when the compile
  fails.
- **A C++ or Java harness error no longer borrows the student's last line as its
  summary.** Neither `errored` emitted a `shortResult` footer, so the shell
  contract fell back to the last stdout line — a student's stray `print` became
  the one-line summary of, for example, a failing reference implementation.


## [0.5.76] - 2026-08-13

### Fixed

- **A page view no longer rewrites its own session row.** Vapor's session
  middleware has no dirty flag, so it called `updateSession` on the way out of
  every request that arrived with a cookie — an `UPDATE` on `_fluent_sessions`,
  the table every authenticated request already reads, to store back the bytes
  it had just read. The Fluent driver is now wrapped so an untouched session
  skips the write. Sessions still write on the requests that actually change
  them (login, the OIDC handshake, an active-course switch, a stashed draft
  form), and lifetime is unaffected: the driver only ever set the data column,
  with expiry coming from `created_at` and the idle timeout enforced against
  the user row.
- **The two-second submission poll no longer writes a metrics row per poll.**
  A student's result view polls the submission-status route every two seconds
  while grading is pending, which during a deadline makes it the
  highest-frequency request the server takes — and each one persisted an
  `api_request_metrics` INSERT on the response path. It is now excluded the
  same way idle runner check-ins already were. Errors still record, and
  `/results`, `/download` and the collection route are untouched.


## [0.5.75] - 2026-08-13

### Security

- **A student's upload can no longer replace the tests it is graded by.** The
  runner executes the suite's scripts out of the same directory the submission
  is merged into, and the merge wrote every student file by its own name over
  whatever was already there — so a zip containing `publictest_bmi_01.py`
  overwrote the instructor's generated test and was graded against itself.
  Generated filenames are deterministic and public-tier names are visible to
  students, and the submit form accepts `.zip`, so this was reachable from the
  ordinary student path. Both normalization paths now refuse a file whose
  workspace path belongs to the test setup (the suite's scripts, the runtime
  helpers, the per-student inputs file and the student-module hints) and warn
  the student by name rather than dropping it silently. `requiredFiles` are
  deliberately not protected — those name what the student must supply.


## [0.5.74] - 2026-08-13

### Fixed

- **Queue bookkeeping no longer gets slower as the backlog deepens.** The
  `queue_depth` diagnostic loaded every pending student submission into memory
  on every job claim and every accepted submission, then issued one test-setup
  lookup and manifest decode per distinct assignment — so a deep queue, or a
  retest fan-out flipping tens of thousands of rows back to pending, made each
  claim and each intake progressively more expensive. It is now two SQL
  aggregates plus one batched grading-mode lookup, costing what the number of
  distinct pending assignments costs rather than what the queue depth costs.
  The reported number is unchanged.
- **Indexed the worker claim query's fresh-work-first split.** Claims ask for
  pending student work with `retested_at IS NULL` before falling back to
  retests (#427), but the existing submissions index stopped at `submitted_at`.
  A retest-dominated queue — precisely the case that split exists to handle —
  made every poll walk the whole pending range. Added
  `idx_submissions_claim_priority` covering `(status, kind, retested_at,
  submitted_at)`.


## [0.5.73] - 2026-08-13

### Fixed

- **A dotfile script name no longer slips past the runner capability gate.**
  `AssignmentLanguage` treats a base name beginning with `.` as extensionless,
  but the runner's own classifier rejected only a name whose *only* dot was
  leading — so a suite entry like `.hidden.lua` required no Lua of the runner
  that claimed the job, and was then dispatched to `lua` anyway, dying at
  `exit 127` in front of a student. The two scanners now apply the same rule,
  held together by a differential test.


## [0.5.72] - 2026-08-13

### Fixed

- **A C++ `exceptionExpected` case now matches the exception's type, not only
  its message.** The save-time validator asks authors to name the exception
  class, and C++ compared the authored text against `what()` alone — so a
  student correctly throwing `std::invalid_argument("n must be positive")`
  against an authored `invalid_argument` was marked "wrong error raised". The
  type name is folded into the reported text, so the "got:" line now names it
  too. Java and Python already matched on type.
- **A C++ submission that throws something other than a `std::exception` is a
  graded failure instead of a crash.** `throw "text";` and `throw -1;` — what an
  intro course teaches before `<stdexcept>` — escaped the generated handler and
  aborted the process, which the runner reported as `error` with a raw
  `terminate called after throwing` on stderr. The same submission in Java has
  always been a clean fail.


## [0.5.71] - 2026-08-13

### Fixed

- **Generated C++ and Java tests compile for `void` targets.** A C++
  `performanceThreshold` bound its call with `auto result = …` and a Java
  `exceptionExpected` used an expression lambda, so timing a `void render(int)`
  or expecting a throw from a `void withdraw(double)` failed to compile and
  reported every case in the family as `error` — while the 0-point existence
  guard still passed, so nothing pointed at the family.
- **Instructor `expected` text is escaped before it reaches generated C++ and
  Java source.** Every other language escaped it; these two interpolated it raw,
  so an expectation of `must be "positive"` or `C:\input` broke the generated
  string literal. Existing generated bytes are unchanged — escaping is the
  identity on ordinary text — so no assignment's cache is busted.


## [0.5.70] - 2026-08-13

### Fixed

- **A C++ or Java submission that throws during a `stdoutEquality` test now
  reports its real failure.** Both runtimes install a stdout capture that was
  only undone on the success path, so an exception unwound past the restore and
  the verdict was written into the capture instead of to the runner. C++ students
  saw a bare "failed" with no reason; Java students saw an `error` blaming a
  `System.exit` they never called. `ck::CaptureStdout` now restores in its
  destructor and `ck.passed`/`failed`/`errored` restore before printing, so a
  verdict always reaches the runner.


## [0.5.69] - 2026-08-12

### Fixed

- **Every author-supplied name is now held to the assignment's own language, not
  a cross-language subset.** Global and section input names, family variables,
  parameter names and `variable_equality` case variables all now use
  `isValidIdentifier(_:language:)`, so an R author may name an input `my.df` and
  a Racket author `bmi-value`.

  Two of those could not be widened before, because the parsers that REFERENCE
  them each carried their own copy of a grammar — `{{name}}` in
  `NotebookSubstitution` and `$name` in `pattern-family-editor.js`, both matching
  `[A-Za-z_][A-Za-z0-9_]*`. A name outside that set failed as a silent misread
  rather than a refusal: `$bmi-value` fell through as a literal string (a wrong
  expected value in a generated test) and `{{my.df}}` survived into every
  student's notebook as text.

  Rather than teach those parsers the grammar, they stopped having one. Both are
  now permissive token grabs, and the ten hand-written copies of the `$name`
  regex became a single constant. Deciding whether a token is a legal name is
  the validator's job, and it already answers per language, exhaustively, with
  the compiler enforcing that a new language cannot be missed. Racket settles
  the point: its grammar is a negative rule — anything but whitespace, reader
  delimiters, a leading `#`, or something that parses as a number — which no
  character class expresses, so a per-language regex in the browser was never
  going to be correct anyway.

  The editor's inline check went permissive for the same reason: the server
  answers per language, so a fixed rule in the browser can only drift from it.

- **Reserved words are now refused in the language that reserves them.** A C++
  assignment could take an input named `template` (Python has no such keyword)
  and then render `inline const auto template = …`, which does not compile;
  likewise `class` on a Java assignment, whose inputs become `public static
  final` fields. The C++ renderer's comment already asserted these were "refused
  by the cpp validator" — the inputs path was calling Python's, so that was an
  intention rather than a fact. It is a fact now.


## [0.5.68] - 2026-08-12

### Fixed

- **Pattern-family parameter names and `variable_equality` case variables are
  now checked against the assignment's language, not Python's.** The previous
  release made a family's `functionName` language-aware and stopped there,
  leaving sibling names in the same file still validated with
  `isValidPythonIdentifier` on every assignment. A Racket author could finally
  save `bmi-category` as the target and was then refused on the parameter
  `bmi-value`, with a message naming Python. Both now use
  `isValidIdentifier(_:language:)` — which already existed, `private`, in
  `NotebookCheckKindHandler.swift`: it was written for notebook checks and never
  shared, so nothing was missing, it was out of reach. The refusal names the
  assignment's language.

  Two name kinds keep the `[A-Za-z_][A-Za-z0-9_]*` rule, and the comments around
  them now say why in terms that are not Python's: global/section **input**
  names, referenced from a notebook as `{{name}}`, and family **variables**,
  referenced from an arg cell as `$name`. That character set is the
  cross-language subset, pinned by the weakest emitter rather than by Python's
  semantics — R backticks an awkward name and Lua/Octave mangle one, but the
  Python preamble writes `name = _ck["name"]` with no emitter, so a hyphen is a
  syntax error. Widening them is therefore not "make it language-aware" (a
  placeholder is replaced by a literal value and reaches no runtime); it is
  giving Python an emitter like the other four have, then widening the two
  reference parsers with it.


## [0.5.67] - 2026-08-12

### Fixed

- **Every deploy since v0.5.65 crash-looped at boot, and the cause was a user
  ID.** The image creates its application user with `useradd --system`, which
  allocates the highest free system ID counting DOWN from 999 — so the ID it
  lands on depends on how many system users the packages installed above it
  happened to create. Adding `default-jdk` for Java claimed two of them and
  moved the application user from **999 to 997**. The production data volume is
  owned by 999 and `.mcp-signing-key` is mode 0600, so the new container could
  not read its own MCP signing key: the server exited fatally before serving a
  request, `--restart unless-stopped` restarted it, `/health` never answered,
  and the blue-green gate correctly aborted every attempt for hours while the
  previous version kept serving. The UID and GID are now pinned to 999 and
  created before any package install can claim them, and the image smoke test
  asserts the UID so this cannot drift again.

  No test downstream of the image could have caught it: a fresh volume takes
  whatever UID writes it first, so the same image is healthy in seconds in CI
  and fatal on a host that already has data. The check has to be on the image
  itself, which is where it now is.

- **A failed blue-green deploy no longer deletes the evidence.** When the health
  gate failed, `bluegreen-deploy.sh` force-removed the container before anything
  read its logs — the only record of why the boot failed. Its output is now
  captured to the deploy state directory and echoed into the journal before the
  cleanup runs. The free-space line printed on every deploy was also broken by a
  quoting bug (`awk: backslash not last character on line`) and had never shown
  a value.

### Fixed

- **No Java or Racket pattern family could be saved at all.** A family's
  `functionName` was validated with `isValidPythonIdentifier` on *every*
  assignment, whatever its language. Java has no free functions, so its target
  is a qualified `Class.method` — and the dot fails Python's rules, while
  `docs/java-support.md` requires the qualified form, making the two rules
  mutually exclusive. Racket's idiomatic `bmi-category` fails on the hyphen. The
  refusal named Python on assignments with no Python in them.

  It stayed invisible because both renderers were written believing the check
  was already language-aware and so neither shouts: `PatternFamilyRendererJava`
  calls its unqualified branch "unreachable through authoring", and the Racket
  renderer quietly sanitizes an invalid name to `ck-invalid-name`. The check now
  dispatches on the assignment's declared language and delegates each arm to the
  grammar that language's own renderer uses, so what validation accepts and what
  rendering can emit cannot drift. The four languages that share Python's rule
  keep their exact previous behaviour.

  Found by authoring the first real Java assignment rather than by any test,
  which is the note worth keeping: the language arc shipped seven languages and
  five sample assignments, and the two languages with no sample are exactly the
  two that were broken.


## [0.5.66] - 2026-08-12

### Fixed

- **Every deploy since v0.5.65 crash-looped at boot, and the cause was a user
  ID.** The image creates its application user with `useradd --system`, which
  allocates the highest free system ID counting DOWN from 999 — so the ID it
  lands on depends on how many system users the packages installed above it
  happened to create. Adding `default-jdk` for Java claimed two of them and
  moved the application user from **999 to 997**. The production data volume is
  owned by 999 and `.mcp-signing-key` is mode 0600, so the new container could
  not read its own MCP signing key: the server exited fatally before serving a
  request, `--restart unless-stopped` restarted it, `/health` never answered,
  and the blue-green gate correctly aborted every attempt for hours while the
  previous version kept serving. The UID and GID are now pinned to 999 and
  created before any package install can claim them, and the image smoke test
  asserts the UID so this cannot drift again.

  No test downstream of the image could have caught it: a fresh volume takes
  whatever UID writes it first, so the same image is healthy in seconds in CI
  and fatal on a host that already has data. The check has to be on the image
  itself, which is where it now is.

- **A failed blue-green deploy no longer deletes the evidence.** When the health
  gate failed, `bluegreen-deploy.sh` force-removed the container before anything
  read its logs — the only record of why the boot failed. Its output is now
  captured to the deploy state directory and echoed into the journal before the
  cleanup runs. The free-space line printed on every deploy was also broken by a
  quoting bug (`awk: backslash not last character on line`) and had never shown
  a value.


## [0.5.65] - 2026-08-11

### Added

- **Java is the seventh assignment language.** `AssignmentLanguage.java` —
  upload-only and native-worker-only like C++ and Racket, with no editor kernel
  (the request was explicitly for no REPL or notebook workflow, and a browser
  kernel would grade a different toolchain than the course's `javac`). All nine
  pattern-family kinds render and execute; per-student `=` expressions evaluate
  through a `javac`-based server driver sharing the same Horner seed fold as
  every other language; notebook checks are refused categorically at save time
  with a stated reason. Generated cases are POSIX shell wrappers that compile
  with `javac` and run with `java` (~0.6 s per test, measured), so no
  per-language build strategy enters Swift. A JDK (`default-jdk`) is now on the
  application and CI images.

### Changed

- **The `.cpp`-shaped forks in language handling are now derived.** Six places
  asked `language == .cpp` when they meant "does this language's generated case
  carry no language signal?" — a question Java answers the same way. They read
  `LanguageDescriptor.generatesLanguagelessWrapper` instead, and the
  `generatedScriptExtension` uniqueness pin exempts exactly those languages
  rather than naming C++.

### Fixed

- **A notebook check on any assignment could be refused as colliding with
  itself.** The generated-filename collision scan flat-mapped names across every
  language without deduplicating, so as soon as two languages shared a generated
  extension one check produced the same filename twice and tripped the
  duplicate-name guard. Found by adding the second such language.
- **`differentialReferenceName` could produce an illegal identifier.** It
  interpolated the family's function name directly, which is a qualified
  `Class.method` for Java — yielding `ck_ref_Solution.f`, a name that no
  generated test could compile and no instructor could define, in both the
  renderer and the save-time validator that checks for it. Dots are now
  sanitized to underscores.


## [0.5.64] - 2026-08-11

### Changed

- **The add-a-kernel runbook no longer tells you to register your kernel with a
  map that does not exist.** Step 4 still described `check-xeus-vendored.sh` as
  carrying a literal `expected_language` and instructed you to add an entry to
  it — a step that predates the guard being derived from
  `editorSupport.notebookKernel(kernelName:)`, and one the same document's
  parity checklist already listed as free. It now says there is nothing to
  register, and gives the check that matters instead: confirm the derivation
  actually lists your kernel, since a derivation over source can go partial
  without going loud. The two rules that fall out of it going partial — assert a
  derivation's completeness, and read the mapping the compiler already forces to
  be exhaustive rather than inferring one from line proximity — are recorded
  alongside the existing enumerated-not-discovered traps, together with the
  reason it stayed invisible: a guard whose answer depends on the event it runs
  under is not a guard.


## [0.5.63] - 2026-08-11

### Fixed

- **The vendored-kernel guard stopped reading the language descriptors, and CI
  had been red on `main` for five releases.** `check-xeus-vendored.sh` derives
  which kernels to expect from `LanguageDescriptor`, but it paired them by line
  PROXIMITY — the nearest preceding `case .X:` owned the next `kernelName:`.
  When #1330 hoisted each descriptor into its own `static let`, the six
  consecutive `case .X: return Self.XDescriptor` lines left `.racket` current,
  the first kernel name found (`xpython`) was attributed to it, and `xr`, `xlua`
  and `xoctave` were discarded — so the guard reported three of the four
  vendored kernels as claimed by no language, and mapped the fourth to the wrong
  one. The vendored tree was healthy throughout; only the parse was wrong. It
  now reads the language set from the exhaustive `descriptor` switch and each
  language's own descriptor literal, and refuses to proceed on a descriptor it
  cannot classify — a partial derivation was previously indistinguishable from a
  complete one, which is the same fails-open shape the guard exists to catch.

- **The JupyterLite guards now run on pull requests, not only on `main`.** Their
  path filter skipped them for any PR touching no JupyterLite file while still
  reporting the job green, and `push` to `main` always counted as relevant — so
  the guards effectively ran only after merge. That is why the broken derivation
  above was invisible: every PR was green, every push to `main` was red, and the
  two were never running the same check. The filter was written to skip an
  expensive rebuild that no longer exists (CI cannot rebuild the kernels; the
  committed bytes are authoritative), so it was saving one Python setup and
  costing the merge-time signal. All three guards run unconditionally now; they
  take well under a second.


## [0.5.62] - 2026-08-11

### Changed

- **A class-goal bonus is now true extra credit, uncapped.** It used to be capped
  at 100% of the suite total, which made the reward invisible to exactly the
  students who earned it: a goal conditioned on "N% of the class reaches 100%"
  leaves most of the class at full marks, where the cap absorbed the whole bonus.
  (HLTH 230 Lab 9: a +1 bonus worth 25% of a 4-point suite showed up as no change
  at all for the majority.) A student at full marks now reads above 100% on the
  submission page, in the grades CSV, and in LEARN. The grades CSV had grown its
  own copy of the cap inline; all three grade-of-record sites now call the single
  shared helper.

### Fixed

- **A class-goal bonus now reaches LEARN at all.** The bonus scales with live
  class progress, but a BrightSpace push is only ever queued by an event on a row
  — a new result, an instructor override, or the manual "Push all" — and class
  progress moving queued nothing. So each student's LEARN grade froze at whatever
  share of the class had reached the goal *at the moment their own submission was
  graded*, leaving the earliest submitters under-credited permanently, while
  Chickadee's own pages (which compute the bonus live) showed the full amount.
  The class-goal sweep now re-queues every student's grade for one push when a
  points-rewarded goal **freezes at the deadline** — the moment the final bonus
  exists. It fires once per assignment, is gated on the assignment being bound to
  a LEARN grade item and not excluded from sync, and leaves the live window alone
  (a goal still moving would otherwise re-push the whole class every sweep). An
  assignment with no due date never freezes, so "Push all" remains the way to
  settle its bonus.

- **A grade push above a LEARN item's maximum is now reported.** D2L's
  `CanExceed` flag was decoded onto `BrightSpaceGradeObject` but never consulted.
  Uncapped extra credit makes an above-max push reachable by design, and it is
  the one way the bonus can be computed correctly and still not appear in LEARN,
  since D2L may clamp or reject the value. The push still goes out — a clamped
  grade beats no grade — and the sync-activity log's success row now names the
  item, its maximum, and the fix (tick "Can Exceed" on the grade item).


## [0.5.61] - 2026-08-11

### Fixed

- **Adding a hand-written test script in another language no longer migrates the
  assignment.** Authoring one `helper_test.R` into an assignment declared as
  Python re-rendered every generated test in R, deleted the `.py` ones, and
  rewrote the manifest's language — a migration nobody asked for, triggered by
  adding a helper, and asymmetric (a `.py` helper could never flip an R
  assignment). It also went around the guard that refuses a language change once
  generated tests exist. The declaration is now what decides, and changing it is
  the language dropdown's job.
- **A runner can no longer claim a job it can only partly grade.** The claim gate
  required just the assignment's declared language, so a `.R` script inside a
  Python assignment could be claimed by a runner with no R and die at
  "Rscript: not found" in front of a student — the exact failure the gate exists
  to prevent. It now requires every language the suite actually uses. A suite of
  plain shell scripts still runs anywhere, as it always has.

### Changed

- **Written down: a declared language is not exclusive.** Shell is the substrate
  every assignment sits on, and a suite may legitimately mix languages — the
  runner classifies each script on its own and stages every language's test
  runtime, so an `.R` helper in a Python assignment has always run under Rscript.
  The declaration governs what Chickadee *generates*; the script's own extension
  governs how it *runs*. `CLAUDE.md` and `docs/language-declaration.md` now say
  so, along with why "None" is not a shell language case.


## [0.5.60] - 2026-08-11

### Fixed

- **A suite save no longer rewrites a "None" assignment's language to Python.**
  Every suite save runs through the pattern-family apply path, which recorded
  whatever language it resolved — and that resolution ended in a Python
  fallback. Reordering two shell scripts on an assignment whose author chose
  "None" therefore declared it Python, silently and stickily. The apply path now
  carries the declaration as an optional and persists it unchanged.
- **The new-assignment page no longer erases the language it just asked for.**
  The manifest builder writes a fresh object, so the draft's suite actions and
  the publish rebuild dropped both `language` and `languageDeclared` on the
  floor — the author picked R, uploaded a suite, and the choice was gone. Both
  fields are threaded through every rebuild.
- **`update_solution` no longer checks a solution filename against Python's
  extensions on an assignment that declares no language**, which accepted
  `solution.py` and rejected everything else for a reason nothing in the
  assignment supported.

### Changed

- **Authoring refuses, with a message naming the fix, where it used to guess
  Python.** Adding a pattern family or notebook check, and storing a per-student
  `=` expression, now require the assignment to declare a language: a generated
  test and an expression are both source code, and an assignment set to "None"
  has no syntax to write them in. Saves that generate nothing — reordering raw
  scripts, editing literal variables — are unaffected, and nothing on the
  grading path refuses: an instructor can fix a missing declaration from the
  dropdown, a student cannot.
- **`docs/language-declaration.md`** records the rule the multi-language arc
  landed on (every assignment declares its language; nothing infers one), the
  doors that enforce it, and a per-site table of the remaining Python fallbacks
  split by whether they sit on an authoring path or a grading one.


## [0.5.59] - 2026-08-11

### Changed

- **Tests no longer write the process environment.** `setenv`/`unsetenv` rewrite
  glibc's `environ` array in place, and a concurrent `getenv` walking it
  segfaults rather than reading a stale value — killing the whole test process
  at a different test each run, which is why it always read as a flake.
  Configuration now reads through `EnvironmentSource`, whose `@TaskLocal`
  override `withTestEnvironment` binds, so a suite that covers env parsing
  supplies an environment instead of mutating the process's. Zero `setenv` calls
  remain in APITests. Production behaviour is unchanged: with no override bound,
  every read falls through to `Environment.get` as before.
- **The seventeen hand-rolled `/usr/bin/zip` test fixtures became one.** Each
  built its own `Process` and spawned it unlocked, reintroducing exactly what
  `Core/ZipProcessSerialization.swift` was written to stop. They now share
  `writeZipFixture`, which holds `withZipProcessLock` across construction and
  spawn.

### Fixed

- **The browser runner boots the assignment's declared substrate, not Python's.**
  `RoutingExecutor.ensureReady` treated `PRIMARY_KIND = 'python'` as the runtime
  the grade depended on, swallowing every other substrate's boot failure
  whenever Python was present. On an R assignment carrying one stray `.py`, that
  made R's boot the swallowed one — so every R test posted a real zero while the
  incidental file got the protection. It now boots the language the assignment
  declares, and only that one; a script of another kind still runs (its worker
  boots on first use) and reports its own error. Where no language reaches the
  browser, every present substrate is required rather than assuming Python.

### Changed

- **A language is declared, never inferred.** `AssignmentLanguage.resolve` now
  returns what the manifest declares and nothing else. The graded-script
  extension sniff and the notebook-kernel sniff moved into
  `derivedDeclaration`, which runs at the three boundaries where content arrives
  without an author answer — the REST zip upload (which did not declare before,
  and now does), course-bundle import, and the one-time backfill — and each
  records the result immediately. Derivation happens once, at the edge, and
  becomes a declaration.

### Removed

- **`AssignmentLanguage.rederive` and `manifestWithRederivedLanguage`.**
  Replacing a starter notebook re-derived the assignment's language, on the
  reasoning that a recorded language was "a memo of what was last resolved". A
  declaration does not go stale when content changes: an author converting a
  Python assignment to R changes the language in the dropdown that exists for
  that purpose, and a notebook upload no longer overrules them silently.


## [0.5.58] - 2026-08-11

### Fixed

- **A `family:<id>` dependency broke the save on every language but Python.**
  `buildConfiguredSuiteEntries` computed the filenames a family dependency token
  expands to without passing the assignment's language, taking the `.python`
  default, while the suite entries beside them were rendered with it. On an R,
  Lua, Octave, C++ or Racket assignment the expansion named `.py` files that do
  not exist, and the manifest's own dependency validation rejected the save with
  a 422. The filenames are now read off the rendered scripts, so there is no
  second computation left to disagree with the first.
- **The pattern-family filename-collision check was inert in five of six
  languages.** It compared a family's Python filenames against a suite of `.R` /
  `.lua` / `.m` / `.sh` / `.rkt` scripts, so it could never collide. It now asks
  across every language, matching the notebook-check collision test beside it.

### Changed

- **Language resolution is up to 426× faster.** Resolving a 40-entry plain `.sh`
  suite — the system's original mode, and a supported one — cost 1.27 ms on the
  worker claim path and every instructor page render, because the walk called
  `URL(fileURLWithPath:).pathExtension` (4.5 µs per call, measured) once per
  suite entry per language and rebuilt a `LanguageDescriptor` literal on every
  fact it read. Descriptors are stored, extensions resolve through a map derived
  from `allCases`, and the suite is walked once. Same answers, including the
  `allCases`-order tie-break, now pinned by a test.
- **No function defaults its `language:` parameter any more.** Seventeen did —
  the shape that compiles at every call site and silently renders Python for an
  R, Lua, Octave, C++ or Racket assignment, and the cause of both defects above.
  The compiler named 101 call sites; each states the language it means.
  `scripts/no-language-defaults.sh` (wired into `format-lint`) keeps them out.
- **The runner's test-runtime helpers are compiled from
  `Tools/runner-support/*` instead of retyped.** `TestRuntimeSources.swift` was
  2,223 lines of Swift string literals mirroring those files by hand, kept
  honest by a drift test. A build-tool plugin (`Plugins/EmbedRunnerSupport`)
  embeds the canonical files, so the helper a student's test loads is the file a
  maintainer edits. Codegen rather than SwiftPM resources, so the runner binary
  stays self-contained and no deployment path changes.
- **One table drives the browser's grading substrates.** `RoutingExecutor` had
  four near-identical lazy factories, four slots, a four-arm router and a
  four-name dispose list. The grading-worker path now lives on
  `EditorSupport.notebookKernel`, and both consumers derive from it — the
  browser's generated `GRADING_WORKER_SCRIPTS` table and
  `NotebookAssetIsolationMiddleware.isolatedWorkerScripts`, which were
  previously two hand-written lists with nothing connecting them.
- **Pattern renderers are sliced by kind rather than by language.** Forty
  renderers moved out of five per-language files into the nine per-kind files,
  so a kind's six renderings are adjacent. Generated bytes are unchanged —
  proven by hashing all 54 kind × language renderings before and after.
- **Octave's line-comment marker is `%` everywhere.** It was the one fact with
  two answers in the tree — `LanguageDescriptor.lineCommentPrefix` said `#` and
  `AssignmentLanguage.lineCommentLeader` said `%`. Both parse in Octave, which
  is why they disagreed for four releases without failing. The inlined-inputs
  banner and the starter-notebook scaffold move to `%`; an existing `#` banner
  is still recognised and stripped.

### Removed

- **`AssignmentLanguage.lineCommentLeader`**, the second copy of the above.
- **`AssignmentLanguage.isRNotebookMetadata` / `isRNotebook`**, dead since the
  callers their doc comment named moved to the general `fromNotebookMetadata`.
  A `Bool` return is the `isRNotebook(nb) ? .r : .python` shape that type-checks
  forever and routes every other language to Python.
- **`scanNotebookForFunctions(_:)`**, a public Python-only notebook scan with no
  way to be told a language and no production caller left. Its coverage moved to
  the language-aware scan that actually runs.
- **`TestScriptVariablePrepender.emitBlock(_:)`**, which emitted Python
  declarations for every language and was called only from two test assertions.
- **The hand-written `pythonKernelNames` copy in `NotebookContentHelpers`**, now
  read off the descriptor like every other language's aliases.

### Added

- **`notebookSectionNames(_:)`**, replacing a call that read
  `parsing: language ?? .python` on an R notebook. Section names are `## `
  markdown headers and have no language, so asking for them no longer requires
  naming one.


## [0.5.57] - 2026-08-10

### Added

- **The freeze tracer can seed a large reopened-lab notebook (`FREEZE_BIG_NOTEBOOK=1`).** Forty-five cells with chunky saved outputs (streams, HTML tables, a base64 figure, ~1.5 MB total), so document-size-scaled work costs what it costs in production without executing anything. Used to clear the page's own JavaScript of the 58 s-anchored `page_unresponsive` stalls that persisted on the fixed build — `docs/browser-freeze-investigation.md` records the follow-up: that stall is a second, distinct, client-environmental mechanism (same ±1 s anchor across pre- and post-fix builds; quiet main thread at the 58 s mark in four instrumented environments), self-recovering and affecting no submission.


## [0.5.56] - 2026-08-10

### Fixed

- **A browser-graded submission can no longer be lost because a badge failed.**
  This is the `grading-probe` intermittent, closed after three sightings.

  The window was exact: the breadcrumb trail reached `suite_done` — graded,
  passed — then the POST 500'd, and the page went on polling
  `GET /api/v1/submissions/:id` and getting 200 for its full budget. That is the
  tell. The submission row existed and the result did not, so something between
  the two threw, and in the probe's configuration exactly one thing there could:
  `awardFirstToSubmitRecords`, an unguarded read-then-write that ran *before*
  the result was saved.

  Why it threw at all is the part that made this hard to place. sqlite-nio
  installs a busy handler that retries forever, so ordinary lock contention
  never surfaces — which is why "set a `busy_timeout`" is the wrong fix and why
  reading the configuration for a missing one finds nothing. What a busy handler
  cannot cover is `SQLITE_BUSY_SNAPSHOT`: a WAL read snapshot made stale by
  another connection's commit, which SQLite returns immediately because waiting
  cannot help. Every badge helper is read-then-write, the shape that hits it,
  and the page's own polling supplies the concurrent commits.

  The Pathfinder award now runs after the result is stored, alongside the class
  records, in an extracted `awardBrowserResultBadges`. Both go through a
  best-effort wrapper: `withTransientDatabaseLockRetry` first, then log and
  continue. A class badge is worth an ordinary amount; a student's grade is not
  worth losing for one.

  `BrowserResultSideEffectOrderTests` pins the ordering and the wrapper, and
  reproduces the original failure when the order is reinstated.

### Added

- **The two `LanguageDescriptor` fields that state facts about a real
  interpreter are now measured against one.** Most of the descriptor is
  normative — it decides something and the code obeys — but
  `interpreterProbe` and `workingDirectoryIsOnDefaultSearchPath` are claims
  about the outside world, true or false independently of what the descriptor
  says, and nothing checked them. Both have already been wrong in ways that
  produced no error: `--version` on lua exits 1, so no runner ever advertised
  Lua and an assignment requiring it queued forever; and the Octave search-path
  answer was, in the field's own words, "an armchair answer".

  The probe test reproduces the Lua failure exactly when the arguments are
  reverted. The search-path test measures the observable consequence rather than
  parsing a path listing: a module in one directory, the script that loads it by
  name in another, run with the working directory set to the module's and the
  search-path variable removed.

  That two-directory separation is the whole measurement. Collapsing it
  disagreed with a *correct* descriptor twice while the test was being written —
  put the module beside the script and every language looks alike, because a
  language that puts the script's directory on its path finds it too, which is a
  different fact. Python is the case that distinguishes them. Neither descriptor
  value was changed; both disagreements were the test's fault, which is worth
  recording because the tempting move on a red measurement is to trust the
  measurement.

### Changed

- **"Write a custom script" now names what it is competing with.** Eight of the
  nine Python script templates were retired because they duplicated a
  pattern-family kind in a worse form, and the ninth is now a kind too — which
  left the custom-script option looking like the ordinary way to write a test.
  Selecting it lists the first-class types available on this assignment,
  derived from the catalog's own family entries rather than from a second list,
  so a tenth kind appears there the day it is added.

  This closes the last open item in `docs/authoring-parity.md`: every retired
  template now has a named equivalent, `differential` included.

### Documentation

- **`docs/adding-a-xeus-kernel.md` covers the parity half.** The runbook took a
  language as far as *working* and stopped; a language can pass every item in
  its done test and still be one an instructor quietly avoids. It now carries a
  parity checklist that separates what a seventh language gets **free** from
  `allCases` — all nine pattern kinds, both Add Test renderings, the authoring
  UI, the whole MCP surface, the browser inputs filename, the vendoring guard —
  from the four things that remain genuinely per-language, each with a decision
  to record rather than a box to tick.

  Also added, all learned the expensive way this cycle: the in-page auto-compute
  half a kernel language owes the editor, with the descriptor entry deliberately
  **last** because one naming a worker that does not exist makes the editor spawn
  a 404 and auto-compute stop silently; a per-kernel eval-quirk table, because
  each of the three kernels needed a different shape rule and none inherited its
  neighbour's; and the per-language literal traps, where three of four are the
  same shape — a null-ish value silently changing a container's length — and all
  three needed different rules.

### Added

- **A ninth pattern-family kind: `differential`.** It grades a submission
  against an instructor-written reference implementation instead of a tabulated
  expected value — each case supplies only inputs, and the expected value is
  whatever the reference returns at grade time. It renders and executes in all
  six languages.

  This was the one thing the retired custom-script templates could do that no
  kind could. It earns its place where enumerating expected values is the hard
  part: a function over a large or awkward input space, or one whose right
  answer is easier to *write* than to *tabulate*. Per-student `$name` argument
  refs work, so the reference computes each student's expected value rather than
  the author tabulating one per student.

  Two things to know before reaching for it, both stated in the kind's own
  documentation and in the MCP tool description:

  The reference is rendered into the generated test, so on a **browser-graded**
  assignment it reaches the student's browser along with every other test script
  — browser grading runs the suite locally, so it must. Chickadee does not
  refuse or warn: whether a reference implementation is a secret is the
  instructor's judgement, and for many assignments it plainly is not. Worker
  grading is the answer when it is.

  And it grades *agreement*, not correctness. A wrong reference makes a wrong
  test that passes for whoever reproduces the same mistake.

  A reference that raises is reported as `errored`, not `failed` — a student
  cannot make it raise except through inputs the instructor chose, so blaming
  their submission would send them to debug the wrong code. In C++ the reference
  is compiled with the test, so one that does not compile is a build failure
  instead, which lands on the instructor at validation.

### Fixed

- **The MCP surface no longer holds a hand-typed list of pattern kinds.** Three
  places did — the `initialize` instructions, the `create_pattern_family`
  description, and that tool's JSON `enum` — and adding a kind made all three
  wrong at once, telling an agent the kind does not exist while
  `get_server_info`, which derives its list from `allCases`, reported that it
  does. `MCPPatternKindProse` now renders all three from `PatternKind.allCases`
  behind an exhaustive switch, so a tenth kind does not compile until it says
  what it is and then needs no copy edits at all. The sibling of
  `MCPLanguageProse`, for the same reason and after the same finding.

- **A family's fields no longer depend on being remembered.** Two paths rebuilt
  a `PatternFamily` field by field — the suite-edit path when the editor sends a
  row-level dependency, and `update_pattern_family` — and both dropped anything
  not listed. That already happened once, to `variables`: an `argVarRefs`
  reference failed validation on the next save of a family the author had not
  touched. There is now one `replacingDependsOn` copy beside the property list,
  pinned by a `Mirror`-based test that fails when any stored property does not
  survive.

- **The family editor's kind `<select>` is covered by the catalog guard**, which
  previously reached only the two lists in `test-editor-modal.js`. A kind
  missing from the template can be created from the Add Test menu but never
  switched to on an existing family — a gap that reads as "not supported yet"
  rather than as a bug.


## [0.5.55] - 2026-08-10

### Fixed

- **The post-boot editor freeze (`page_unresponsive`, Aug 2026) is root-caused and mitigated.** Production freeze-watchdog beacons — Chromium tabs blocking ≥8s about a minute into a lab, new with the 0.5/xeus era — were reproduced under CPU throttle and profiled to two upstream listeners that each force a synchronous reflow once per IOPub output message: `CodeCell.updatePromptOverlayIcon` reads `clientHeight`, and the Notebook 7 `:scroll-output` plugin reads `outputArea.node.scrollHeight` per cell to auto-collapse long outputs. A data-lab run-all therefore paid N outputs × full-document reflow, with the rendered tables making each reflow expensive. The mitigation touches no immutable vendored bytes: the new `Public/jl-cell-perf-patch.js` (injected into the notebooks editor beside the diagnostics collector, cache-busted, asserted by `verify-jupyterlite.sh`) coalesces the overlay-icon method to once per animation frame per cell at the prototype level, and re-applies the auto-collapse rule with upstream's exact semantics in that same per-frame callback — while `@jupyter-notebook/notebook-extension:scroll-output` is disabled via `jupyter-lite.json`'s supported `disabledExtensions`, since its per-message handler would both re-pay the reflow and fight the class toggle. Fail-safe: an unfamiliar upstream shape leaves the editor exactly as unpatched. The reusable tracer that found both ships as `Tools/editor-smoke-test/freeze-trace-check.mjs`; the full writeup is `docs/browser-freeze-investigation.md`.

- **The benign JupyterLab `insertWidget` boot rejection is no longer reported as a `kernel_error`.** The boot-time layout race (`this.layout.insertWidget` on a still-null layout) rejected on essentially every editor load in every engine and never affected the boot — a full month of production telemetry shows ~1 such rejection per successful `editor_ready`, making it 96% of all `kernel_error` rows and burying real failures (`kernel_unknown`, `boot_stalled`). The in-iframe collector now drops it at the source, matched on the property name so both the Chromium and WebKit phrasings are covered.

### Changed

- **Safari is no longer version-warned by the supported-browser matrix.** The D2L-seeded floor (Safari 26 — Apple's year-numbering jumped 18 → 26 in 2025) flagged a large working population: Safari tracks the OS, so 16–18 remain common, and production telemetry on the xeus editor shows Safari 17.3–18.6 booting and grading fine on the deliberate WebKit service-worker path while generating every `below_matrix` beacon. Safari/WebKit (desktop and iOS) is now floorless in `SupportedBrowserMatrix`; a WebKit that genuinely cannot run the editor is still caught by the runtime capability probe, the slow-boot notice, and the server-side grading failover. Chrome/Edge/Firefox floors are unchanged, and the banner copy no longer names a Safari version.


## [0.5.54] - 2026-08-10

### Fixed

- **The per-student inputs filename is generated for the browser, not
  hand-written.** `Public/browser-runner.js` chose between four literal
  filenames in an if/else chain whose final branch wrote Python's. That chain
  had already shipped the bug it invites: a browser-graded Lua assignment took
  the Python branch and wrote `_ck_inputs.py` while the Lua runtime read
  `_ck_inputs.lua`, so every per-student value went missing — silently, with no
  error and wrong marks. `scripts/generate-js-constants.sh` now emits
  `INPUTS_FILE_NAMES` from `LanguageDescriptor.inputsFileName`, so the filename
  is machine-written and CI fails when it goes stale.

  The renderer table stays hand-written — the four writers live in the browser's
  own `*-grading-shared.js` modules and have no Swift counterpart to derive from
  — and `BrowserInputsWriterCoverageTests` pins it to exactly the languages with
  an editor kernel. A fifth kernel language missing from it is what would make
  the Python fallback reachable again.

### Added

- **A coverage guard on the "+ Add Test" catalog**
  (`TestEditorCatalogCoverageTests`). The menu in `Public/test-editor-modal.js`
  is a hand-written list, one entry per `PatternKind` and per
  `NotebookCheckKind`, and nothing made it cover them. A ninth pattern kind
  would land with a renderer in six languages, a validator, an MCP schema and
  execution tests — every one of which fails loudly if missing — and then simply
  not appear in the menu: the server accepts it, an agent can author it, and the
  instructor in the editor cannot reach it.

  `AuthoringLanguageFactsTests` already pinned that the menu's per-language
  availability agrees with the save-time validator; this pins the prior question
  that one assumes, that the kind is in the menu at all. It also fails on an
  entry the server would refuse, and on one with no description.

- **The "+ Add Test" dropdown now disables kinds the assignment's language
  cannot support**, as the modal's type select already did. The two are built
  from the same catalog and only one consulted the support predicate — and for a
  pattern family or notebook check the dropdown does not open the modal at all,
  it authors the row in place, so the select's disabled options were guarding a
  path instructors no longer take. A Lua author picking "DataFrame has the right
  shape" went straight to an inline row for a kind Lua refuses at save time.

- **A failing smoke probe now prints the server's error lines, not only the log
  tail.** The tail exists so a server-side 500 is visible in CI, and on the
  failure it most needs to explain it cannot be: after a submit 500s the page
  polls the submission for the probe's full 300-second budget, so the last 40
  lines are several hundred INFO polls and the 500 has scrolled away. Three
  sightings of the result-POST intermittent have been triaged from breadcrumbs
  alone for this reason.

- **The vendored-kernel guard derives its expected kernels from the language
  descriptors** instead of a literal map. `check-xeus-vendored.sh` carried
  `{"xpython": "python", "xr": "r", …}` under a comment that admitted the
  consequence in as many words: a kernel absent from the map shipped completely
  unguarded, so a partial or botched re-vendor of it passed CI silently. That is
  the "enumerated rather than discovered, fails open" shape
  `docs/adding-a-xeus-kernel.md` names, sitting in the script whose whole job is
  catching a bad vendor. It now reads
  `editorSupport.notebookKernel(kernelName:)`, so a seventh language with a
  kernel is checked the day its descriptor names one, an upload-only language
  contributes nothing, and a vendored kernel no language claims is an error
  rather than dead weight.


## [0.5.53] - 2026-08-10

### Added

- **Octave assignments compute expected values in the browser**, on the vendored
  xeus-octave kernel. That closes the set: every language with an editor kernel —
  Python, R, Lua, Octave — now computes in the page, and the two that route to
  the server are the two with no kernel to run. `OctaveAutoComputeRuntimeTests`
  pins that correspondence, so a future kernel language cannot quietly ship on
  the server driver.

  Octave costs neither of the other kernels' shape constraints — no
  inter-expression yield, no `return <cell>` mis-read, and its cells share one
  base workspace — so its snippets are plain statement lists. Its one shape
  requirement is the `1;` guard on the boot cell, without which the cell reads
  as a function file and the seeded runtime never registers.

- **`octaveLiteral` in `Public/octave-grading-shared.js`**, pinned to
  `JSONValue.octaveLiteral` by `Tests/Fixtures/octave-literal-contract.json`,
  which both implementations read. The trap it exists for: `[...]` in Octave
  concatenates rather than collecting, and a number beside a string is coerced
  to its character, so `[65, "bc"]` is the char array `"Abc"`. Brackets are used
  only for an all-numeric/boolean array; anything else is a cell.

- **The Octave snippets are executed under a real interpreter in CI**
  (`Tests/BrowserRunnerJSTests/octave-eval-execution.test.mjs`), against the
  runtime the server actually seeds. A browser-grading smoke row covers the
  kernel half.

### Fixed

- **A solution function sharing a builtin's name is now the one that gets
  called.** `exist("area")` reports the solution's command-line function while
  `str2func("area")` hands back Octave's *plotting* `area` — so a handle-based
  lookup would have graded against a completely different function, reporting
  "no graphics toolkits are available" as though the instructor's solution had
  raised it. Command-line functions are resolved by name. Found by executing the
  snippets rather than inspecting them.

- **`octaveStringLiteral` now escapes control characters**, matching
  `encodeOctaveString` in Swift. It passed them through, which was survivable
  while its callers were names Chickadee controls and is not once it renders
  instructor text. The escape is exactly-three-digit octal, not `\x`, because
  Octave's `\x` consumes every hex digit that follows — `"\x0abc"` would swallow
  four characters of payload.

- **The language-conformance guard no longer demands every interpreter of every
  apt-get in the workflow.** It matched any `--no-install-recommends` line,
  including a job that installs two interpreters on a plain runner for the
  eval-snippet execution suites; it now matches the probe-guarded fallback
  installs it was written for.


## [0.5.52] - 2026-08-10

### Added

- **Lua assignments compute expected values in the browser.** Auto-compute runs
  on the vendored xeus-lua kernel — the same one that grades a browser-graded
  Lua submission — instead of round-tripping to the server. Octave is now the
  last kernel language still on the server driver; C++ and Racket have no kernel
  to run and stay there by construction.

  Two Lua facts shape the implementation, and neither is R's:

  Every kernel cell is its own chunk, so the `local function` declarations in
  the seeded runtime do not survive it. The runtime now ends by re-binding its
  serializer and JSON encoder as globals, in the same chunk that declares them —
  the only place they are still in scope. Without it every snippet fails on a
  nil call, reported as a per-cell error rather than as the substrate failure it
  is.

  Each snippet is one *call* expression, matching the grading wrapper, because
  xeus-lua first tries to compile a cell as `return <cell>` and mis-reads a cell
  that opens with a `local` declaration. R's snippets are one expression for an
  unrelated reason (its ~180ms inter-expression yield), which Lua does not have.

- **Arguments are rendered one `local` per argument, never into a table.** A
  JSON null is `nil` at top level and the `chickadee.NULL` sentinel inside a
  table, because a table constructor does not store `nil` at all; building an
  argument table would silently drop the slot and call the solution with the
  wrong arity. The sentinel is seeded from the same Swift expression
  `test_runtime.lua` binds, since the eval worker loads no `test_runtime`.

- **The Lua snippets are executed under a real interpreter in CI**
  (`Tests/BrowserRunnerJSTests/lua-eval-execution.test.mjs`), with each snippet
  `load`ed as its own chunk so a helper that only works by sharing a file scope
  fails. It runs the runtime the server actually seeds, extracted from the Swift
  constants that define it. A browser-grading smoke row covers the kernel half.

### Changed

- **The browser-grading smoke's auto-compute probe is one parameterized page**
  rather than one per language, and the Swift-constant extraction it depends on
  moved to `Tools/browser-grading-smoke/auto-compute-runtime.mjs`, shared with
  the Node execution suite.

### Fixed

- **The browser-grading smoke's path filter named languages by hand and had
  already gone stale** — it listed r/python/lua grading and python/r eval while
  the matrix also ran octave grading, so an octave-only change skipped the job
  that tests it. It is now a pattern, which also fails in the safe direction: an
  unrecognised language matches and runs the smoke rather than skipping it.


## [0.5.51] - 2026-08-10

### Added

- **The in-page auto-compute worker can now be given its language's own value
  serializer and JSON escaper.** `AssignmentLanguage.autoComputeRuntimeSource`
  seeds the source a worker must prepend before it can report a value — the
  SAME constants the server driver and grading runtime already use, so the two
  substrates cannot disagree about what a value looks like. Lua and Octave need
  a serializer and an escaper; R needs only an escaper (`deparse` is a builtin);
  Python needs neither.

  The eval protocol is unchanged — the one `python-eval-worker.js` already
  speaks, with the payload printed as JSON behind a per-run nonce. An earlier
  draft of this work proposed a second, nonce-framed encoding to avoid pushing
  escapers into three languages; the escapers turned out to already exist as
  Core constants, so framing would have bought nothing and cost a second payload
  encoding and a second parser.

### Changed

- **R's char-by-char JSON string encoder moved from `PersonalizationEvaluator`
  into `RPersonalizationRuntime`**, where a second consumer can share it rather
  than copy it. Worth knowing when reaching for one: there are two R encoders in
  the tree, and this is the robust one — the `gsub`-based encoder in the grading
  runtime trips over replacement-string backslash rules, which is why this one
  was written.

### Added

- **R assignments compute expected values in the browser.** Auto-compute used to
  send every non-Python language to the server, which was the right fix for a
  wrong answer and the wrong rule for an editor whose job is in-browser
  authoring: an instructor changing a case should see what their solution
  returns without a round-trip. R now runs on the vendored xeus-r kernel, the
  same one that grades a browser-graded R submission.

  Lua and Octave still route to the server. Their kernels exist and the worker
  shape is now proven; each needs its own snippet module and a smoke row.

- **`rLiteral` in `Public/r-grading-shared.js`** — a browser twin of
  `JSONValue.rLiteral`, needed because in-page auto-compute calls an R solution
  with arguments the instructor has typed but not saved, so there is no server
  round-trip in which the server could render them. Neither implementation owns
  the expectations: both read `Tests/Fixtures/r-literal-contract.json`, so a
  change to either that is not mirrored fails on both sides — the arrangement
  `output-contract.json` already uses to pin RunnerCore's native and wasm builds
  together.

- **A browser-grading smoke row for R auto-compute.** It exercises the kernel
  for real, because every way these snippets can be wrong is silent: they must
  be one top-level expression each (a xeus-lite performance constraint), they
  report behind a nonce, and the seeded escaper has to be defined before any of
  them runs. The probe reads that escaper out of the Swift constant that defines
  it rather than copying it — a copy would have been the fourth R JSON encoder
  in this repo.

### Added

- **A browser `luaLiteral`**, pinned to `JSONValue.luaLiteral` by
  `Tests/Fixtures/lua-literal-contract.json` — the same arrangement the R
  renderer uses, where neither implementation owns the expectations and both
  read the fixture. Groundwork for in-page auto-compute on Lua.

  The contract exists mainly to pin one trap: Lua spells null `nil`, and a `nil`
  inside a table constructor **is not stored** — `{60, nil, 20}` loses its middle
  slot, `ipairs` stops at the hole, and `#t` is unspecified. So null renders
  `nil` only at top level and the `chickadee.NULL` sentinel inside any table. A
  renderer that misses that produces a table of the wrong length and grades
  against it.

### Fixed

- **`luaStringLiteral` now escapes control characters**, matching
  `encodeLuaString` in Swift. It passed them through, and a literal newline
  inside a quoted Lua string is a syntax error rather than a formatting quirk.
  The escape is decimal (`\ddd`) because `\xNN` is Lua 5.2+.


## [0.5.50] - 2026-08-10

### Changed

- **`LanguageDescriptor` now carries two capabilities as implementations rather
  than claims.** `functionScan` holds the definition patterns a language's
  solution notebook is read with, and `autoCompute` names the in-page worker
  that computes a case's expected value (or says the server evaluates instead).
  Both were previously a boolean somewhere else with the implementation
  elsewhere again — the shape that had already drifted once, where a capability
  can be claimed and not supplied and an instructor finds out by being told
  their solution is empty. A seventh language now either supplies the patterns
  or declares `noSolutionNotebook`, and either names a worker or takes the
  server driver; there is no answer that compiles and does nothing.
  `notebookFunctionScanSupport` and `AuthoringLanguageFacts` derive from these
  rather than restating them.

- **Auto-compute routes on the descriptor, not a language name.** The editor
  read `name !== 'python'` and sent everything else to the server, which was
  the wrong rule for a surface whose job is in-browser authoring: an author
  changing a case should see what their solution returns without a round-trip.
  It now spawns whatever worker the language declares, and only falls back to
  the server for a language that declares none. R, Lua and Octave still declare
  the server driver — their kernels exist but their eval workers are not written
  yet, and declaring a worker before writing it would have the editor spawn a
  404 and auto-compute stop silently. Flipping each is one line, one worker, and
  one smoke-matrix row.

### Removed

- **Eight of the nine Python script templates.** Each duplicated a
  pattern-family kind that already renders in all six languages, in a strictly
  better form — a family is server-rendered, spec-hashed, re-renders when a case
  changes, and is pinned by execution tests, where a template is a one-shot text
  dump the instructor then owns forever. Offering both taught authors to reach
  for the fallback. `exists` → the automatic existence guard; `correctness` and
  `corner_cases` → `boundaryEquality`; `exception` → `exceptionExpected`;
  `type_check` → `returnTypeCheck`; `performance` → `performanceThreshold`;
  `variable_equality` → `variableEquality`; `structural_check` → the
  `astStructure` notebook check.

  `differential` stays: nothing supersedes it yet, since no pattern kind
  compares a submission against a reference implementation.

- **Per-function scaffold scripts on the create page.** The auto-scaffold wrote
  one `publictest_exists_<fn>.py` per detected function, from the template that
  is now gone — seeding a Python script to do a job every pattern family does
  automatically and in every language. Section scaffolding, which was always
  language-neutral and always useful, is unaffected.


## [0.5.49] - 2026-08-10

### Fixed

- **A scaffolded notebook now carries the assignment's own kernel.** "Create
  assignment notebook" wrote a Python kernelspec whatever the language, from
  four call sites that had no language to pass — so selecting R and clicking the
  button produced a Python notebook. The assignment still resolved R (a recorded
  manifest language outranks the kernelspec), leaving generated `.R` tests beside
  an editor booting `xpython`; on a draft with no recorded language the
  kernelspec is the only signal there is, so the wrong answer was also a sticky
  one. The kernel now comes from `EditorSupport.notebookKernel`, the starter
  cell's comment from `lineCommentPrefix`, and an upload-only language is
  refused rather than scaffolded.

- **Suite sections are scaffolded in every language.** The auto-scaffold bailed
  whenever no functions were found, and the scanner returns nothing for a
  language it cannot read — so five languages got no section scaffolding as
  collateral from a limitation that applies only to function extraction. A `## `
  header is markdown, not code: `unsupportedReason` now scopes to `functions`,
  and the scan reports `sectionNames` either way.

- **The three shell test templates no longer name Python.** They are offered on
  every language and their bodies said `FILE="solution.py"` and
  `python3 -c "import solution; …"` — so a non-Python author got three
  templates, all wrong, which is worse than none. The filename now comes from
  `sourceFileExtension` and the invocation from `interpreterProbe`, with a
  compile-then-run form for a language whose grading builds before it runs
  (chosen by `capabilityRequiresExecutableOutput`, not by naming C++).

### Added

- **Solution scanning for R, Lua and Octave.** The scanner read Python `def`
  statements and nothing else, so an author in another language was offered a
  "Scan Solution for Functions" button that could only ever report an empty
  solution. Each language now has its own definition parser — `f <- function(x)`
  and the `=` spelling for R; `function f`, `local function f` and
  `f = function` for Lua; and Octave's `function [y, z] = f(x)`, whose name is
  not the first identifier on the line — selected behind the existing exhaustive
  `notebookFunctionScanSupport`. The traversal (cells, `## ` headers, dedup,
  shadowing) stays one implementation.

  Partial fidelity by design: none of the three has parameter annotations, so no
  types are claimed. That is the same state an un-annotated Python function
  already produces, and the editor already handles it. C++ and Racket stay
  unsupported for a structural reason — upload-only, so there is no solution
  notebook to scan.


## [0.5.48] - 2026-08-10

### Fixed

- **The create page no longer reports adding starter tests it did not write.**
  "Generate Starter Tests" filtered its work list to empty on any non-Python
  assignment and then reported `N test file(s) added to suite.` from the count
  of files nobody wrote. It now says the templates are Python-only and names the
  assignment's language. Its solution scan also passes the declared language to
  `/instructor/scan-notebook`, as the family editor's scan already did — without
  it, a declared-R assignment whose solution still carried a Python kernelspec
  scanned as Python and listed functions no generated test could be written for.
  The whole panel moved out of `assignment-new.leaf` into
  `Public/generated-starter-tests.js`, where it is linted and testable; both
  defects were invisible from the template.

- **Copy that named C++ as the only upload-only language now names every
  upload-only language.** Racket has been the second since it shipped, and the
  enforcement predicate (`requiresUploadOnlySubmission`) picked it up
  immediately because it asks `editorSupport` — so the rule covered Racket while
  the explanation did not, in both authoring pages and four MCP tool
  descriptions. All six sites now interpolate `LanguageProse`, which derives
  predicate-defined language lists the way `MCPLanguageProse` derives the full
  one. `MCPLanguageCoverageTests` gained the matching guard: any served sentence
  about upload-only that names one upload-only language must name all of them.
  Its existing guard could not see this class, because it ignores
  single-language mentions on purpose.

- **The pattern-family variables table no longer calls every value a Python
  literal.** The `Value (JSON / Python literal)` column header was shown to R,
  Lua, Octave, C++ and Racket authors — the same defect as the adjacent "Python
  default" placeholder fixed earlier, missed because this instance lived in Leaf
  rather than in the editor's JavaScript. It now names the assignment's own
  language. The required-Languages placeholder on the create page and the
  student-facing "the Python kernel" prose on the editor-reset and notebook
  pages were stale the same way; the placeholder is now derived from
  `AssignmentLanguage.allCases`, and the kernel prose no longer names a language.

- **The custom-script editor no longer offers Python to every language.** "Write
  a custom script" is advertised in the Add Test catalog as "your assignment's
  language, or .sh" and then offered nine Python templates, a
  `test_correctness.py` placeholder, and a `test_new.py` default on all six
  languages. The Python group is now shown only on Python assignments; Shell is
  shown everywhere because `.sh` is the universal test contract; and a new
  file's extension comes from the assignment's own language — `sh` for C++,
  whose test cases are shell wrappers. Template sets for R, Lua, Octave, C++ and
  Racket do not exist yet, so those assignments get Shell and Blank; writing
  them is content work, not a structural gap.

- **The two authoring facts nothing read are now read.** `functionScanning` and
  `expressionEvaluation` were computed server-side, parsed in the browser, and
  consumed by no one — the create page invited a solution scan on every language
  and reported "No functions found." where the honest answer was "this language
  cannot be scanned", and auto-compute routed on a hand-written
  `name !== 'python'` beside an unread capability flag. The scan panel now
  refuses up front and names the language, and auto-compute reads the flag, so a
  seventh language without an expression driver disables the control instead of
  filling Expected cells from a server that refuses. `authoring-language.js`
  gained the accessors and its first test file.

### Fixed

- **A hand-written test in Lua or Racket no longer gets a banner its interpreter
  cannot read.** The comment written above inlined global/section inputs was a
  hardcoded `#` line in every language — a comment in Python, R, Octave and
  shell, and a syntax error in the other three, where `#` is Lua's length
  operator, a Racket reader prefix and a C++ preprocessor directive. Because the
  banner is also the sentinel used to strip the previous block, re-saving
  compounded the damage instead of repairing it. `LanguageDescriptor` gained
  `lineCommentPrefix`, and a script already carrying the broken banner is
  repaired on its next save. Python, R and Octave output is byte-identical.

- **The main web authoring path no longer skips four languages when inlining
  inputs.** `PUT /suite` picked a raw script's language with a hand-written
  switch on `py`/`r` and `default: nil`, so a hand-written Lua, Octave, Racket or
  C++ test received no global or section variables — while MCP `author_script`
  and the single-script save, which resolve through
  `AssignmentLanguage(scriptExtension:)`, delivered them. All three paths now
  resolve the same way, behind one `supportsRawScriptInlining` predicate that
  declines C++ (whose graded scripts are `.sh` wrappers, so an inlined
  declaration would never be read).

- **Racket inputs land inside the module.** A `#lang` line now keeps line 1 the
  way a shebang does. This is stronger than the shebang rule it reuses: a
  `(define …)` written above `#lang` is a read error, not a formatting problem.

### Added

- **`docs/authoring-parity.md`** — what an instructor authoring in each of the
  six languages can and cannot do, which differences are defects and which are
  correct refusals (with the substrate reason for each, so they stop being
  re-litigated), and the remaining work in order.


## [0.5.47] - 2026-08-09

### Changed

- **`docs/leaf-decomposition-review.md` gained a section scoring #1253's four
  landings against its own finding.** Each of the four was filed as a tidiness
  task; three of the four stated rationales pointed somewhere other than the
  defect, and in every case what a diff actually showed was two copies of one
  thing that had drifted. The section records the corrected premises, the
  rules worth carrying forward, and why the review's earlier "not planned"
  call on `assignments.leaf` changed.


## [0.5.46] - 2026-08-09

### Changed

- **The runner claim walk moved out of the HTTP routes file.** `ClaimedJob`,
  `BlockedCandidate`, `ClaimEvaluator`, the candidate query and the
  evaluate-and-claim walk now live in
  `Sources/APIServer/Services/WorkerClaimEvaluation.swift`. None of them is
  about HTTP; they were file-private in `WorkerJobRoutes.swift`, so nothing
  else could see or test them.

### Added

- **Coverage for the claim walk's lost-race path.** The atomic claim step is
  now injected into the walk rather than being a method on the route
  collection, which makes reachable the branch `atomicallyClaimSubmission`'s
  own documentation described as impossible to trigger deterministically
  through the HTTP endpoint: another runner claiming a candidate between our
  scan and our claim. Three tests pin it, including that a claimed job carries
  its own test setup rather than the first candidate scanned.


## [0.5.45] - 2026-08-09

### Changed

- **`applyPatternFamilies` carries no lint exemptions at all.** Its remaining
  four phases — resolving caller arguments against the stored manifest,
  rebuilding the authored ordering, resolving the assignment language, and
  rewriting the manifest — moved into
  `PatternFamilyApplication+Inputs.swift` and `+Manifest.swift`. The function
  is now a 90-line orchestrator over six named phases, down from 575 lines
  when the work started, and the `function_body_length` exemption is gone.
  No behavioural change: the manifests and file lists produced for a fixture
  covering families, existence guards, notebook checks with sidecars,
  sections, global variables, `family:` dependency expansion, disabled cases,
  the deletion diff and the carry-forward path are unchanged.


## [0.5.44] - 2026-08-09

### Changed

- **`applyPatternFamilies` no longer suppresses a cyclomatic-complexity
  warning.** Its render-and-write phase and its suite-entry-building phase
  moved into `PatternFamilyApplication+ZipMutation.swift` and
  `+SuiteEntries.swift`, taking the function from a 575-line body to 306 and
  dropping its complexity below the threshold on its own — so the repo's only
  double lint exemption is now a single one. No behavioural change: the
  manifests and zip file lists produced for a fixture covering families,
  existence guards, notebook checks with sidecars, sections, global variables,
  `family:` dependency expansion, disabled cases and the deletion diff are
  unchanged.


## [0.5.43] - 2026-08-09

### Fixed

- **The runner no longer cancels one prepare-phase artifact download because
  the other failed.** Cancelling an in-flight `URLSession.download` on Linux
  can deadlock — `swift_task_cancel` takes the task's status-record lock and
  then blocks on the session's Dispatch work queue, while that queue is
  completing the same task's transfer and resuming its continuation, which
  wants that lock — and the job setup's `async let` performed exactly that
  cancel whenever the test-setup fetch failed first. The submission download
  and the test-setup acquire now both report a `Result` and are both always
  awaited, so neither leg's failure can cancel the other. Deliberate
  cancellation is unchanged: cancelling the daemon still stops both transfers.
  This was Family 4 in `docs/ci-flakiness.md` — `worker-tests` SIGABRTing at
  the wedge watchdog roughly one CI run in fifteen.


## [0.5.42] - 2026-08-09

### Changed

- **The new-assignment page's bounce-back redirect has one builder instead of
  two.** The five form fields that survive a redirect to `/instructor/new`
  (title, due date, start date, section, draft id) are now a
  `NewAssignmentFormContext`, and the two functions that each assembled the
  same query string from them — in a different field order — collapsed into one
  method on it. Two `function_parameter_count` lint exemptions went with them.
  No behavioural change: a correct consumer reads query parameters by name, and
  the emitted fields and values are unchanged.


## [0.5.41] - 2026-08-09

### Changed

- **`WedgeWatchdog` is shared test support, and `APITests` now arms it.** The
  watchdog — a monitor on a dedicated OS thread that dumps `/proc/self/task`
  (state + `wchan` per thread) and aborts after 300 s of total test silence —
  was `WorkerTests`-local, so an `api-tests` stall still burned a silent
  20-minute `cancelled` job and yielded nothing to diagnose from. It moves to a
  new `ChickadeeTestSupport` target that both test targets depend on (one copy,
  no drift), and `APITests` arms it at `withApp`, the scope 172 of its 315
  files funnel through. It measures silence, not slowness: entering or leaving
  any test body resets the clock, so a lane merely running at 10× cost — the
  2026-08-09 shape — still passes, while a wedge fails in ~6 minutes carrying
  the thread table that names the pinned syscalls. Verified both ways: a full
  `APITests` run passes with the limit forced down to 30 s (individual tests
  reporting up to 131 s of wall clock), and an induced pool wedge aborts with a
  dump showing four cooperative-pool threads parked in `anon_pipe_read`.

- **`FD_CLOEXEC` on the last three unguarded subprocess pipes**
  (`Core/ZipArchiver`, `TestSetupZipHelpers`, `NotebookContentHelpers`), via
  the worker's `setCloseOnExec` hoisted to `Core` so there is still exactly one
  implementation. Filed as the mechanism that makes a transient overload
  permanent; measured, it is not currently reachable that way. On Swift 6.3 /
  glibc 2.39 both spawners this codebase uses already prevent it — a pipe of
  ours does not survive into a child spawned through Foundation's `Process`,
  and swift-subprocess `close_range`s everything above stderr — so only a bare
  `posix_spawn` still inherits. Kept as defence in depth and as the invariant
  every other pipe here already states; `PipeCloseOnExecTests` pins the
  measurement, and its control fails if the leak ever stops being
  demonstrable.

- **`docs/ci-flakiness.md` gains Family 5: `api-tests` starved past its
  20-minute ceiling.** A `cancelled` `api-tests` job looks identical to the
  #1233 wedge but can be plain starvation — the tell is whether tests were
  still *completing* at the tail of the log, and whether `api-tests-postgres`
  (same target, same commit) passed. Recorded with the measurement that
  separates the two: the same commit's `Run APITests` step took 1107 s
  (killed at the ceiling) and 216 s on rerun, against a `main` baseline of
  204/236/441 s min/median/max over 18 runs. Also records that reproducing
  `APITests` locally needs CI's
  `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=4`, since unbounded
  parallelism SIGSEGVs the target in a way that reads as a regression.

- **`api-tests` gets the same 25-minute CI ceiling as `api-tests-postgres`.**
  The two run the same target; the sqlite lane had the tighter cap despite
  the wider run-to-run spread. This buys headroom for the ordinary tail, not
  for a starvation event — the job that prompted it was killed still running
  at 1107 s, and nothing establishes it would have finished inside the larger
  budget either.


## [0.5.40] - 2026-08-09

### Fixed

- **Assignments outside a section were missing the retest and copy-link
  actions.** The instructor dashboard's sections table and its ungrouped table
  rendered the same row markup from two copies, and the copies had drifted: the
  ungrouped one had lost the "Retest all submissions" form from every status and
  the "Copy student link" button from staff-only-preview assignments. The
  ungrouped table is also the flat-table mode a course falls back to when it has
  no sections at all, so on such a course those actions were absent for every
  assignment. Both tables now render one shared partial.
- **The publish form's title and due-date inputs carried two `class`
  attributes**, so the `editor-input` styling on the second was discarded by the
  parser. Merged into one attribute.

### Changed

- **`assignments.leaf` halved, 1,140 → 545 lines.** The item row moved to
  `_course-item-row.leaf`, and the action-cell branch on assignment status —
  three arms whose markup was byte-identical — collapsed to one.


## [0.5.39] - 2026-08-09

### Added

- **`get_server_info` reports every assignment language and what it supports (#1290).** The MCP
  surface had no way to discover which languages exist: an agent learned that six notebook-check
  kinds are refused on Lua, and all ten on C++ and Racket, by having a save rejected. The tool now
  returns a `languages` array — per language, its wire token and display name, its
  script/generated/source extensions, whether it has an in-browser editor kernel or is upload-only,
  whether per-student expressions can be evaluated and by which interpreter, and exactly which
  pattern-family and notebook-check kinds it renders with the reason for every exclusion. Every
  field is derived from whatever already owns the answer — the check-kind exclusions come from the
  same predicate the save-time refusal calls, so what an agent is told and what it is allowed to
  write cannot disagree, and a seventh language appears in the payload without an edit.

### Fixed

- **The agent-facing MCP copy no longer describes a five-language world (#1290).** Five hand-typed
  language lists still stopped at `cpp` after Racket shipped — including `set_assignment_language`'s
  own description, which told agents Racket was not a legal value while its (derived) JSON schema
  accepted it. Four more tool descriptions still called personalization expressions "Python source",
  the exact defect #1288 fixed in the `initialize` instructions one language earlier and did not
  fix in the tool catalog. All of it is now interpolated from `AssignmentLanguage.allCases` via
  `MCPLanguageProse`, and `MCPLanguageCoverageTests` fails on any list in the served catalog that
  stops short of every language — scoped to the whole catalog rather than to the string someone
  happened to be looking at, which is why the first fix did not hold.


## [0.5.38] - 2026-08-09

### Fixed

- **Racket assignments are gradable.** Two runner defects closed together, both
  from the multi-language audit:
  - A generated `.rkt` test had no `ScriptInterpreter` case and no extension arm,
    so it classified as unknown, fell through to `/bin/sh`, and exited 2 on its
    own leading `;` — every generated Racket test reporting `error`, in the only
    grading path an upload-only language has.
  - `RunnerProfileDetector.firstNumericVersion` could not read
    `Welcome to Racket v8.10 [cs].` because the version token is letter-led, so
    no runner ever advertised `racket` and `RunnerLanguageGate` refused every
    runner — jobs queued forever with no error, no failed test and no log line,
    instructor validation included.

### Changed

- **Three guards, each the one that would have caught its defect.**
  `GeneratedScriptDispatchTests` asserts from `allCases` that every language's
  generated extension reaches its own interpreter (C++'s `.sh` wrapper is the
  stated exception). `RunnerProfileDetectorTests` — the detector's first test of
  any kind — pins all six real banners and, under CI, asserts each probe's live
  output *parses* rather than merely exiting 0. `RacketNativeGradingTests`
  executes generated `.rkt` through a real interpreter, so Racket meets the
  runbook's done test rather than being declared finished.

**Operational note:** dispatch and the runtime helper both live in the runner
binary, so a Racket assignment needs a runner at this version or newer. Refresh
the fleet before opening one.


## [0.5.37] - 2026-08-09

### Changed

- **The add-a-language runbook covers the authoring UI, and says a seventh
  language needs no JavaScript at all.** That section exists to stop work: the
  editors clearly behave per-language, so the failure mode is going looking for
  the arm to add and re-introducing the per-language table that v0.5.36 removed
  twice. It records the derivation table, the greppable invariant, and the rule
  for adding a genuinely new fact.
- **The compiler-invisible list is nine, not eight.** Capability matching gains
  the probe's *output format* (Racket's letter-led `v8.10` defeats the version
  parser even though the probe exits 0), and generated-script dispatch is added
  as item 9 — which the `RunnerCore`/`Core` dependency direction means the
  compiler probably never will see. The runtime helper left the list: it is
  installed from `allCases` now, so omitting it is a compile error.
- The descriptor field list, the compiler-named site count (27 arms across 17
  files), and `CLAUDE.md`'s language list are current — Racket is in both, and
  `CLAUDE.md` records the authoring-language seam and the server-side
  compute-expected route.


## [0.5.36] - 2026-08-09

### Fixed

- **The pattern-family editor knows which language it is editing.**
  `Public/pattern-family-editor.js` contained the string "language" zero times:
  it validated Python identifiers, accepted `True`/`False`/`None`, rewrote
  pasted values by Python's rules, and named Python in its optional-argument
  placeholder — on R, Lua, Octave, C++ and Racket assignments alike, while the
  server rendered the same family correctly in those languages. An R author who
  typed the boolean true got the *string* instead, silently, in a value that
  decides marks. Both authoring pages now seed `#assignment-language-seed` from
  the new `AuthoringLanguageFacts`, whose scalar spellings are computed by
  `JSONValue.literal(_:)` — the same call that renders the real generated test,
  so the editor cannot drift from what will actually be produced. Python's facts
  reproduce the previous hardcoded constants exactly, so Python assignments are
  unchanged.
- **C++ is offered no null token.** Its `literal(.null)` is the poison
  identifier the renderer emits so a leak becomes a compile error; the editor no
  longer offers that as something to type, matching the save-time refusal.

### Fixed

- **The Global and Section Inputs editors read the assignment's language.**
  `inputs-editor-core.js` parsed values by Python's rules — `True`, `False`,
  `None`, and a Python-repr rewrite — on all six languages, so an R instructor
  typing the boolean true stored the *string*. These panels are where per-student
  `=` expressions are authored, and an expression is evaluated in the
  assignment's language, not Python. The scalar spellings now come from the same
  shared reader the pattern-family editor uses.
- **The "Add Test" menu no longer offers notebook-check kinds the language
  cannot save.** It listed all ten on every assignment — six a Lua author could
  not save, and every one of them on C++ or Racket, where there is no notebook to
  check at all. Unsupported kinds are disabled with their reason, derived from
  the same predicate the save-time refusal uses (issue #1290).
- **The dashboard stops offering an editor link for a language that has none.**
  The row reported the stored submission mode while gating Edit and Open-editor
  on it; it now reports `effectiveSubmissionMode`, matching `effectiveGradingMode`
  beside it. Manifest-writing sites keep the stored value.

### Changed

- **`Public/authoring-language.js`** is the one place the browser reads the
  assignment's language facts, shared by the pattern-family editor, the inputs
  editors and the test-editor modal, so "how does this language spell true" has a
  single answer.
- Student- and instructor-facing wording that named Python on every assignment:
  the in-browser kernel messages, the raw-script blurb's extension list, and the
  required-languages placeholder.

### Fixed

- **Auto-computing a case's expected value now runs the assignment's own
  language.** The editor's evaluator is a Python kernel in a Web Worker, so on
  an R, Lua, Octave, C++ or Racket assignment it did not fail — it computed a
  *Python* answer for a value that would be compared against that language's
  result. Non-Python assignments now call
  `POST /instructor/:assignmentID/compute-expected`, which evaluates through
  `PersonalizationEvaluator` (the same per-language driver that resolves every
  per-student `=` expression). Python keeps its in-page kernel unchanged.
- **A non-Python reference solution is extracted at all.** The server wrote only
  `solution.py`, so an R, Lua, Octave, C++ or Racket personalization expression
  could never call the reference solution — the evaluator looked for a helper
  with that language's extension and the solution was never among them.
  `SolutionNotebookExtractor` now writes `solution.<ext>` in the assignment's
  language, reusing the RunnerCore extractors the worker already uses.

### Changed

- **`LanguageDescriptor.sourceFileExtension`** replaces two identical
  hand-written switches (the worker's submission staging and its notebook
  extractor) that a third was about to join. Distinct from
  `generatedScriptExtension`, which for C++ is the `.sh` wrapper.
- Automatic stdout capture is offered where a language expresses it in one
  expression (R, Octave) and reported unavailable where it does not, instead of
  being auto-filled with what Python printed.

### Added

- **Architecture audit of multi-language support (`docs/multi-language-audit.md`).**
  Covers the arc from Lua's completion through Racket. Finds Racket ungradable on
  the native worker via three stacking defects — generated `.rkt` tests classify
  as unknown and run under `/bin/sh`, no Racket runtime helper is written into
  the grading workspace, and `racket --version`'s letter-led version token
  (`v8.10`) defeats the runner's version parser so no runner ever advertises the
  language — plus the upload-only coherence rule still naming C++ at three of its
  five enforcement sites. No behaviour changes; the audit is documentation only.

### Fixed

- **The solution-notebook scan says which language it cannot read.** It matches
  Python `def` statements and nothing else, so an R, Lua, Octave or Racket
  solution produced no functions and the instructor was told "No functions
  found." — the same message an empty solution gets. `notebookFunctionScanSupport`
  is now an exhaustive switch a seventh language must answer, the scan endpoint
  returns the reason alongside the functions, and both authoring pages show it.
  The scaffold asks the same question instead of no-opping by accident.

### Fixed

- **An upload-only language can no longer be authored into notebook mode.** The
  rule "a language with no editor kernel must be `submissionMode: uploadOnly`"
  was enforced at five places and spelled `== .cpp` at three of them, so a Racket
  assignment could be flipped back to the notebook workflow from the MCP tool,
  the web editor, or a zip-borne manifest. All five now ask
  `EditorSupport`, and the refusal message names the language it refused instead
  of always saying "C++".
- **`TestProperties.effectiveSubmissionMode`** pins a kernel-less language to
  upload mode at every consumption site, the way `effectiveGradingMode` already
  did for `upload + browser`. A stored incoherent pair — from a hand-crafted zip,
  an imported course bundle, or a row written before the language existed — is
  now inert rather than a promise of an editor that cannot load.
- **Every language's runtime helper is installed, discovered from
  `allCases`.** The runner installed them through five hand-written calls under a
  comment reading "one per language", which stopped being true at the sixth:
  `test_runtime.rkt` had no embed and no write call, so a generated Racket test's
  `(require "test_runtime.rkt")` found nothing. Adding a language now fails to
  compile until it answers `runtimeHelperFiles(for:)`.

### Changed

- **Three drift guards walk `allCases` instead of naming languages.**
  `RuntimeSourceDriftTests` was five hand-written cases and now checks every
  language both ways — embed matches canonical, and no canonical helper goes
  uninstalled. The script-dispatch fixture gained Lua, Octave and C++ rows (it
  had covered neither Lua nor Octave since they shipped) plus an `allCases`
  assertion that every language's generated extension has one, with Racket
  carried as a named exemption until its dispatch lands.
  `AssignmentLanguage.lineCommentLeader` is hoisted out of `renderInputsFile` so
  the drift guard reads the same per-language fact rather than keeping a second
  copy.


## [0.5.35] - 2026-08-08

### Added

- **Racket is the sixth assignment language.** `AssignmentLanguage.racket`
  covers the courses Waterloo's first-year CS stream actually runs — CS 135 and
  CS 115 (`#lang htdp/bsl`) and CS 136 (`#lang racket`) — with all eight pattern
  kinds rendering and executing. It is upload-only like C++, because no
  Scheme-family kernel exists on `emscripten-forge-4x` to vendor; unlike C++
  that answer is contingent rather than principled, so a kernel appearing is a
  reason to revisit it. Notebook checks are refused categorically for the same
  structural reason as C++ (no submitted notebook exists). `racket` is on the
  server, runner and CI images; the Debian package carries the HtDP
  teaching-language collections, which is a requirement and not a bonus.

  Four things were measured before any Swift was written, each because the
  obvious spelling fails silently:

  - A teaching-language module **exports nothing**, so a generated test cannot
    `require` the submission. Tests load it with `dynamic-require` +
    `module->namespace`.
  - Definedness must ask `namespace-mapped-symbols`;
    `namespace-variable-value` reports a perfectly good BSL binding as missing.
  - Calls must evaluate an **application form**, never a bare identifier — BSL
    rejects a function reference outside operator position.
  - Arguments must be **bound into the namespace and passed by name**. Quoting
    is the natural spelling and BSL refuses it (`(quote (1 2 3))` is an error),
    which would have broken exactly the list-valued arguments a CS 135
    assignment is made of.

  The payoff is that one rendered test grades both dialects unchanged, which
  `PatternFamilyRendererRacketTests` pins by running every kind against each.
  Numeric comparison uses `=` rather than `equal?` because BSL reads `18.5` as
  the exact rational `37/2`, and `equal?` would mark a correct student wrong.

### Changed

- **`existenceGuard` builds its `GeneratedScript` once.** Every per-language arm
  constructed an identical value around a different source string; the shared
  construction is hoisted and Python's bytes moved to a helper unchanged (the
  goldens verify). A seventh language is now one line there rather than
  thirteen.


## [0.5.34] - 2026-08-08

### Changed

- **Corrected the C++ `noexec` postmortem in `docs/cpp-support.md`.** It said
  no C++ assignment could be graded in production. That was true of the moment
  it was measured — the one runner hardened with a `noexec` `/tmp` was also the
  only one new enough to advertise `cpp` — but not of the system: a second
  runner has a writable, exec-capable work root and grades C++ correctly. The
  bug was claim-order-dependent grading across a non-uniform fleet, which is
  what `RunnerLanguageGate` exists to eliminate, and is why the fix belongs in
  capability discovery rather than an operator runbook. The original conclusion
  came from a probe that filtered the mount table to `/` and `/tmp`; the full
  table is now recorded, along with the v0.5.33 production confirmation that
  the hardened runner drops `cpp` from its profile while keeping every other
  language.


## [0.5.33] - 2026-08-08

### Fixed

- **C++ assignments could not be graded at all in production.** The generated
  C++ wrapper compiles a binary into the job working directory and then
  `exec`s it, and the runner container mounts `/tmp` — where job workspaces
  were rooted — as `tmpfs ... noexec`. Every C++ test died with
  `exec: ./.ck_bin_...: Permission denied` despite a `-rwxr-xr-x` binary and a
  clean compile; the mount flag, not the file mode, was the cause. Job
  workspaces and scratch copies now share the runner's existing cache directory
  (`--test-setup-cache-dir` / `RUNNER_TEST_SETUP_CACHE_DIR`) as one work root,
  so pointing that at a writable, exec-capable path fixes it. No new setting,
  and the default is unchanged.
- **A runner advertised C++ it could not run.** Capability discovery probed
  only `g++ --version`, which succeeds on a `noexec` host — so the runner
  claimed `cpp`, the language gate routed every C++ job to it, and each failed
  with a message that reads as a broken test script. Discovery now compiles and
  runs a trivial program in the runner's actual work directory for any language
  whose grading path executes its own build output, and a runner that cannot do
  both stops advertising the language. C++ is the only such language today.
- **A newly created C++ assignment stored an incoherent grading mode.**
  Declaring `cpp` set `submissionMode` to `uploadOnly` but left `gradingMode` at
  the new-assignment default of `browser` — the pair every other authoring
  surface explicitly refuses. Grading was never wrong (upload-only assignments
  are coerced to native grading at consumption), but the stored value was
  reported back verbatim, so a fresh C++ assignment looked browser-graded.
  Declaration now sets both.

### Added

- **`get_assignment` reports `submissionMode` and `language`.**
  `set_submission_mode` told callers to read the current mode from
  `get_assignment`, which never returned it, leaving an authoring agent no way
  to check the mode it had just been told to verify. `gradingMode` is now the
  effective mode, so an upload-only assignment no longer reports a grading path
  that cannot run.

### Changed

- **Octave's notebook-check count corrected in the renderer's own header.**
  `NotebookCheckRendererOctave.swift` opened by claiming "seven of ten" and then
  enumerated five, three lines above the `switch` that returns true for exactly
  those five. #1302 fixed the same stale count in `CLAUDE.md` and cited this
  file as the authority without correcting the claim inside it.


## [0.5.32] - 2026-08-08

### Fixed

- **The test suite no longer leaks the ~1 GB per run that remained after
  #1299 (#1298).** Both residual causes are closed. `withApp` — the teardown
  route nearly every suite uses — now performs the full `tearDownTestApp`
  instead of a bare shutdown, so per-app temp directory trees are removed
  (~45 MB / ~1,400 entries per run). And teardown now discovers, via
  `PRAGMA database_list`, the real temp file sqlite-kit secretly backs every
  "in-memory" test database with — upstream never deletes it — and removes it
  (~973 MB / ~1,566 entries per run). Regression tests pin both outcomes,
  including a loud failure if sqlite-kit's temp-file scheme ever changes out
  from under the discovery.


## [0.5.31] - 2026-08-08

### Fixed

- **The runner now refuses a job that carries per-student inputs but names no
  assignment language, instead of rendering them as Python.** The values arrive
  already rendered as source literals in the assignment's language (`repr` /
  `deparse`), so writing them into `_ck_inputs.py` for an R assignment raised no
  error at the boundary — it produced a file whose *contents* were wrong, and
  every personalized test then failed somewhere inside the student's own code,
  with a traceback that read as their mistake and persisted as their grade. The
  old default was justified by "nil means an older server", a premise the
  declare-at-creation work falsified: personalization is resolved per-language
  on the server, so an assignment with inputs has a language by construction,
  and a plain `.sh` suite has neither. The refusal reports `buildStatus: failed`
  with a message naming the cause and the fix, and classifies as terminal so it
  is not retried.


## [0.5.30] - 2026-08-08

### Changed

- **Language resolution is Optional, and Python resolves positively.**
  `AssignmentLanguage.resolve` answered `.python` when nothing named a
  language, so "this is Python" and "nothing here says anything" were the same
  value — Python was defined by absence at both ends to make that work
  (`gradedScriptLanguage` skipped it, so a `.py` script never matched; its
  `notebookKernelNames` was empty, so a `python3` kernelspec never matched
  either). That conflation is upstream of the silent-misroute defects in this
  area, Lua shipping green while resolving to Python among them. `resolve` and
  `rederive` now return `AssignmentLanguage?`, nil meaning "no signal names a
  language" — a legal state, since a suite of plain `.sh` scripts is the
  system's original mode. `AssignmentLanguage.default` is gone; every site that
  used it was really asking "is this Python?" and now says so, with identical
  behaviour. Sites that must produce a language regardless (notebook
  extraction, literal rendering, expression evaluation, pattern-family
  authoring) state that locally instead of inheriting it. The browser's
  generated copy of the kernel-alias sets gains `PYTHON_KERNEL_NAMES` to match,
  so `browser-runner.js` identifies a Python notebook positively and its
  unrecognised-kernel fallback is a visible branch rather than the shape of the
  tail.

### Added

- **A runner only claims a job it can actually grade (`RunnerLanguageGate`).**
  Runners upgrade independently of the auto-deployed server, so several builds
  poll at once and claim order decided which one graded a job: an assignment in
  a newer language validated green on a capable runner, then failed for the
  next student whose job an older one claimed — with a symptom (exit 127,
  "interpreter not found") that reads as a broken test script. The claim seam
  now resolves the assignment's language and refuses a runner whose advertised
  profile lacks it, so the job waits for one that can grade it. No authoring
  step is involved, and it catches strictly more than a `minimumRunnerVersion`
  gate: a current runner whose *host* lacks the interpreter never advertises it
  either. Fails open for an assignment with no language and for a runner
  advertising no profile at all (capability discovery switched off).
  `minimumRunnerVersion` remains for runner behaviour that is not observable as
  an interpreter.

- **A Language dropdown on the assignment edit page.** Sits above Submission
  Method and declares the language explicitly, for the cases derivation cannot
  reach: a suite made only of pattern families has no script on disk to sniff,
  and C++ has neither a notebook kernel nor a language-bearing generated
  extension. It writes through the same shared helpers the MCP
  `set_assignment_language` tool uses, so both surfaces share one policy and its
  three refusals. Options are built from `AssignmentLanguage.allCases`, and the
  list leads with "detect from the notebook or test scripts" — a recorded
  language outranks every content signal, so without a way back the first
  choice would be permanent.


## [0.5.29] - 2026-08-08

### Fixed

- **The test harness no longer leaks its scratch directories.** `makeTestApp`
  built its per-app temp path with a trailing slash inside
  `appendingPathComponent`, and `URL.path` strips that — so the five directories
  it then created by string concatenation were *siblings* of the intended
  parent rather than children (`…/<uuid>content-files/`). Nothing created the
  parent, so `tearDownTestApp`'s `removeItem` deleted a path that never existed,
  and its `try?` swallowed the error: cleanup reported success while removing
  nothing. A full suite run leaked ~1.4 GB across ~6,900 `/tmp` entries, enough
  to fill a 252 GB disk over a working session. Measured after the fix, the same
  run leaves 45 MB. Two regression tests assert the outcome — that the
  configured directories are inside the recorded root, and that nothing matching
  the app's prefix survives teardown — rather than asserting that cleanup ran,
  which is what was true the whole time it was broken. (#1298)


## [0.5.28] - 2026-08-07

### Added

- **MCP can now author a C++ assignment.** Two new content tools close the gap
  the C++ language arc left behind: `set_submission_mode` (`notebook` /
  `uploadOnly`, the MCP twin of the edit page's control) and
  `set_assignment_language` (declare `python` / `r` / `lua` / `octave` / `cpp`).
  C++ was previously unreachable through MCP entirely — its language is the one
  that cannot be derived, since it has no editor kernel for a notebook
  kernelspec to name and its generated tests are deliberately extension-free
  `.sh` wrappers — so a C++ assignment could only be created by uploading a
  hand-written `test.properties.json`. The catalog is now 54 tools.

  Both halves of the `cpp ⟺ uploadOnly` invariant are enforced, each from its
  own side: declaring C++ on a notebook-mode assignment is refused, and a C++
  assignment cannot be flipped back to the notebook workflow it has no kernel
  for. A language change is refused once generated tests exist, since every
  generated filename carries the current language's extension — declare the
  language before authoring families, which is the natural order anyway.

- **`update_solution` accepts a source-file answer key.** A language with no
  notebook workflow has no `.ipynb` to extract a solution from, so C++
  assignments had no way to receive a reference solution — and therefore no way
  to pass validation — even once their suite could be authored. The tool now
  takes either `notebook` (unchanged) or `solutionFile` ({filename, content}),
  and picks which shape is legal from the assignment's language rather than the
  caller's preference: passing a notebook for C++ is refused, since it would be
  stored and then grade as an empty submission at validation time.


## [0.5.27] - 2026-08-07

### Added

- **C++ is a full assignment language — the first with no editor kernel.**
  `AssignmentLanguage` is now `.python | .r | .lua | .octave | .cpp`. C++
  assignments are upload-only (`submissionMode: "uploadOnly"`, enforced on
  every authoring surface) and grade exclusively on the native worker with
  the course's real g++ toolchain — no xeus kernel is vendored, deliberately:
  a browser kernel would grade a different compiler than the course teaches
  (docs/cpp-support.md records the two-C++s decision). A generated case is a
  POSIX shell wrapper that compiles one translation unit (the injected
  template runtime `test_runtime.hpp`, optionally `_ck_inputs.hpp`, then the
  student's file with `main` renamed so program-style submissions still
  expose their functions) and runs the binary under the original
  shell-script contract — no per-language build strategy enters Swift, and
  per-test compile is ~0.65 s at -O0, measured. All eight pattern-family
  kinds render and execute, including `performanceThreshold` (supportable
  precisely because C++ is native-only; its wrapper compiles -O2) and
  `returnTypeCheck` (static-type matching via decltype, no RTTI). Notebook
  checks are refused categorically — there is no notebook workflow to check.
  Literals never guess a type: single-kind containers render explicitly
  typed, and JSON null, mixed arrays, and nested containers are refused at
  save time with named reasons. Personalization `=` expressions are C++,
  evaluated by a compile-and-run driver (~0.3 s) sharing the same Horner
  seed fold as every other language, delivered as typed
  `inline const auto` definitions in `_ck_inputs.hpp`. g++ rides both
  images, runners advertise it via the capability probe, and the upload
  form's accept hint now includes `.cpp`/`.h`/`.hpp` from the language
  table.


## [0.5.26] - 2026-08-07

### Changed

- **`LanguageDescriptor` can now express a language with no editor kernel.**
  The four descriptor facts that presupposed a vendored JupyterLite kernel
  (the environment file, kernel name, display label, and missing-dependency
  wording) are folded behind one `editorSupport` judgement:
  `.notebookKernel(...)` for every current language, `.uploadOnly` for a
  compiled language graded through the shell-script + makefile path whose
  submissions arrive as file uploads. Purely internal — every language keeps
  its kernel and every behaviour is unchanged — but a kernel-less language is
  now expressible at all, which the compiled-C++ arc requires, and a test pins
  that admitting one is a deliberate, stated decision rather than an
  unfinished descriptor.


## [0.5.25] - 2026-08-07

### Added

- **Assignments can be upload-only (`submissionMode: "uploadOnly"`).** A new
  manifest field beside `gradingMode` declares how students hand work in:
  `notebook` (the JupyterLite workflow, the default and the behaviour of
  every existing assignment — which keeps the upload form available on
  worker-graded assignments, so it already covers notebooks edited offline)
  or `uploadOnly`, which removes the editor surface
  entirely — the dashboard drops the Edit action, the notebook URL (including
  the assignment's vanity link) sends students to the upload form, and
  grading always runs on the native worker. This makes the shell-script +
  makefile path a first-class product surface for work the notebook workflow
  cannot carry: makefile-graded compiled languages such as C++, and
  multi-file projects submitted as a zip. The upload form now lists the
  assignment's `requiredFiles` and derives its file-picker hint from the
  language table plus those files (the hand-listed hint had gone stale twice
  — it never learned `.lua` or `.m`). The incoherent `upload` + `browser`
  combination is refused on every authoring surface (edit page, MCP
  `set_grading_mode`, the test-setup upload API), section moves skip adopting
  a browser default for upload assignments, and `effectiveGradingMode` pins
  imported bundles that carry the pair to worker grading anyway. Suite
  rebuilds now also preserve `requiredFiles`, which a rebuild previously
  reset to empty.


## [0.5.24] - 2026-08-07

### Added

- **Octave is a full assignment language.** `AssignmentLanguage` is now
  `.python | .r | .lua | .octave`: `.m` test scripts grade on the native
  worker (`octave-cli`, now on the runner and CI images together with the
  gnuplot-nox + freefont pair that makes headless figures work) and in the
  browser via the vendored `xeus-octave` kernel (`chickadee-octave`, xeus
  6.0.5, ~12 s cold boot, no per-statement cost). All eight pattern-family
  kinds render and execute; notebook checks cover seven of ten — more than
  Lua, because both of Lua's opposite answers were re-measured for Octave:
  `figureCount` is supported (plotting is core Octave, verified in both
  runners) and `cellContains` keeps `regex: true` (Octave's regexp is PCRE).
  The four data-frame kinds and `astStructure` are refused at save time with
  a message naming what is supported. Personalization evaluates `=`
  expressions through an `octave-cli` driver sharing the same Horner seed
  fold as R and Lua, so a student's seed is one number in every language.
  Generated literals render mixed-type arrays as cell arrays — never `[...]`,
  whose silent char coercion (`[65, "bc"]` is `"Abc"`) is Octave's most
  dangerous default — and equality is `isequaln`-based, so authored nulls
  (`NA`) match missing values and 1 == 1.0 == true, matching what students
  can observe with Octave's own operators.


## [0.5.23] - 2026-08-07

### Added

- **Lua is a supported assignment language, not just a grading substrate.**
  `AssignmentLanguage` gains `case lua`, so a Lua assignment resolves to Lua
  instead of falling back to Python and inheriting Python's inputs file, pattern
  cases and notebook checks. All eight pattern-family kinds render as `.lua`
  test scripts, along with four notebook-check kinds — `variableExists`,
  `functionExists`, `numericArrayClose`, `cellContains`. The other six are
  refused at save time with a message naming what Lua does support, because the
  `chickadee-lua` environment is bare `xeus-lua`: the four data-frame kinds need
  a data frame and Lua has no such type, `figureCount` needs a plotting library,
  and `astStructure` is Python-only by design.

  Per-student personalization works end to end: a Lua expression driver on the
  server, `_ck_inputs.lua` written by both the worker and the browser, and one
  shared seed reduction (`LuaPersonalizationRuntime`) so the seed the driver
  binds equals the seed a graded script reads. Lua notebooks extract through the
  same marker-emitting RunnerCore extractor R uses.

### Changed

- **One shared failure-message vocabulary for generated test scripts.**
  `"  expected: "` and `"  got:      "` were each hand-typed in fourteen files
  across both renderer families and every language; 188 call sites now read
  `GeneratedMessage`. It computes each message's column from the longest label
  in that message, so a new field, kind, or language gets alignment for free and
  cannot mis-pad it. Generated bytes are unchanged — the 72 existing goldens
  pass without regeneration, so every assignment's `spec_hash` and
  `TestSetupCache` key is stable.

### Fixed

- **The conformance matrix's interpreter probe reported Lua absent.** It
  hardcoded `--version`, which python3 and Rscript accept and `lua` does not, so
  every executed assertion for Lua skipped silently — the suite reported green
  having never parsed a line of generated Lua. The probe arguments are now
  per-language, in the same compiler-forced switch as the eval flag.
- **Nothing parse-checked a pattern family's existence guard**, in any language.
  It is produced by `existenceGuard(for:)` rather than `renderPatternFamily`, so
  iterating the latter covered every generated script except the one that every
  other case in the family depends on.
- **`scripts/generate-js-constants.sh` hardcoded `rKernelNames`**, so adding a
  language generated nothing for it and the browser kept routing that language's
  notebooks to Python. It now discovers every `<lang>KernelNames` declaration
  and fails when a language has no fenced block to write into.
- **The worker's notebook extractor asked "is this R?"** and sent everything
  else to the Python path, which a Lua notebook is not. It now resolves the
  language positively via `fromNotebookMetadata`.

### Fixed

- **Runner capability matching could not see Lua, in both directions.**
  `RunnerProfileDetector` hand-listed `python3` / `R` / `swift`, so no runner
  ever advertised Lua however it was provisioned — which made requiring it
  *worse* than not: an assignment with `lua` in its required languages matched
  no runner and queued forever. And `detectRequirementSuggestions` mapped only
  `.py`/`.r`, so a Lua assignment suggested no language requirement at all and
  its jobs went to any runner, including one whose image has no interpreter.
  Both now resolve through `AssignmentLanguage` — the probe from `allCases`,
  the extension through the one extension table — so a new language is
  advertised and suggested the day its case exists.
- **A `.lua` test suite file could not be uploaded through the web form.** The
  allowlist was hand-listed (`sh/bash/zsh/py/r/rb/pl/js/php`) and a `.lua`
  upload was silently dropped from the suite rather than rejected with a
  message, while the MCP `author_script` path accepted it. Assignment-language
  extensions now come from `AssignmentLanguage`, and an extensionless script
  with a `lua` shebang is recognised.
- **A Lua notebook submission was normalized as a Python submission.** The
  worker's routing asked "is this R? else Python", and its Python arm was
  reached by falling through extension probes rather than by naming Python — so
  a Lua assignment's `.ipynb` was turned into a Python module the Lua suite
  could not grade. The routing now returns a `SubmissionNormalization` carrying
  the language, `manifestOwningLanguage` generalises the old
  `manifestTargetsRSubmission`, and the notebook sniff returns which language a
  submission declares instead of whether it is R. Python and R behaviour is
  unchanged, including the deliberate rule that a mixed Python+R suite keeps
  Python's normalizer.

### Added

- **A submission policy: what Chickadee guarantees a student about their
  upload, stated once for every language.** `SubmissionPolicy` names the
  guarantees — valid notebook JSON, at least one code cell, unsupported files
  warn rather than fail, no gradeable source is an error naming the language —
  and each language either provides one or exempts itself **with a reason**.
  Only one exemption exists: R and Lua skip the introspectable sidecar, because
  it exists for `astStructure` checks and those are Python-only by design.

  This closes a real asymmetry. The Python path had 445 lines of validation and
  student-facing errors; the generic path used `guard let … else { continue }`,
  so an R or Lua student whose notebook was corrupt or empty got no file, no
  message, and then "No R submission file was found to grade" — blamed for a
  platform failure. Guarantees apply to the student's own notebook only, so an
  instructor's markdown-only helper still skips leniently, now with a warning.
- **The import guard rejected `import solution` on Python assignments.**
  `studentModulePrefixes` was hand-written per language and Python's omitted
  `solution` and `submission`, while `test_runtime.py` itself special-cases
  `solution.py` — so an instructor's hand-authored reference to their own
  reference solution was reported unsatisfiable in a browser-graded test. The
  prefixes are now derived from one shared list, which can only widen what the
  guard accepts.


## [0.5.22] - 2026-08-06

### Fixed

- **The Lua interpreter is now on the runner image.** `.lua` scripts classify to
  an `env lua` subprocess, but the image installed only `python3` and `r-base`,
  so native grading failed with command-not-found — and because instructor
  validation is enqueued as a `kind == .validation` submission graded by the
  *native* worker, even a purely browser-graded Lua assignment could not be
  validated. The browser→worker failover was a dead end for Lua for the same
  reason.

### Added

- **`JSONValue.luaLiteral` and `extractLua`**, the two pieces of Lua's
  authoring support that can be written and proven in isolation. The literal
  renderer's interesting case is `null`: a bare `nil` inside a Lua table
  constructor is not stored, so `{60, nil, 20}` makes `ipairs` visit one
  element instead of three and `table.concat` raise. A `chickadee.NULL`
  sentinel (now defined by `test_runtime.lua`, and compared by identity in
  `chickadee.equal`) occupies the slot instead — Lua's answer to the problem R
  solves with `NA`. Every expectation is checked against a real `lua 5.4`.
  `extractLua` shares R's implementation via `extractWithCellMarkers`, differing
  only in the comment marker.

### Changed

- **The notebook-language sniff is a table rather than an R special case.**
  `AssignmentLanguage.notebookKernelNames` plus `fromNotebookMetadata` replace
  the hand-inlined `rKernelNames` checks; `isRNotebookMetadata` is now a thin
  equality over the one implementation, and graded-script resolution asks for
  "any non-default language" rather than "is it R". Behaviour is unchanged —
  Python stays the fallback and is deliberately given no positive alias set.

- **`docs/adding-a-xeus-kernel.md` now carries the second half as a
  compiler-generated worklist and a done test.** Adding `case lua` to
  `AssignmentLanguage` and rebuilding enumerates the work in three passes — 10
  sites in Core, 3 in RunnerCore/Worker, 12 in APIServer — and the document
  records all 25, plus the four the compiler *cannot* see (the runner image,
  `shouldNormalizePythonSubmission`, the generated JS constants, the vendored
  browser wasm), each of which has shipped broken at least once. It also states
  the rule the Lua work surfaced: a vendored kernel is registered in the editor,
  so there is no such thing as a grading-only kernel — finish the second half or
  do not vendor it.

  It also records **what a half-supported language actually does**, measured
  rather than predicted, since Lua spent a release in exactly that state: the
  worker path fails with exit 127 (`env: 'lua': No such file or directory`),
  which RunnerCore maps to `error` rather than `fail`, and instructor
  validation — a native-worker job even for browser-graded assignments — hits it
  before any student can. The section also flags the trap that follows: putting
  the interpreter on the image removes that loud signal while leaving four
  silent ones (empty `_ck_inputs`, `.py` pattern cases in a Lua assignment,
  likewise notebook checks, and Lua notebooks extracted through the Python
  sanitizer), so the interpreter fix is only safe as part of finishing the
  second half.

- **A language conformance matrix** (`Tests/APITests/LanguageConformanceMatrixTests`)
  — what "supported" *means*, asserted for every `AssignmentLanguage` rather
  than for whichever ones someone remembered. Before it, the suite had exactly
  one test parameterised over language and it read
  `arguments: [AssignmentLanguage.python, .r]` — a hand-listed pair, not
  `allCases`, so a third case would have left it silently testing two languages
  and passing. That is the same fail-open shape as the `chickadee-*` glob and
  `expected_language`; this was the third instance and the worst-placed, since
  it is the thing meant to notice omissions.

  Everything in the matrix iterates `allCases`, and the per-language glue it
  needs itself lives in one exhaustive `adapter(for:)` switch, so a new case
  cannot compile without supplying it. It covers structural invariants
  (extensions and kernel aliases disjoint, inputs filename consistent with the
  language, kernel env file exists), **the interpreter being present on the
  runner image** (the exit-127 defect), every `PatternKind` and
  `NotebookCheckKind` rendering per language with unsupported kinds *named*
  rather than merely absent, every generated script **parsing in its own
  language**, and the inputs file the server writes being the one the language
  actually reads back. `PatternKind` gained `CaseIterable` to make the kind half
  possible — it had none, so the kinds could not be iterated at all.

- **Byte-for-byte goldens for every generated script** (72 snapshots covering
  every `PatternKind` and `NotebookCheckKind` in every language, plus each
  language's inputs file), and a **cross-language wording guard**. Together they
  make the planned renderer refactor provable rather than a judgement call:
  generated filenames embed a `spec_hash` and `TestSetupCache` keys on manifest
  content, so a change of one byte rewrites every existing assignment's manifest
  and busts every cache entry. Snapshot first, refactor, and the work is correct
  exactly when the goldens still pass.

  The wording guard covers the other axis. `"  expected: "` and `"  got:      "`
  are each hand-repeated in **fourteen** files across both languages and both
  renderer families, so a reworded Python failure could silently diverge from
  the R one and a student on an R lab would read different prose for the same
  mistake. The guard asserts that whichever message fields a kind uses, it uses
  in every language — currently true, now pinned.


## [0.5.21] - 2026-08-06

### Added

- **Browser grading for Lua, on a vendored xeus-lua kernel.** A `.lua` test
  script now grades in the browser the way a `.py` or `.R` one does:
  `RoutingExecutor` sends it to `/lua-grading-worker.js`, which boots the new
  `chickadee-lua` environment (~19 MB, against 74 MB for R and 85 MB for
  Python) and reports an exit code, stdout and stderr back to the same
  RunnerCore suite loop the other two use. `Tools/runner-support/test_runtime.lua`
  ships the `passed()` / `failed()` / `errored()` API, the per-student seed and
  inputs, and submission loading; the native worker injects it alongside the
  Python and R helpers, so one file serves `lua script.lua` and the kernel
  alike. Proven on a real kernel by
  `node Tools/browser-grading-smoke/smoke.mjs --language lua`, now a leg of the
  browser-grading smoke workflow.

  This is the architecture test `docs/adding-a-xeus-kernel.md` recommends
  rather than a language a course can be authored in — Lua has no literal
  renderer, no pattern families, no notebook checks and no personalization
  driver, and `AssignmentLanguage` is still `.python | .r`. What it does have
  is a measured answer to the question the document asks: the browser substrate
  really is language-agnostic, and R's two hard-won lessons (the `evaluate`
  stderr trap and the one-top-level-expression rule) turned out to be xeus-r
  properties that do not generalise.


## [0.5.20] - 2026-08-06

### Changed

- **Language dispatch is compiler-enforced, so a third language can't silently
  inherit Python's or R's behaviour.** `AssignmentLanguage` is threaded through
  98 references across 32 files, and almost all of them are either generic or
  exhaustive `switch`es that fail to compile when a case is added — which is the
  point of the design. The exceptions were boolean tests (`if language ==
  .python`, `language == .r ? … : …`) that compile fine with a third case and
  route it down whichever branch it happens to fall into.

  Each remaining one was inverted so the *language* answers the question instead
  of the call site testing it, as a property on `AssignmentLanguage` with no
  `default:` arm: `kernelEnvironmentFileName`,
  `missingDependencyFailureDescription`, `runnerProvidedModules`,
  `studentModulePrefixes`, `supportFilesPathEnvironmentVariable`. Behaviour is
  unchanged — the same strings and sets, reached a different way.

  `AssignmentLanguage.default` is a genuine correction rather than a renaming.
  Resolution asked `manifestOnly == .python` when it meant "did resolution fall
  back?" — the same answer today, and the opposite answer with a third language,
  where it would stop consulting the notebook kernelspec for an assignment that
  had resolved positively.

  Not fixed, and now marked at the site: `shouldNormalizePythonSubmission` is a
  normalization strategy shaped as "R, or else Python", whose Python branch is
  reached by falling through content probes rather than by naming Python. It
  cannot be inverted the same way; giving each language a normalization strategy
  is an artifact rather than an edit. `docs/language-handling-review.md` §4
  records the closed census and this one exception.

### Changed

- **Browser-graded Python boots a bare kernel and installs packages when a
  script asks for one.** The Python environment is 61 MB across 48 packages, and
  **84% of it is the optional data-science half** — most of which a given
  assignment never touches. `python-grading-worker.js` now boots only the
  closure of `xeus-python` (the interpreter and the kernel), and when a script
  fails with `ModuleNotFoundError: No module named 'X'` it resolves X to its
  owning conda package, installs that package's closure into the **live**
  kernel, and re-runs that one script.

  Measured in Chromium, 3 runs, from local disk — so these are *install* costs
  (untar, FS write, `dlopen`), not download, which means the saving survives a
  fully warm cache and is larger over a real network:

  | boot | packages | payload | median |
  |---|---|---|---|
  | full env | 48/48 | 61 MB | 8604 ms |
  | bare kernel | 28/48 | 9.7 MB | 4822 ms |
  | + numpy | 29/48 | 13 MB | 4839 ms |
  | + matplotlib | 44/48 | 35 MB | 6092 ms |

  Adding to a running kernel costs 242 ms (numpy) or 696 ms (pandas). `scipy`
  alone drags in 16 MB of `openblas` — which `numpy` does not need — for an
  import that takes 0.09 s.

  Failure-driven rather than predicted, deliberately: under browser grading the
  test script imports the *student's* module, so the student's imports run too
  and the server cannot know them. Predicting the set means being wrong for the
  one student who imported something the tests did not; the kernel cannot be
  wrong about what is missing. The loop is bounded — each pass must install at
  least one new package — and a module the environment does not have leaves the
  original `ModuleNotFoundError` exactly as it was.

- **R does the same, and gains more than expected.** `r-grading-worker.js` boots
  `xeus-r` alone and installs on the same loop, shared in
  `xeus-kernel-shared.js`. R words the failure identically for `library()`,
  `require()` and `pkg::fn` — the latter two route through `loadNamespace()` —
  so one pattern covers every way a script can name a package.

  R's optional share is smaller than Python's (22.2 MB of 62.1, so 36%) because
  `r-base` alone is 25 MB. But **`r-stringi` (14 MB) is not part of the bare
  kernel** — it arrives with `stringr`/`tidyr` — so a dplyr-only assignment
  installs 2.4 MB rather than the whole 22.2 MB set, and a base-R lab installs
  none of it.

  Measured on the smoke fixture that attaches *and exercises* all seven
  tidyverse packages, same harness before and after: the script went from
  **62 006 ms** on a full-env boot to **5 621–6 815 ms** on a bare kernel with
  on-demand install, and boot from 5.1–10 s to 3.9–4.0 s. Reproducible across
  three runs. The mechanism for the ~10× is **not established** — the plausible
  one is that installing a subset lets `loadSharedLibs` resolve exactly the
  needed shared objects at install time, where the full-env boot left it to R's
  lazy path at first attach (26 s for `dplyr`) — and it is recorded as inference
  rather than asserted.

### Fixed

- **Kernel package requests no longer cost a database lookup each.** The
  `kernel_packages/` subtrees are now on `EditorAssetFastPathMiddleware`, so the
  ~50 package fetches a boot makes no longer ride the full middleware chain and
  pay a Fluent session lookup they never needed.

  Scoped to `kernel_packages/` rather than `/jupyterlite/xeus/` wholesale, which
  is the version that shipped and was reverted in v0.5.19: the wider prefix also
  captures `kernels.json` and each `<env>/<kernel>/kernel.json`, which the editor
  fetches during app **startup**, before any kernel exists.
  `kernelStartupJSONStaysOnTheNormalChain` asserts both directions so a
  well-meaning prefix widening fails in CI rather than in front of a student.

- **Installing into a live kernel had to happen from the environment prefix.**
  By the time a script triggers an on-demand install the kernel has `chdir`'d
  into the student workspace, and the vendored unpacker resolves paths relative
  to the working directory — installing from there fails inside the bundle with
  a bare `Error` carrying no message. `addPackages` chdirs to `/` and restores
  afterwards. Invisible to every unit test; only a real kernel shows it, and
  `Tools/browser-grading-smoke` is what caught it.

### Added

- **`importable-modules.json` records which package ships each module.**
  `moduleOwners` is a by-product of the scan `derive-kernel-modules.py` already
  performs — the tarball being read *is* the answer — so it cannot drift from the
  shipped bytes, and there is no distribution-name-to-import-name table to
  maintain and get wrong (`PIL` → `pillow`, `matplotlib` → `matplotlib-base`).

- **The browser grading smoke proves on-demand loading on a real kernel.** One
  test imports a package absent at boot and asserts it computes; another imports
  a module the environment does not have and asserts it still fails the ordinary
  way, which is what shows the retry terminates rather than spinning.

- [docs/kernel-boot-cost.md](../docs/kernel-boot-cost.md) — what a kernel boot
  costs, measured per package and per environment; why cross-user caching is not
  available; and why the editor is deliberately not in this slice.


## [0.5.19] - 2026-08-06

### Added

- **The R editor and grading environment now ships the tidyverse core.**
  `dplyr`, `tidyr`, `readr`, `stringr`, `tibble`, `purrr` and `forcats` are
  available in R notebooks and in browser-graded R tests. The environment was
  previously bare `xeus-r` — base R and nothing else — so any `library(dplyr)`
  failed, and failed at *grade* time, because instructor validation runs on the
  native worker's full R installation where it works fine.

- **Saving a browser-graded R test now fails if the kernel cannot satisfy its
  `library()` calls**, the R half of the Python import check added in v0.5.18.
  It reads `library(pkg)`, `require(pkg)` and `pkg::fn`, and is checked against
  what the vendored kernel actually contains. `pkg::fn` counts anywhere in the
  file while `library()` counts only at the top level: `::` is not a conditional
  construct and appears overwhelmingly inside functions, whereas an attach inside
  a function or an `if` is indented and therefore guarded.

- **A browser probe asserts every package the R environment declares actually
  attaches in a real kernel**, matching the equivalent Python check. Presence in
  the vendored tarballs is not the same as loading — the Python side learned that
  the expensive way when a transitive `urllib3` stopped the kernel booting.

### Changed

- **`ggplot2` and `lubridate` are deliberately NOT in the default R
  environment.** Both solve and install fine; both are excluded on measured cost.
  `library(ggplot2)` takes **193 seconds** on first attach in the wasm kernel and
  `library(lubridate)` 32 — against a default per-test limit of 10 seconds, and a
  student's first editor cell would simply hang. A course that wants them can add
  them to `Tools/jupyterlite/environment-r.yml` and raise its time limits; that
  is now a deliberate, documented choice rather than an accident.

  Worth knowing before adding anything else, to either environment: a kernel env
  has two costs and they fall on different people. *Boot* — fetching and mounting
  the whole env — is paid by everyone on every notebook open and every
  browser-graded submission. *Import* is paid only by a script that uses the
  package, but against the 10-second default per-test limit. Neither is free and
  the second is not proportional to size: the R tidyverse shares a dependency
  graph, so whichever package attaches first pays for all of it (~26s cold, ~58s
  for the set).

  Both environment files now carry their measured numbers, including Python's,
  which had none. `scikit-learn` costs 10.8s to import and `pandas` 4.8s, so
  scikit-learn already exceeds the default per-test limit — worth knowing for
  anyone writing a browser-graded test that uses it.
  `Tools/browser-grading-smoke` prints per-package timings; measure there rather
  than guessing from package counts.

- **`scikit-learn` and `sympy` are dropped from the Python environment.** Both
  were added during the xeus-python migration to preserve parity with what
  Pyodide *could* resolve at run time, not because any lab used them, and both
  are expensive: scikit-learn takes 10.8s to import — over the default per-test
  limit on its own — and sympy 5.9s. The environment goes from 62 packages /
  85 MB to 48 / 75 MB, and loses `requests` → `urllib3` with them, which is the
  dependency whose emscripten module has to be patched or the kernel does not
  boot at all. That patch and its guard stay in place: they cost nothing when the
  package is absent, and a future addition could bring it back.

  `numpy`, `pandas`, `matplotlib`, `scipy`, `statsmodels` and `pillow` remain.
  Note for anyone trimming further: `openblas` is 16 MB, the largest single
  package in the environment, and **only scipy needs it** — numpy does not. scipy
  plus openblas is ~27 MB of a ~69 MB payload for a package whose import is
  nearly free, and statsmodels is the only remaining reason scipy is there. That
  is the biggest boot saving still available, and it is a course decision rather
  than an engineering one.

### Removed

- **Pyodide is gone — ~465 MB of vendored bytes.** `Public/pyodide`, the
  `jupyterlite-pyodide-kernel` federated extension, `check-pyodide-parity.sh`,
  `add-pyodide-extras.py`, `Tools/vendor/pyodide-extra-packages.json`,
  `patch-pyodide-kernel.py` and the unused nb_mypy/astor wheels are all deleted.
  Both editor kernels and both browser graders have been xeus since v0.5.18; what
  remained was a parity anchor for bytes nothing loaded. `verify-jupyterlite.sh`
  now fails if a `pyodide` federated extension or plugin setting reappears, since
  re-adding the kernel means re-vendoring that payload and restoring its CSP
  allowances.

### Changed

- **`script-src` keeps `'unsafe-eval'`, and now says why.** Retiring Pyodide was
  expected to allow narrowing it to `'wasm-unsafe-eval'`. Measured with Pyodide
  fully removed, it does not: JupyterLab cannot activate its plugins, the editor
  never renders a console, and restoring `'unsafe-eval'` with no other change
  makes the same smoke pass. JupyterLab compiles JSON-schema validators at run
  time; that is a JupyterLab requirement, not a Pyodide leftover. The comment and
  the migration plan now record the measurement so it is not retried blind.

  The accidental CSP dependency the spike documented — browser Python grading
  working *because* `data:` was absent from `script-src`, which broke Pyodide's
  classic-worker probe — is genuinely gone, since that probe went with Pyodide.

### Known

- **The vendored kernels are still not on the asset fast path.**
  `/jupyterlite/xeus/` is ~230 MB and the largest asset tree in the app, and a
  kernel boot fetches every package in its environment — ~50 requests, each
  riding the full middleware chain and paying a Fluent session lookup it does
  not need. Putting it on `EditorAssetFastPathMiddleware` was written and
  reverted here: it is the only behavioural server change in this release, and
  WebKit's editor smoke failed deterministically across it while Chromium
  passed. The tree is not only package tarballs — `kernels.json` and each
  `<env>/<kernel>/kernel.json` are fetched during app startup, so
  short-circuiting the chain also skips it for requests made before a kernel
  exists, on the one engine we deliberately serve non-isolated with the
  JupyterLite service worker intercepting fetches. Scoping the prefix to
  `kernel_packages/` is the likely shape; it needs a green WebKit smoke first.

### Fixed

- **The editor smoke test was booting Pyodide, and said so.** Its default leg
  requested `?kernel=python` — the Pyodide kernelspec — deliberately, because
  its probes were written as pyodide-kernel behaviours. Deleting `Public/pyodide`
  deleted that kernelspec, so every leg asked for a kernel that no longer
  existed. Chromium tolerated it; WebKit did not, and the failure presented as
  a Safari-class editor regression — modal dialog over the console, plugins
  failing to activate — rather than as a stale fixture. The selftest now
  defaults to `xpython`, the editor's actual default and the only Python kernel
  that exists. Both premises behind the old default had expired too: the
  `data:`-worker waitAsync polyfill is not pyodide-specific, and service-worker
  stdin is exactly what xeus does on WebKit.

- **The `Atomics.waitAsync` polyfill patch never covered the kernel we
  actually run.** `patch-pyodide-waitasync-worker.py` rewrites the polyfill's
  helper worker from a `data:` URL — blocked by our CSP (`worker-src 'self'
  blob:`), hanging the kernel on engines without native `waitAsync` (older
  Safari / iPadOS) — into a `blob:` one. It globbed only the pyodide-kernel
  extension, and the **xeus** extension ships the identical polyfill, unpatched,
  for both languages. Retiring Pyodide made this load-bearing rather than merely
  tidy: selftest leg 4 stubs out `Atomics.waitAsync` to force the polyfill path,
  and with the pyodide extension gone the xeus chunks are the only ones left for
  it to exercise. Renamed to `patch-waitasync-worker.py` and scoped to every
  federated extension, with `verify-jupyterlite.sh` asserting the same breadth.


## [0.5.18] - 2026-08-05

### Added

- **Saving a browser-graded Python test now fails if the grading environment
  cannot satisfy its imports (#1271).** Browser grading runs a fixed
  `chickadee-python` kernel, and the editor's `connect-src 'self'` CSP leaves no
  runtime install escape hatch, so a package that is not baked in is an
  unrecoverable `ImportError`. That used to surface at the worst possible moment:
  instructor validation is graded by the *native* worker on a full CPython, so a
  test importing `seaborn` validated green and then failed for the first student
  who submitted. The web script create/update endpoints, `PUT /suite`, and the
  MCP `author_script` tool now reject such a write, naming the module, the line,
  and the ways forward. Nothing about the previous Pyodide architecture allowed
  this — there was no fixed package set to check against.

  The check is deliberately narrow, because a false positive blocks an
  instructor from saving legitimate work: it applies only to `.py` files in
  **browser-graded** assignments (worker grading runs real `python3`, where the
  same import is fine), and it accepts anything the setup itself bundles, the
  modules the runner injects (`test_runtime`, `_ck_inputs`), student-module
  names, and any import that is guarded or function-local.

  The available set is derived from the vendored kernel's own package tarballs
  by `scripts/derive-kernel-modules.py`, not from
  `Tools/jupyterlite/environment-python.yml`. The env file states an intent that
  only becomes true after a re-vendor — which needs micromamba and network to
  `repo.prefix.dev`, so CI can never do one — and a check derived from intent
  would accept `import scipy` while the shipped kernel has none. Deriving from
  the bytes also removes the distribution-name-to-import-name problem: the
  tarball says `site-packages/sklearn`, so there is no `scikit-learn` → `sklearn`
  table to get wrong. `scripts/check-xeus-vendored.sh` fails if the derived index
  drifts from the env beside it.

### Changed

- **The pattern-family editor's auto-compute runs on xeus-python (#1271).**
  `Public/pyodide-worker.js` is replaced by `Public/python-eval-worker.js`, which
  boots the same vendored `chickadee-python` kernel the editor and the browser
  grader use. Auto-compute produces the expected value a generated test will then
  assert, so having it run on a different interpreter — with a different numpy —
  from the one that grades it was a real source of "the value it computed is not
  the value the test reproduces". No behaviour change from an instructor's side:
  the worker protocol and the timeout contract are unchanged.

  With this, **no Chickadee-owned JavaScript loads Pyodide.** The only remaining
  consumer is the vendored `jupyterlite-pyodide-kernel`, whose removal — and with
  it the ~465 MB `Public/pyodide` and the `unsafe-eval` in the CSP — needs a
  JupyterLite rebuild that CI cannot run.

### Fixed

- **A long-running browser-graded test could have reported a bogus result.** The
  xeus `execute` helper polled a fixed number of times for the kernel's reply,
  which read like a 2-second execution timeout; a test that really exceeded it
  would have returned whatever partial output existed, with no error. In practice
  it never fired — a xeus-lite cell runs inside `notify_listener`, so a slow cell
  blocks the worker's event loop and the reply is in hand before the poll gets a
  turn, which is why the R smoke grades a 3,139 ms script under a 2,000 ms cap.
  The cap is now a named, overridable dead-kernel backstop rather than an
  accidental limit, and the auto-compute worker sets a much larger one because
  its legitimate waits are longer.

### Changed

- **Python browser grading moved from Pyodide to the xeus-python kernel
  (#1271).** Test scripts now execute on the same `chickadee-python` environment
  the notebook editor runs, so authoring and grading are one environment for
  Python as they already were for R — "it ran in the editor" now implies "it
  grades in the browser". No configuration: there is one Python substrate.
- **`scipy`, `sympy`, `scikit-learn`, `statsmodels` and `pillow` are now in the
  editor/grading environment.** Pyodide resolved these at run time from its
  package index; a fixed environment has no runtime escape hatch, so they are
  baked in. They are now available while *authoring* too, which Pyodide-only
  grading never allowed. A browser probe asserts each one actually imports in a
  real kernel, not merely that it is present in the vendored bytes.
  `networkx`, `seaborn` and `plotly` have no emscripten-forge build and remain
  unavailable.

### Removed

- **The main-thread grading fallback.** It existed only because Pyodide can run
  on the main thread, and it carried a real hazard: a synchronous CPU-bound loop
  in student code never yields, so the per-test timer never fires and the tab
  freezes with the submission lost. Every substrate is now a Web Worker, where
  `Worker.terminate()` actually kills a runaway. A browser without Worker support
  fails the grade over to the native worker.
- **`Public/grading-worker.js` and the Pyodide package preloader.** A fixed
  environment needs no import scanning, which retires the class of bug where a
  bundled helper's imports were invisible to the scanner.

### Fixed

- **Browser grading of R never ran in the browser on Chromium or Firefox.** The
  student notebook page is cross-origin isolated on those engines, and a worker
  spawned by an isolated page must itself be served `Cross-Origin-Embedder-Policy:
  require-corp` or the browser refuses the worker script outright. The header is
  stamped from a per-path allowlist that `/r-grading-worker.js` was never added
  to, so every R submission was blocked at worker start and quietly failed over
  to the native worker — correct marks, none of the speed the feature exists for.
  Safari was unaffected (it runs the page non-isolated). Both per-language
  grading workers are now allowlisted, and a test reads the spawn sites out of
  the page scripts and fails if the list drifts from them in either direction.

### Fixed

- **The editor and browser-grading Python environment now actually contains
  scipy, sympy, scikit-learn and statsmodels.** `environment-python.yml` had
  listed them since the xeus-python migration and a release announced them as
  available, but adding a name to that file changes nothing until the kernel is
  rebuilt — and the vendored bytes had never been rebuilt, so `import scipy`
  would have failed with an unrecoverable `ImportError` for any student whose
  test used it. The kernels are re-vendored, and a browser probe now asserts
  every declared package genuinely imports in a real kernel rather than merely
  being present in the tarballs.

- **The re-vendored kernel would not have booted at all without a second
  library patch.** `scikit-learn` pulls in `requests` → `urllib3`, and
  `urllib3.contrib.emscripten.fetch` constructs a Pyodide-only streaming fetcher
  at module import under exactly the conditions a grading worker meets. That
  raised out of `xkernel.start()`, so the failure was total rather than
  degraded. `scripts/patch-xeus-python-http.py`, which already neutralised the
  identical hazard in `pyodide-http`, now covers urllib3 too, and
  `check-xeus-vendored.sh` asserts it — an un-patched re-vendor is a CI failure
  rather than a dead editor. Nothing short of booting a real kernel could have
  caught this: the environment solves cleanly and every other guard passes.

### Added

- **Re-vendoring the xeus kernels is a CI workflow, not a manual step.**
  `.github/workflows/revendor-kernels.yml` rebuilds the JupyterLite bundle and
  both kernel environments and commits the result — on demand, or when a pull
  request changes an environment file. "CI cannot do this, it needs micromamba
  and network to repo.prefix.dev" had been the standing assumption and it was
  simply wrong: a hosted runner has unrestricted network and micromamba is a
  single ~7 MB download. Believing otherwise is what allowed the environment
  file and the shipped kernel to drift apart for a whole release.

- **`scripts/check-env-vendored-sync.sh` fails when they drift again.** It is the
  only guard that compares *declared intent* to *shipped bytes*; every other one
  compares the vendored tree to itself, which is why none of them could see four
  missing packages. It costs two file reads, runs on every JupyterLite-relevant
  PR, and points at the workflow that fixes it.


## [0.5.17] - 2026-08-05

### Added

- **Browser-graded R, on the xeus-r kernel (#1271).** R assignments set to
  `gradingMode: browser` now grade in the student's browser, like Python ones.
  Previously every `.R` test script came back as an error reading "R test
  scripts require WebR" and R could only be graded by the native worker; WebR
  was never a viable route, since `jupyterlite-webr` caps at
  `jupyterlite-core<0.7` and Chickadee pins 0.8.x. The substrate is the same
  vendored `chickadee-r` environment the notebook editor already boots for R
  notebooks, so authoring and grading run one environment with no package skew.
  `RunnerCore` still owns the suite loop, dependency gating, and output
  interpretation for both languages — the kernel supplies only "run this script,
  report its exit code and streams", the seam `ScriptExecutor` exists for.

### Changed

- **The browser runner boots only the runtime an assignment needs.** Test
  scripts are routed to a Python (Pyodide) or R (xeus-r) substrate per script,
  using the classification `RunnerCore` already shares with the native worker, so
  an R lab no longer loads Pyodide and a Python lab never fetches the R
  environment.

### Fixed

- **Per-student personalization reaches R tests graded in the browser.** The
  browser wrote `_ck_inputs.py` for every assignment, so a personalized R test
  saw an empty `chickadee_inputs()`. The seed endpoint now reports the
  assignment's resolved language and the browser writes `_ck_inputs.R` for R
  assignments, matching what the native worker delivers.


## [0.5.16] - 2026-08-05

### Security

- **The Compose runner no longer mounts the data volume.** It mounted
  `chickadee-data` read-only for one reason: to read `/data/.worker-secret`.
  That volume also holds the SQLite database, every submission, and the results
  tree, and a test script runs as the same uid as the runner — so the secret
  file's `0600` mode was no barrier. A student script could read the runner ↔
  server HMAC secret and sign worker API calls, which is exactly what the
  environment allowlist in `mergedScriptEnvironment` withholds it to prevent,
  and could read student submissions and the database directly. Enabling
  `--sandbox` would not have closed either hole: the Linux sandbox isolates the
  network, not the filesystem. The secret now arrives through
  `RUNNER_SHARED_SECRET`, which both the server and the runner already read and
  which the server already prefers over the persisted file, so the runner
  container has no access to student data at all.

### Changed

- **`RUNNER_SHARED_SECRET` is required for Docker Compose.** It is now the only
  channel by which the runner container learns the secret, so Compose fails
  fast with a pointed message when it is unset rather than starting a runner
  that cannot authenticate. Generate one with `openssl rand -base64 32`. A
  deployment with no separate runner container may still leave it unset and
  fall back to the auto-generated `.worker-secret`.

### Changed

- **The worker launches scripts through swift-subprocess.** Every subprocess
  the runner starts — sandboxed, unsandboxed, and the optional `make` build
  step — now goes through one `executeScriptLaunch` path on every platform,
  replacing the hand-written `fork()`/`execve()`/`waitpid()` implementation
  that existed only because Foundation's `Process` deadlocked forking from the
  multithreaded daemon (issue #1139). The async-signal-safety burden in the
  forked child, the manual `argv`/`envp` marshalling, the `waitpid` poll loop
  on a detached thread, and the separate macOS `Process` path are all gone.
  Bounded output capture (1 MB per stream, truncation marker) and the explicit
  `ScriptOutput.timedOut` flag are unchanged, so the shared output contract in
  `Tests/Fixtures/output-contract.json` is untouched.

### Fixed

- **A timed-out script's background children are killed on macOS too.** Session
  isolation (`setsid`) and the group-wide SIGTERM → SIGKILL ladder were
  previously Linux-only; the macOS path signalled the direct child alone and
  leaked anything it had backgrounded. Both platforms now run the same
  teardown.
- **A cancelled job no longer leaves its script running.** Cancelling the task
  around a script run tears the process group down; the old Linux path polled
  `waitpid` on a detached thread and never observed cancellation at all.


## [0.5.15] - 2026-08-05

### Added

- **The editor smoke matrix now probes `input()` against the kernel students
  actually get.** The selftest runs `?kernel=python` — the Pyodide kernel, which
  since v0.5.14 is no longer the editor default (`defaultKernelName` is
  `xpython`). Without this, every stdin and freeze-detector result we had
  described a kernel nobody boots. The new step is blocking on both engines, and
  both must run: they use different synchronous-stdin transports, so a change
  that breaks only one would otherwise ship green. Chromium is cross-origin
  isolated and carries stdin over `SharedArrayBuffer`; WebKit is served
  non-isolated and carries it over the service worker, which
  `JupyterLiteConfigFlagMiddleware` re-enables per request for that engine.
  Measured: `input()` round-trips on both.

### Changed

- **Corrected three stale editor-kernel claims.** `docs/xeus-r-kernel-spike.md`
  asserted that xeus "hard-requires SharedArrayBuffer with no fallback" —
  untrue, and load-bearing: it is why we believed moving Python to xeus would
  break Safari, and why #1270 briefly shipped a changelog entry describing a
  Safari regression that does not exist. The same document still routes builds
  through `emscripten-forge-dev`, frozen since 2026-04-09.
  `docs/notebook-editor-kernel-boot.md` separately described cross-origin
  isolation as "unconditional" when `COEPMiddleware` exempts WebKit, and
  described the service worker as disabled when that is true of Chromium only.
  All three now record what was measured, when, and against which kernel.


## [0.5.14] - 2026-08-05

### Changed

- **The editor's Python kernel is now xeus-python.**
  `Tools/jupyterlite/environment-python.yml` and `environment-r.yml` build
  `xpython` (xeus-python 0.19.0, Python 3.13.1) and `xr` (xeus-r 0.11.2,
  R 4.5.3), so authoring runs one kernel technology for both languages.
  Notebooks normalize to `xpython` / `xr`; new starter scaffolds are written
  with the `xpython` kernelspec. Verified in headless Chromium against the
  vendored bytes: both kernels boot and execute cross-origin isolated,
  pandas/numpy/matplotlib import, and the boot makes zero external network
  requests.
- **Each kernel gets its own emscripten-forge env.** A xeus kernel fetches its
  whole env at boot, so building Python and R into one shared env made every
  Python boot pull all of `r-base` and every R boot pull numpy/pandas/
  matplotlib — slow enough to time out the editor probes with "kernel never
  reported idle". `check-xeus-vendored.sh` now asserts the two envs stay
  distinct, and that neither has acquired the other's packages, so a re-vendor
  cannot silently recombine them.
- **Kernel builds moved to the `emscripten-forge-4x` channel.** The
  `emscripten-forge-dev` alias the R kernel was pinned to serves the frozen 3x
  (emscripten 3.x ABI) channel — its last build of any package was 2026-04-09 —
  so the vendored R kernel was tracking a channel that no longer receives fixes.
  This also unblocked Phase 3 of the xeus spike: xeus-python has been built
  against xeus 6 with a real `run_exports` pin since 0.18.1 (2026-03-09), which
  is the supported pairing the spike said to wait for.
- **`scripts/check-xeus-vendored.sh` now guards both kernels.** It asserts
  `xpython` and `xr` are registered, share one env, declare the right language,
  and each have both a loader and its `.wasm` beside it — so a partial
  re-vendor fails in CI rather than in front of a student.

### Fixed

- **The editor kernel no longer hangs on cross-origin-isolated engines.**
  `pyodide-http` (an unavoidable dependency of `xeus-python-shell-lite`) selects
  a Pyodide-specific streaming implementation whenever `crossOriginIsolated` is
  true. It is not pyjs-compatible, so on Chromium the kernel never left
  `kernel_starting` and the editor sat on "Kernel Connecting" indefinitely;
  WebKit, which Chickadee serves non-isolated on purpose, took the library's
  XMLHttpRequest fallback and worked fine. `scripts/patch-xeus-python-http.py`
  forces that fallback on every engine — upstream's own documented degradation
  for non-isolated contexts — and `check-xeus-vendored.sh` asserts it on the
  committed bytes, since the fault is invisible both in the JupyterLite REPL and
  on WebKit.

### Known issues

- **Editor and browser grader are no longer the same Python.** Authoring runs
  xeus-python 3.13; browser grading and `/validate` still run Pyodide 3.14. The
  native worker remains the authoritative grader, so marks are unaffected.


## [0.5.13] - 2026-08-05

### Added

- **Review: what the corrected Leaf rule unblocks.** `docs/leaf-decomposition-review.md`
  sizes the `assignment-new` / `_assignment-edit-body` duplication against real diffs
  rather than marker counts, and lands on a four-slice plan. Verifies (control-first,
  with a falsified assertion) that three inline partial includes resolve inside an
  extend/export block. Records two live create-page defects traced to duplicated
  JavaScript rather than to template structure: per-student `=` expressions degrade to
  literal strings in section inputs, and section drag-reorder raises a spurious failure
  alert because a second, redundant handler posts to an endpoint that does not accept
  the method.

### Fixed

- **Per-student `=` expressions no longer degrade to literal strings on the
  Create Assignment page.** That page carried a pre-v0.4.160 inline copy of the
  section-inputs editor whose value parser had no `=` branch, so an expression
  typed into a section input was persisted as the literal text and the payload
  omitted `expressions` entirely. It now loads the same shared modules the edit
  page uses.
- **Section drag-reorder now persists on the Create Assignment page.** The
  reorder endpoint was derived from the suite URL by rewriting a trailing path
  segment, which no-ops on that page's query-string URL and posted to a GET/PUT
  endpoint; the page's own fallback handler read an out-of-scope `draftID` and
  threw before its request. The list reordered on screen, nothing was saved, and
  a failure alert appeared. The endpoint is now an explicit, required builder.
- **Deleting a suite section no longer raises two confirmation dialogs** on the
  Create Assignment page, which bound duplicates of handlers `suite-table.js`
  already owns.

### Changed

- **The suite-section shells are one shared partial** (`_suite-sections.leaf`),
  used by both authoring surfaces, parameterized on the per-page endpoint base
  and whether its forms submit in place.
- **`checkUWDates` is shared** (`ChickadeeUI.checkUWDates`) instead of living as
  three inline copies that had drifted on null-handling and on label text. Both
  labels are preserved.


## [0.5.12] - 2026-08-05

### Changed

- **Switching notebooks in the workbench no longer reloads the page.** Opening
  the solution, or toggling between the authored template and the rendered
  values, swaps the notebook half in place instead of navigating. The Pyodide
  kernel still restarts — it belongs to whichever notebook is open — but the
  edit half is no longer rebuilt with it, so assignment details typed and not
  yet saved survive the switch. The address bar still moves, so a reload lands
  on the same notebook and Back returns to the previous one.

### Fixed

- **The workbench's view control showed the wrong view as selected.** "With
  values" was marked as the active choice regardless of what was open. Course
  staff are defaulted to the *template* on a notebook carrying placeholders, so
  the control mislabelled itself on exactly the assignments it exists for.

- **The workbench page no longer scrolls.** The shell sized itself to the full
  viewport while the site nav sat above it, making the document taller than the
  window — so the nav scrolled away under the pointer while the panes stayed
  pinned, contradicting the invariant the layout is built on. The chrome and the
  page body now share the viewport.


## [0.5.11] - 2026-08-05

### Changed

- **The assignment workbench is now a single document.** The edit page and the
  notebook editor were composed as two same-origin iframes; they are now
  rendered inline by one template, each bound to its own sub-context. The
  wrapper frames are gone and the only remaining `<iframe>` is the JupyterLite
  editor itself. Writes refresh the edit half by swapping its DOM rather than
  reloading, so a save, a suite-section rename, or a support-file upload no
  longer costs the live Pyodide kernel a 10–30s reboot. Switching between the
  starter and the solution stays a full navigation — the kernel restarts either
  way — and is guarded by an unsaved-changes prompt.

### Fixed

- **Leaf partial decomposition was never blocked by a LeafKit parser bug.** The
  long-standing rule of "at most one inline `extend(...)` include per template"
  traced to a misdiagnosis: what actually fails is the literal tag text
  appearing in template *prose*, including inside HTML comments, which Leaf's
  lexer reads as a real tag with no parameters. Multiple includes, and the
  sub-context form, work fine. `CLAUDE.md` is corrected.

- **An assignment with no starter notebook no longer breaks its workbench.**
  Inlining the notebook made a missing one able to fail the whole authoring
  page; the pane now degrades to a placeholder and the edit half stays usable,
  which is where a starter gets uploaded in the first place.


## [0.5.10] - 2026-08-04

### Fixed

- **Writes in the workbench no longer navigate the editor pane away.** Every
  form on the assignment editor — Save, Create solution, the secret-reveal
  toggle, and suite-section create/rename/delete — redirects to the chromed
  standalone editor when it succeeds. Inside the workbench that redirect landed
  *in the left pane*, so adding a suite section replaced the editor with a
  second copy of itself under the workbench's own Save button; because the
  standalone page is not cross-origin isolated, the browser then refused it
  under `require-corp` and the pane went blank. Those writes are now fetched and
  the pane re-renders itself, keeping the author's scroll position. The
  standalone `/edit` page is unchanged and still follows its redirects.
- **The workbench's Save reports the real result.** It replied "saved" before
  submitting, because the pane was about to navigate and a later reply would
  never arrive — so a failed save looked like a successful one.
- **`Create solution` no longer redirects to a 404.** It writes a draft
  notebook, but the solution resolver only looked in the test-setup zip and at
  validation submissions, so its own redirect target reported that no solution
  existed. Every other place that asks whether an assignment has a solution
  already counted the draft, which is why the Files table showed an Edit button
  beside a dead link.


## [0.5.9] - 2026-08-04

### Fixed

- **Browser probe setup retries the Ubuntu package fetch.** Installing Node and
  npm is an unauthenticated plain-HTTP fetch of ~40 packages from
  `archive.ubuntu.com`; when that mirror is unreachable the step exits 100 and
  takes the whole probe — and the required editor-smoke gate — down with it.
  Observed on PR #1264: `Unable to connect to archive.ubuntu.com`. The
  network-bound half now retries three times with a short backoff. `npm ci` is
  deliberately left outside the loop, so a genuine lockfile failure still fails
  once and clearly.

### Fixed

- **The CI image rebuild no longer times out.** `mirror-images.yml` builds the
  derived `swift-ci` image by apt-installing a heavy package set from
  `archive.ubuntu.com` behind a retry loop; with that mirror flaking the build
  step alone consumed 29.3 of its 30-minute budget and was killed, leaving the
  image unpublished. Since the job runs weekly, a silent timeout means a stale
  CI image for everyone. Budget raised to 60 minutes.

### Changed

- **Browser probe jobs run in the `swift-ci` image and own a build cache.** They
  previously used the plain Swift mirror and `apt-get`-installed Node and npm at
  job start — the same per-job cost the `swift-ci` image already exists to
  remove, and a hard failure whenever `archive.ubuntu.com` is unreachable.
  `nodejs`/`npm` are now baked into that image and the probes use it; the apt
  path remains as a guarded fallback so a caller on the plain mirror, or a run
  that beats the image rebuild, still works.

  They also now save and restore a probe-owned build cache when the shared
  swift-tests key misses. That key is written by a job in another workflow, so
  nothing could order the probes after it; a miss meant a cold Swift build, and
  re-running a probe on the same commit paid for it again every time because
  nothing the probes did ever populated a key they could read back. The shared
  key is deliberately left alone — a probe winning that race would publish a
  `.build` holding only `chickadee-server` for the swift-tests jobs to restore.

### Fixed

- **Browser probe jobs no longer time out on a cold build.** `browser-probe-setup`
  builds `chickadee-server`, and the shared build cache it restores is keyed on
  `hashFiles('Sources/**', 'Tests/**')` — so the key is new on any PR touching
  either, and the job that populates it lives in a different workflow, which
  `needs:` cannot order against. The probes therefore cold-build, and the setup
  step alone measured 23.2 min on a passing run and 29.0 min on a killed one,
  against a 30 min ceiling. The budget only ever fit the cache-hit path; on a
  miss the job died in setup with every test step `skipped`, and GitHub reports
  a timeout-kill as `cancelled`, which reads as an unrelated concurrency cancel.
  Budgets raised to 50 min (75 for the grading probe, which runs 12 iterations
  per engine on top of the same setup).

### Changed

- **The workbench is now the assignment editor.** The `/instructor` dashboard's
  Edit buttons open it, and its chrome has been cut back to what the panes do
  not already provide: no Assignment/Solution tab strip, no Hide-editor or
  Full-width-editor buttons, no repeated assignment title, and no Download in
  the notebook pane. The left pane already names the assignment, lists its
  files with links, and offers Edit for each.

- **One Save, in the top-right corner.** "Save & Validate" and "Save to
  assignment" were two buttons for what an author thinks of as one action.
  The single Save writes the open notebook and the assignment's details and
  re-validates.

  It deliberately does **not** close the assignment. The standalone edit page
  still does, unchanged — but the workbench is a live-edit surface, where the
  suite, families and notebook endpoints all already write without changing
  visibility, and closing on save there would pull a lab out from under the
  students sitting in it.

- **Clicking Edit in the Files table opens that notebook in the workbench's
  notebook pane.** Previously those links carried no `embedded=1`, so inside
  the workbench they navigated the *left* pane into a fully chromed notebook
  page and the assignment editor disappeared. They are still ordinary links on
  the standalone page.


## [0.5.8] - 2026-08-04

### Security

- **The workbench validates a notebook destination before pointing a frame at
  it.** The tab destinations reach the page as DOM text and the sink is an
  iframe `src`, where a `javascript:` URL would be script execution in
  Chickadee's own origin. The server builds that map from its own test-setup
  identifiers, so nothing hostile could reach it — but the page did not enforce
  that, and the gap between "is not attacker-controlled" and "cannot be" is the
  whole bug class. Destinations are now accepted only if they match the
  same-origin notebook-page path shape, checked both where a click is resolved
  and again at the assignment itself. Flagged by CodeQL.

### Added

- **The workbench can switch between a notebook's template and its rendering.**
  On an assignment whose notebook carries `{{placeholders}}`, the notebook pane
  gains a Template / With values control beside the Assignment / Solution tabs,
  so an author can compare what they wrote against what a student sees without
  leaving the page. The control is rendered per file and only where the two
  readings actually differ — on a notebook without placeholders they are
  byte-identical, and switching would be a kernel reboot for no change.

  Pane URLs now always carry an explicit `view=`. The server defaults staff to
  the template on a personalized notebook, so omitting it made the "Assignment"
  tab mean the template on one assignment and the rendering on another.

### Changed

- **The workbench holds one notebook document, not one per destination.** The
  tabs and the view switch repoint a single iframe. Previously each notebook got
  its own live iframe so switching was instant; with the view axis that would
  have been up to four simultaneous Pyodide kernels and an eviction policy to
  bound them — a lot of machinery for a secondary interaction. The workbench
  exists to put the edit page and *a* notebook on screen together, which holds
  with one. The accepted cost: switching notebooks re-boots the kernel.

  The browser check now asserts the iframe count directly, so reintroducing a
  frame per destination fails rather than passing quietly.

### Fixed

- **Collapsing the workbench editor now actually gives the notebook the window.**
  Hiding the edit pane removed it from the grid without re-declaring the
  columns, so the notebook landed in the content-sized column and shrank to
  roughly 300px — narrow enough that the embedded notebook page rendered its
  "Open on a larger screen" notice. Collapsing the editor to see more of the
  notebook showed none of it. Found by screenshotting the real page; the
  collapse unit tests were correct and could not see it, so the browser check
  now asserts the rendered width.

- **The workbench no longer shows two template/values controls.** The embedded
  notebook page rendered its own view-toggle link beside the workbench's, and
  that link carries no `embedded=1` — following it would have loaded the fully
  chromed page inside the pane. The page's own toggle is suppressed when it is
  a workbench pane; the workbench's control is the one that works there.


## [0.5.7] - 2026-08-04

### Added

- **The workbench smoke check now covers the two interactive behaviours that had
  no browser coverage.** It asserts that a keystroke inside a pane reaches the
  shell as `chickadee:activity` — the chain that stops the idle watchdog from
  signing an author out while they are actively typing, a bug that otherwise
  only shows up half an hour into a session — and that selecting the Solution
  tab mounts it while leaving the assignment notebook mounted, so switching back
  is a pane toggle rather than a second cold kernel boot. The seeded assignment
  now gets a reference solution so the Solution tab actually renders; without it
  those assertions were unreachable.

  Both were verified by falsification: disabling the activity forwarder and
  forcing unmount-on-switch each fail the check with the matching diagnostic.

### Changed

- **`docs/ci-flakiness.md` records the first chromium sighting of the grading
  hang.** Family 2 is documented as webkit-only, and the note that "chromium
  passes 12/12" is what makes a chromium hang look like a genuine regression.
  One was observed (and did not reproduce on rerun), so the doc now says it is
  rarer on chromium rather than absent. The gate policy is deliberately
  unchanged — chromium stays at hard zero so a recurrence is loud.


## [0.5.6] - 2026-08-04

### Added

- **The workbench's cross-origin-isolation chain is now checked in a real
  browser.** `Tools/editor-smoke-test/workbench-check.mjs` seeds an assignment
  through the real HTTP API, opens the workbench as its instructor, and asserts
  the shell, the left pane, and the *nested* notebook iframe are each isolated
  (inverted for WebKit, which runs the comlink path deliberately), that the
  nested frame really has `SharedArrayBuffer`, and that the solution pane stays
  unmounted until asked for. Runs in the editor-smoke matrix on both engines.

  Unit tests can only pin the response headers. Whether the isolation those
  headers are meant to produce actually survives two levels of framing is a
  browser question, and getting it wrong is silent — the kernel still boots,
  just on the slower service-worker transport, with no error reported anywhere.
  The check was verified by removing each half of the isolation rule in turn and
  confirming it fails with the matching diagnostic.

  The editor-smoke path filter now also covers the workbench route, template and
  scripts, so a change to any of them runs the smoke rather than skipping it.

### Fixed

- **Editing inputs in the workbench now warns that the notebook is stale.** The
  assignment workbench's shell already knew how to raise a "reload the notebook"
  chip when global inputs or section variables changed, but nothing sent the
  message — so saving an input silently left the notebook pane rendering a
  substitution of the old values, which is the confusion the chip exists to
  prevent. The two inputs editors now announce their saves. The notice is
  deliberately advisory rather than an automatic reload: reloading that pane
  restarts the Python kernel and discards the author's live state, so the author
  chooses when to pay for it.

### Added

- **Collapse the workbench's editor pane.** A "Hide editor" toggle in the
  workbench toolbar (and `Enter`/`Space` on the splitter) gives the notebook the
  full window and restores the pane to its previous width. Previously the only
  way to widen the notebook was to drag the splitter to its stop, which matters
  most on a 1280–1440px laptop where the split leaves the notebook near its
  minimum.

### Changed

- **`ChickadeeUI.notifyWorkbench`** replaces the private copy in `notebook.js`
  as the one place a page tells the workbench shell that something the other
  pane depends on has changed. Three pages send these notes and each is also
  reachable as a standalone page, so the guards — silent when there is no shell
  above, and an explicit target origin rather than a wildcard — are now written
  and tested once instead of per caller.


## [0.5.5] - 2026-08-04

### Added

- **Assignment workbench — the edit page and the notebook editor, side by side.**
  A new instructor surface at `/instructor/:assignmentID/workbench` puts the
  assignment editor in a left pane and the embedded JupyterLite editor in a
  right pane, with a tab strip that switches the notebook pane between the
  starter notebook and the reference solution. Authors can read and change
  global inputs, section variables, suite entries and deadlines while a Pyodide
  kernel boots or a validation run finishes, instead of paying a full editor
  cold boot on every hop between the two pages. Reached from a "Workbench"
  button on the edit page; the standalone `/edit` and
  `/testsetups/:id/notebook` pages are unchanged and remain the default.

  The shell renders no assignment content of its own — it composes the two
  existing pages as same-origin iframes, so the suite editor, inputs editors and
  `notebook.js` all run unmodified. The solution pane stays unmounted until its
  tab is first selected, then stays warm, so switching costs one kernel boot
  rather than one per switch; a device reporting low memory keeps a single
  kernel and reboots on switch instead. The splitter is drag- and
  keyboard-operable and clamps so the notebook pane can never fall under the
  width at which it would replace the editor with its "open on a larger screen"
  notice; below a viewport that can hold both panes honestly, the layout falls
  back to one pane at a time.

### Fixed

- **Cross-origin isolation now covers the whole editor frame chain.** Isolation
  is a property of every ancestor, so nesting the notebook page inside another
  page requires the outer documents to carry `COOP`/`COEP` as well. Without it
  the editor iframe would lose `SharedArrayBuffer` and silently fall back to the
  service-worker kernel transport on Chrome and Firefox — and, under
  `require-corp`, the sibling pane would have been refused outright. The
  workbench routes are isolated on the same terms as the notebook page,
  including the WebKit exemption that keeps Safari on its comlink path. Plain
  `/instructor/*` pages are unaffected.


## [0.5.4] - 2026-08-03

### Added

- **Course staff author notebooks against the template, not a rendering.** A
  notebook with personalization is two documents: the template the author
  writes (`patients = {{patients}}`) and the per-viewer rendering the server
  produces from it. Staff only ever saw the second one — their own values,
  substituted in — so the placeholders were not visible, not editable, and
  edits to a substituted cell were silently reverted on save (correctly: the
  alternative was baking one person's values into the class template). Staff
  opening the starter or the solution now get the template by default, with
  `{{name}}` standing as written; typing a placeholder into a cell stores it
  verbatim. The two views are separate working copies, so a "View with values"
  switch in the editor toolbar moves between them without either clobbering the
  other's edits, and Submit stays on the rendered view — a template does not
  run. Nothing changes for students, who always get their rendering, or for an
  assignment with no personalization, where the two views are identical bytes.

### Fixed

- **The reference solution was reachable by any enrolled student through
  `/testsetups/:id/notebook/source?file=solution`.** The notebook *page* has
  always gated the solution to course staff — with a comment warning against
  relying on the absence of a UI link — but the raw content endpoint behind it
  never applied the same check, so a student who guessed the query parameter was
  served the answer key as JSON. It now enforces the same staff gate.


## [0.5.3] - 2026-08-03

### Added

- **`variable_equality` pattern families support a per-student `expectedVarRef`.**
  "This student's `sd_systolic` equals this student's value" is the simplest
  personalization there is, but it was rejected outright — so an author who wanted a
  per-student answer for a variable exercise had to reshape it into a function first,
  purely to satisfy the grader. The R renderer already had the plumbing; the Python
  one never emitted the personalization preamble and baked the expected in as a
  literal. Both now bind the value from `_ck_inputs`, and the validator's single
  per-student gate is split in two: `kindSupportsPerStudentArgRefs` (unchanged — a
  bound `$name` must reach a called function) and `kindSupportsPerStudentExpected`
  (now including `variable_equality`). Arg refs stay rejected for
  `variable_equality`, whose `args[0]` is the variable *name* and is baked in as a
  literal — a ref there would be silently ignored rather than personalizing anything.
  Families with no per-student refs render byte-identically, so existing `spec_hash`
  / `TestSetupCache` keys do not churn.


## [0.5.2] - 2026-08-03

### Added

- **"Save to assignment" in the notebook editor.** Course staff (TA+) can now
  write the notebook they are editing in the embedded JupyterLite editor back to
  the assignment, from the browser — the starter notebook and the reference
  solution both. Previously JupyterLite kept the live document in the browser
  and the only ways to change an assignment's notebooks were an upload on the
  new-assignment page or the MCP `update_notebook` / `update_solution` tools;
  the editor's Edit button was effectively a scratchpad. The new endpoint
  (`POST /testsetups/:id/notebook/save`) reuses those tools' server-side steps,
  is versioned like every other authoring write, and re-runs validation — but,
  matching the other live-edit endpoints rather than the MCP tools, it never
  changes the assignment's visibility, so fixing a starter notebook mid-lab does
  not close the assignment out from under students.

### Fixed

- **Course staff can edit an assignment's notebooks while it is closed.** The
  notebook editor locked itself read-only ("This assignment is closed — view
  only") for everyone on a closed assignment, including the staff authoring it —
  and an assignment is closed for exactly the window in which it is being
  written, since creating, cloning, or saving one returns it to closed. Staff
  (TA+ or admin in the assignment's course) now keep an editable starter and
  solution notebook regardless of the closed state; students are unaffected, and
  submission stays gated by the closed state for everyone.


## [0.5.1] - 2026-08-02

### Added

- **`delete_support_file` MCP tool.** Removes one non-graded support/data file from
  an assignment's test setup. `author_script(tier: "support")` could create and
  replace support files but never remove one, so retiring a helper module or a stale
  fixture meant overwriting it with a stub — leaving a dead entry in the setup zip
  that students could still download. The tool refuses graded rows (pointing at
  `delete_suite_item` or the owning family/check) and the reserved setup members
  (`test.properties.json`, `assignment.ipynb`, `solution.ipynb`), clears any
  `graderOnlyFiles` / `datasets` mark naming the file, re-syncs the shared support
  directory so student symlinks disappear, and re-runs validation — so a remaining
  test that still sources the file fails loudly instead of at submission time.
  Content catalog is now 52 tools.

### Fixed

- **R pattern-family and notebook-check cases can express `NA`.** An authored JSON
  `null` now renders as R's `NA` rather than `NULL`, and a null interleaved among
  scalars no longer demotes the whole array to `list(...)` — `[60, null, 20]` renders
  as `c(60, NA, 20)`, `["G2", null, "G4"]` as `c("G2", NA, "G4")`. Previously `NULL`
  silently vanished inside `c()`, so an NA-bearing case handed the student's function
  a list and failed with `'list' object cannot be coerced to type 'double'` before the
  function was meaningfully exercised. This made the "NA in, NA out" half of a
  function's contract unauthorable as a pattern family, forcing hand-written scripts.
  Mixed-kind arrays still render as `list(...)`; a null does not rescue them.


## [0.5.0] - 2026-08-01

### Changed

- **Chickadee 0.5.0.** Marks the conclusion of the first full course offering
  run on Chickadee and the close of the 0.4 series. The system this milestone
  snapshots: Python and R assignments; browser (Pyodide/wasm) and native
  worker grading sharing one RunnerCore implementation; per-student
  personalization, pattern families, and notebook checks; achievements and
  slip days; per-course roles; BrightSpace grade sync; the MCP authoring and
  admin-diagnostics surfaces; OIDC SSO; and zero-downtime auto-deploys. The
  0.1.0 – 0.4.669 release history is archived in CHANGELOG-0.4.md;
  development now shifts to next year's feature work.


## [0.4.670] - 2026-08-01

### Changed

- **0.5-boundary cleanup pass.** Closes out the 0.4 series ahead of the 0.5.0
  milestone: the CI test image now installs `r-base` and pandas/matplotlib so
  the R execution-path and dataframe/plot suites actually run in CI (their
  availability guards were permanently false before); the browser graders'
  shared Python snippets, exit-code derivation, MEMFS writer, and package
  preloader moved into one `Public/grading-shared.js` consumed by both the
  grading worker and the main-thread fallback (the fenced-region drift test is
  retired, and the grading worker is now spawned with the page's cache-buster
  so all grading files pin to one release); six APITests suites that spawn
  subprocesses or bind ports gained `.timeLimit` traits; the `alert()` ratchet
  now also covers first-party `Public/*.js`; and the second migration
  consolidation folded the post-#502 incremental migrations into their
  canonical `Create*` files, removing the boot-order hazard class behind
  #1077.

### Removed

- **Pre-0.5 compatibility shims.** The `WORKER_SHARED_SECRET` env alias (a
  deprecation warning had been shipping; use `RUNNER_SHARED_SECRET`), the
  `GET /admin/workers` and `POST /admin/worker-secret` route aliases, the two
  "one-time" legacy boot sweeps that ran on every boot, the decode-and-ignore
  `suiteFiles`/`suiteConfig` fields on `/edit/save`, the verified-dead overlay
  pattern-family editor path, the `NotebookFunctionScanner` memberwise-init
  realignment shim, and the legacy `isOpen` key on course-bundle exports (the
  read-side fallback stays, so old bundles import unchanged).

### Fixed

- **Documentation debt.** `CHANGELOG.md` history through 0.4.669 archived to
  `CHANGELOG-0.4.md`; CLAUDE.md's per-version log compressed into a 0.4
  retrospective; `docs/architecture.md` and `README.md` refreshed to describe
  the five-target + wasm reality, both MCP surfaces, and per-course roles;
  finished-era investigations moved to `docs/archive/`; stale "not yet built"
  headers corrected; and the manual minor-bump procedure is now documented in
  `docs/release-process.md`.

