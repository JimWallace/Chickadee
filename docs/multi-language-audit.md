# Multi-language support: architecture audit

Scope: the arc from Lua's completion (#1282) through Racket (#1305) — Octave
(#1292), the upload-only submission mode and C++ (#1293–#1296, #1303), the
runner language gate (#1297, #1300), and Racket (#1305). Audited at v0.5.35.

The headline is narrow and specific. **The server half of this arc is in good
shape; the runner half of the sixth language is absent.** Racket renders,
validates, refuses the right kinds and personalizes correctly — and no
`chickadee-runner` can claim, dispatch or execute a single Racket job. Three
independent defects stack in exactly the order that hides the two behind them.

Everything else here is smaller: one coherence rule that generalised at two of
its five sites, a set of guards that are hand-enumerated where `allCases` was
available, and documentation that stops at the fifth language.

---

## The three that stack (Racket is not gradable)

They must be read in this order, because each one masks the next. Fixing F3
alone surfaces F1; fixing F1 alone surfaces F2. Any fix that does not close all
three leaves Racket exactly as broken, with a different symptom.

### F1 — A generated `.rkt` test is dispatched to `/bin/sh`

`ScriptInterpreter` (`Sources/RunnerCore/ScriptClassification.swift:9`) has no
`racket` case, and `classifyScriptInterpreter`'s extension table has no `rkt`
arm. Racket's `generatedScriptExtension` is `"rkt"`, so this is the extension
every generated Racket test carries.

Trace it through a real golden
(`Tests/Fixtures/generated-source/racket/pattern/boundary_equality/publictest_fam_01.rkt`):

| step | result |
|---|---|
| extension table | `rkt` unmatched → fall through |
| `interpreterFromShebang` | first line is `; Test: b`, not `#!` → nil |
| `looksLikePythonContent` | `#lang` lines are filtered as comments; no `import`/`def`/`class` → false |
| classification | `.unknown` |
| `scriptInvocation` fallback | not executable → `shInvocation` |

Measured, running that exact golden:

```
$ /bin/sh publictest_fam_01.rkt
publictest_fam_01.rkt: 1: Syntax error: ";" unexpected
$ echo $?
2
```

Exit 2 maps to `error`. Every generated Racket test errors, in the only grading
path Racket has — it is `EditorSupport.uploadOnly`, so there is no browser
substrate to fall back to.

This is the shape CLAUDE.md already records for C++ and got right there: C++
generates `.sh` *because* there is no `ScriptInterpreter` case for it. Racket
generates its own extension and needs one.

### F2 — The Racket runtime helper never reaches the workspace

`Tools/runner-support/test_runtime.rkt` exists. Its Swift mirror does not:
`Sources/Worker/TestRuntimeSources.swift` declares `testRuntimePy`,
`testRuntimeR`, `testRuntimeLua`, `testRuntimeOctave`, `testRuntimeCpp` and no
`testRuntimeRacket`. `RunnerDaemon.swift` has five `write<X>RuntimeHelper`
functions, and `RunnerDaemon+JobProcessing.swift:465` calls them from a
hand-written list of five under the comment *"one per language,
unconditionally"*.

Every generated Racket test opens with `(require "test_runtime.rkt")`. Even
with F1 fixed, that require fails against a file that was never written.

### F3 — No runner ever advertises `racket`, so the jobs are never claimed

`RunnerProfileDetector.firstNumericVersion` accepts a whitespace-delimited token
whose *numeric prefix* contains a `.`, after trimming `,;:()`. Racket's banner
is `Welcome to Racket v8.10 [cs].` — the version token is `v8.10`, letter-led,
so the numeric prefix is empty. No other language prefixes its version with a
letter.

Verified against the real function, with each language's actual banner:

| language | banner | parsed |
|---|---|---|
| python3 | `Python 3.11.2` | `3.11.2` |
| R | `R version 4.3.1 (2023-06-16) …` | `4.3.1` |
| lua | `Lua 5.4.4  Copyright (C) …` | `5.4.4` |
| octave-cli | `GNU Octave, version 8.4.0` | `8.4.0` |
| g++ | `g++ (Debian 12.2.0-14) 12.2.0` | `12.2.0` |
| **racket** | `Welcome to Racket v8.10 [cs].` | **nil** |

`detectVersion` returns nil, the task returns nil, `racket` is absent from
`languageVersions`. `RunnerLanguageGate.evaluate` then refuses every runner for
every Racket assignment (`WorkerJobRoutes.swift:546`), so the jobs queue
forever — including instructor validation, which is enqueued as a
`kind == .validation` submission and always runs on the native worker.

The worst part is the symptom. This is the gate's own documented "worse
direction": no error, no failed test, no runner log. An instructor authors a
Racket assignment, clicks validate, and watches a submission sit pending with
nothing anywhere saying why.

**The guard for this exists and stops one step short.**
`everyLanguageProbeActuallyReportsAVersion` (conformance matrix) runs the real
probe and asserts it exits 0. `racket --version` exits 0. The runbook's
compiler-invisible item 6 says *"the probe's ARGUMENTS matter as much as its
command"* — learned from `lua --version` exiting 1. Racket is the third thing
in that chain: the command is right, the arguments are right, and the **output
format** is unparseable. The assertion needs to be that
`firstNumericVersion(probe output) != nil`, not that the probe exited 0.

`RunnerProfileDetector` has no test file at all — nothing under `Tests/`
references it, and `firstNumericVersion` has zero coverage.

### Why the compiler said nothing

The runbook's premise holds — `AssignmentLanguage` is a closed enum and adding
`case racket` produced a worklist. All three of these sites are outside it:

- `classifyScriptInterpreter` switches on a `String` extension.
- `scriptInvocation` switches on `ScriptInterpreter`, a *different* enum.
- The runtime-helper writers are five separate functions, not a switch.
- `firstNumericVersion` is a parser with no notion of language at all.

They are a fourth instance of the same shape the runbook already names — a list
hand-written at the edge of a system whose types are language-generic, failing
open. Item 6 covers half of this (capability matching) and should absorb the
rest: **a language's generated scripts must dispatch, and its runtime helper
must land.**

---

## F4 — The upload-only coherence rule generalised at two sites of five

"An upload-only language must be in `submissionMode: uploadOnly`" is enforced
in five places. #1294 turned two of them into the general
`if case .uploadOnly = language.editorSupport`; the other three still name C++:

| site | form | covers Racket? |
|---|---|---|
| `ManifestFieldEdits.setManifestLanguage:107` | `editorSupport` | yes |
| `SetAssignmentLanguageTool.swift:91` | `editorSupport` | yes |
| `ManifestFieldEdits.setManifestSubmissionMode:260` | `== AssignmentLanguage.cpp.rawValue` | **no** |
| `SetSubmissionModeTool.swift:90` | `== AssignmentLanguage.cpp.rawValue` | **no** |
| `TestSetupRoutes.swift:104` | `manifest.language == .cpp` | **no** |

So a Racket assignment can be flipped back to notebook mode from the MCP tool or
the web editor, and a zip-borne manifest declaring `language: racket` with
`submissionMode: notebook` is accepted — the case `TestSetupRoutes`' own comment
says it exists to stop ("so a zip-borne manifest can't smuggle it in").

The message is a second, smaller problem: `cppRequiresUploadOnlyMessage` is
hardcoded prose — *"A C++ assignment is upload-only: C++ has no editor
kernel…"* — and the two **generalised** sites serve it verbatim. A Racket
author who trips the rule is told about C++.

Both halves want the same fix: derive the predicate from `editorSupport` and the
message from `displayName`.

---

## F5 — Test coverage is asymmetric, and the asymmetry tracks recency

Racket's *renderer* coverage is the best of any language:
`PatternFamilyRendererRacketTests` executes real Racket across all eight pattern
kinds, both `#lang` dialects, and carries its own `racketIsPresentInCI`
did-not-skip proof. That is the right standard.

What is missing is everything downstream of rendering:

| coverage | py | r | lua | octave | cpp | racket |
|---|---|---|---|---|---|---|
| native grading end-to-end (`Tests/WorkerTests/*NativeGradingTests`) | ✓ | ✓ | ✓ | ✓ | ✓ | **—** |
| personalization driver executed | ✓ | ✓ | ✓ | ✓ | **—** | **—** |
| `test_runtime.*` drift vs `Tools/runner-support/` | ✓ | ✓ | ✓ | ✓ | ✓ | **—** |

`RacketPersonalizationDriver.swift` (167 lines) and
`CppPersonalizationDriver.swift` are referenced by no test.

`RuntimeSourceDriftTests` is the clearest instance of the recurring shape: one
hand-written `@Test` per language, five of them. `test_runtime.rkt` sits in
`Tools/runner-support/` with no mirror to drift from and no test to notice —
green, because nothing looked.

`ScriptInvocationTests` and `ScriptClassificationTests` are likewise
case-by-case, and `ScriptDispatchContractTests` is driven by a hand-listed JSON
fixture. **No test asserts that a language's `generatedScriptExtension`
dispatches to that language's interpreter** — one `allCases` test would have
caught F1 at the moment the descriptor literal landed.

### The three assertions that would have caught all of this

Each is a few lines, each is `allCases`-driven, and together they close F1–F3:

1. For every language, `classifyScriptInterpreter(name: "t.<generatedScriptExtension>", source: <a rendered golden>)` resolves to that language's interpreter — not `.unknown`.
2. For every language, a prepared workspace contains the runtime helper its generated tests reference.
3. For every language, `firstNumericVersion(<probe output>)` is non-nil.

### One smaller gap in the conformance matrix

`theInputsFileTheServerWritesIsTheOneTheLanguageReads` builds a `holes` fixture
carrying a null inside a collection, documents at length why that matters (R's
`NA`, Lua's `chickadee.NULL`), and then reads back only `threshold`. Because
every language loads the file whole, a *malformed* `holes` still fails the
test — but a `holes` that loads and holds the wrong value passes. Reading both
keys costs one line.

---

## F6 — Documentation stops at the fifth language

Racket appears **zero times** in `CLAUDE.md` and **zero times** in
`docs/adding-a-xeus-kernel.md`. There is no `docs/racket-support.md`.

That breaks a pattern the previous four additions kept without exception — R
(`docs/r-support.md`), Lua and Octave (the "What the *X* run actually cost"
postmortems in the runbook), C++ (`docs/cpp-support.md` plus the decision memo).
Those postmortems are what turned the runbook from a checklist into a scored
model, and Racket is the most informative data point yet available: the first
upload-only language that is *not* compiled, and the first whose contingent
"no kernel" answer could reverse.

Concretely stale:

- `CLAUDE.md`: *"Assignments are Python, R, Lua, Octave **or** C++"*, and
  `AssignmentLanguage (.python | .r | .lua | .octave | .cpp)`.
- `CLAUDE.md` describes C++ as the language with "NO editor kernel" in the
  singular; there are two.
- `CLAUDE.md` says the runbook names **seven** compiler-invisible items; the
  runbook says **eight**.
- The runbook's item 6 (capability matching) needs the version-*parse* clause
  from F3, and a clause for dispatch + runtime-helper landing.

`LanguageDescriptor.notebookKernelNames`' doc comment
(`Sources/Core/LanguageDescriptor.swift:213`) still reads *"Python is
deliberately EMPTY and that is not an oversight: it is the default, reached by
falling through"*. The Optional-resolution work (#1297) reversed this — Python's
descriptor now carries `pythonKernelNames`, and `resolve` matches it positively.
The comment states the opposite of what the field does, in the type whose entire
purpose is to be the trustworthy single source of language facts.

---

## What is genuinely good, and worth not regressing

The audit found no defect in any of these, and several of them are the reason
the defect list is as short as it is.

- **The closed enum + exhaustive-switch design pays.** Every language-dispatch
  site that *is* a `switch` on `AssignmentLanguage` has a correct Racket arm —
  `literal`, `renderInputsFile`, `driverPlan`, `supportFileEntries`,
  `validateKindSupport`, `assembleExtractedSource`, `submissionGuaranteeExemption`,
  `KernelEnvironment.environmentName`. Not one was missed. The rationale block
  at the head of `LanguageDescriptor.swift` for choosing this over a protocol is
  correct and has been vindicated twice now.
- **`ModuleResolution` and `EditorSupport` held.** Both reductions absorbed a
  sixth language with no change to their shape, and `EditorSupport.uploadOnly`
  is what let a kernel-less language be expressed at all.
- **The sites that were converted from enumeration to discovery stayed fixed.**
  `RunnerProfileDetector`'s probe loop, `KernelEnvironments`' keyed storage,
  `normalizeNotebookForJupyterLite`, `detectRequirementSuggestions`,
  `generate-js-constants.sh`, the UI language picker, `supportedLanguageNames` —
  all `allCases`-driven, all correct for Racket without an edit.
- **`RunnerLanguageGate` is the right mechanism** and its two fail-opens are
  well-argued. It is behaving exactly as designed in F3; the fault is upstream.
- **`SubmissionPolicy` as a policy value** rather than a protocol, with named
  exemptions, remains the right call — the reasoning in its header is worth
  keeping intact.
- **`PatternFamilyRendererRacketTests`** is the model for what a new language's
  test suite should look like: real interpreter, every kind, both dialects,
  did-not-skip proof.

---

## Efficiency

One observation, low priority and stated with its caveat.

`AssignmentLanguage.descriptor` is a **computed** property that constructs a
fresh `LanguageDescriptor` — six `Set<String>`s, several `String`s, an
`EditorSupport` payload — on every access. Every derived property routes through
it (`scriptExtensions`, `notebookKernelNames`, `inputsFileName`,
`generatedScriptExtension`, `displayName`, `editorSupport`, `interpreterProbe`,
`runnerProvidedModules`, `studentModulePrefixes`,
`supportFilesPathEnvironmentVariable`), and several callers iterate `allCases`
to reach it: `AssignmentLanguage(scriptExtension:)` builds up to six
descriptors per lookup, and `gradedScriptLanguage(in:)` does that per suite
entry.

At course scale this is not measurable and should not be treated as a
regression. It is worth a `static let` table keyed by language only if a
manifest-heavy path ever shows up in a profile — the change is mechanical and
the readability of the current form is worth something.

A smaller redundancy: `PersonalizationEvaluator.supportFileEntries` re-lists
each language's file extension in its own arm, duplicating `scriptExtensions`.
The arms differ in more than the extension (Python validates identifiers, C++
orders headers before sources), so this is not a pure duplication — but the
extension itself could come from the descriptor.

---

## Does it catch and prevent errors going forward?

Partly, and the boundary is sharp.

**Inside the enum, yes.** Adding `case racket` produced a worklist of compile
errors and every one of them was answered correctly. The conformance matrix then
adds a real definition of done on top: renderers, goldens, parse checks against
the real interpreter, disjointness invariants, both Docker images, the CI probe,
the did-not-skip proof. That machinery works, and the sixth language cost far
less than the second because of it.

**Outside the enum, not yet.** The compiler-invisible surface is not shrinking
on its own — the runbook went from seven items to eight during this arc, and F1
and F2 are a ninth and tenth that no list named. The pattern across all of them
is identical and mechanical:

> A list of languages written by hand, in a place whose types are
> language-generic, that fails open.

Every one that has been converted to `allCases` has stayed fixed. Every one that
has not has broken again. That is a strong enough signal to act on directly
rather than to keep discovering: the highest-value work is not another runbook
item but converting the four remaining hand-written lists —
`RuntimeSourceDriftTests`, the `write<X>RuntimeHelper` call site,
`ScriptInvocation`'s mapping, and `ScriptDispatchContractTests`' fixture — into
`allCases` walks, at which point the seventh language's equivalent of F1–F3
fails loudly at compile or on the first test run.

---

## Suggested order of work

1. F3 (version parse) — smallest fix, and until it lands nothing else about
   Racket is observable end to end.
2. F1 + F2 (dispatch + runtime helper) — the two that F3 was hiding.
3. The three `allCases` assertions in F5, which pin 1–2 from the outside.
4. F4 (upload-only rule at the three C++-named sites, plus the message).
5. F5's remaining coverage: `RacketNativeGradingTests`, personalization-driver
   tests for Racket and C++, the `test_runtime.rkt` drift mirror.
6. F6 documentation, including a Racket postmortem in the runbook and the
   `notebookKernelNames` comment correction.

Items 1–3 are what make Racket work at all. Items 4–6 are what make the seventh
language cost what the sixth should have.
