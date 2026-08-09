# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project follows Semantic Versioning.

Releases before 0.5.0 (the 0.1.0 – 0.4.669 history, ~660 releases across the
first course offering) are archived in [CHANGELOG-0.4.md](CHANGELOG-0.4.md).

## [Unreleased]

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

