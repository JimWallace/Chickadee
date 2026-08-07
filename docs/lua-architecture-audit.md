# Lua support + language-dispatch refactor: architecture audit

*Audit of `main` at `0280225` (PR #1282), 2026-08-07. Method: every claim below
that could be executed was executed — probe scripts against a real `lua 5.4.6`,
a scratch Swift test against the built package, and deliberate breakage of each
new guard. Findings are ranked; **defect** means wrong marks, data loss, or
silent failure on concrete inputs, as distinct from maintainability risk and
taste.*

## Status: all findings resolved

Kept as the record of what was wrong and how it was found — the findings below
describe `0280225`, **not** current behaviour. Every one has since been fixed:

| Finding | Fixed in | What landed |
|---|---|---|
| F1 — `resolve`/`rederive` have no Lua arm | #1284 | one shared `gradedScriptLanguage(in:)` + `fromNotebookMetadata`; authored-items flip; `allCases` resolution rows |
| F2 — no Lua interpreter in CI | #1285 | `lua5.4` in the ci-image + apt fallback; two did-not-skip proofs that fail rather than skip under `CI` |
| F3 — `equal` ≠ `unordered_equal` | #1285 | `unordered_equal` reuses `equal` (greedy multiset); both embeds synced |
| F4 — stdout capture defeated | #1285 | `io` proxy doubles as `io.stdout`, `write` is self-aware and chainable |
| F5 — browser Lua personalization missing | #1286 | the runner honours the server's resolved language |
| F6 — normalizer / hint / content-type Lua arms | #1286 | `xlua` normalization, `.lua` student-module hint, `text/plain` |

F5 and F6 were **not** in the original findings: they came from the
enumerated-not-discovered sweep this audit recommended, and F5 turned out to be
a live wrong-marks defect of the same shape as F1, on the browser side. That is
the argument for running the sweep rather than trusting the census.

Two flagged sites were deliberately left alone, and both are documented at their
call site: `KernelImportGuard.language(forFile:)` declines `.lua` (the
`chickadee-lua` inventory is empty, so a guard would reject every `require`,
starting with `require("test_runtime")`), and `isolatedWorkerScripts` is
accurate today and covered by `IsolatedWorkerScriptDriftTests`.

---

## F1 — DEFECT (critical). The language dispatch never dispatches: `resolve` and `rederive` have no Lua arm, so every server-side decision for a real Lua assignment is made as Python

`AssignmentLanguage.resolve(manifest:notebookKernelName:notebookLanguageInfoName:)`
([Sources/Core/AssignmentLanguage.swift:106](../Sources/Core/AssignmentLanguage.swift))
is the root every server path resolves through (via `resolve(for:manifest:)`).
Its chain is: recorded `manifest.language` → any `.R` script → `rKernelNames` /
`language_info == "r"` → `.python`. **No step knows Lua.** `rederive`
(line 195) ends `isRNotebookMetadata(metadata) ? .r : .python` — the *literal
example string* the runbook's item 5 gives for the "boolean sniff that
type-checks forever and routes the new language to Python", and the runbook's
own detection grep (`grep -rn "? \.r : \.python\|isRNotebook" Sources/`) finds
it today.

Executed confirmation (scratch Swift test against the built package — all four
fail):

```
resolve(manifest with publictest_x.lua)          → .python   (expected .lua)
resolve(…, notebookKernelName: "xlua")           → .python
resolve(…, notebookLanguageInfoName: "lua")      → .python
rederive(…, notebookData: xlua-kernel notebook)  → .python
```

And nothing ever records `language: lua` into a manifest: the two creation
sites (`DraftAssignmentRoutes+NewAssignment.swift:290,688`) pass no language;
manifest rebuilds only *preserve* `props.language`; the only writer is
`manifestWithRederivedLanguage`, whose `rederive` cannot produce `.lua`; the
MCP `create_assignment` tool has no language parameter; there is no UI picker.
So for every real Lua assignment `manifest.language` is nil and lazy resolution
answers `.python` forever.

**Concrete failures** (all downstream of the 18 `resolve(for:)` call sites):

- `PUT /families` / `PUT /suite` render pattern families and notebook checks
  for a Lua assignment **as Python scripts** (`PatternFamilyApplication.swift:318`),
  which import `student_module` and can never pass against a Lua submission —
  every student fails every generated test. The 1,070-line Lua renderer, the
  Lua notebook-check renderer, and the Lua existence guard are **reachable only
  from tests**.
- The six "refused at save time" notebook-check kinds are *not* refused for a
  real Lua assignment (validation runs with `language == .python`), so
  `astStructure` and the data-frame kinds save fine and generate Python checks.
  The refusal machinery — messages, `cellContains` `regex: true` rejection —
  is dead code in production.
- `WorkerJobRoutes.swift:316` stamps `job.language = .python`, so the worker
  writes `_ck_inputs.py` while `chickadee.inputs()` reads `_ck_inputs.lua`:
  on a personalized Lua assignment every per-student value is missing and the
  generated preamble fails every test with "Personalization input …
  unavailable". The browser seeds route (`BrowserRunnerRoutes.swift:184`)
  resolves the same way, so browser grading personalization breaks identically.
- `PersonalizationEvaluator` runs `=`-expressions through `python3` for a Lua
  assignment — the exact bug (`SyntaxError` on first foreign expression) whose
  R incarnation motivated `resolve(for:)` in the first place.
- Converting an assignment by replacing its starter notebook with a Lua one
  re-derives `.python` — the "one-way door" `rederive` was built to open for R
  stays shut for Lua.

What still works, and why the PR's own verification passed: per-*script*
paths are extension- or metadata-keyed and were genuinely fixed — worker
routing (`manifestOwningLanguage` iterates `allCases`), notebook extraction
(`fromNotebookMetadata`), script classification, requirement suggestions,
variable prepending, runtime injection (unconditional). A hand-authored `.lua`
suite with no families, no checks, and no personalization grades correctly.
Every executed check in #1282 (`LuaNativeGradingTests`,
`LuaPersonalizationDriverTests`, the conformance matrix) invokes the machinery
with `.lua` **explicitly**, so none of them ever asks the question production
asks — *which* language is this assignment? — and there is no resolution test
mentioning Lua anywhere (`AssignmentLanguageTests`,
`AssignmentLanguageResolutionTests`: zero matches).

The same omission has a second instance inside the PR:
`PatternFamilyApplication.swift:322-324` flips the language from
*authored items* by checking `pathExtension == "r"` only — adding the first
`.lua` script to a suite still saves as Python even at the moment the `.lua`
extension is in hand.

**Fix shape:** resolve script extensions via
`AssignmentLanguage(scriptExtension:)` over the suite (first non-default match,
with the R-before-Lua precedence made explicit), sniff kernels via
`fromNotebookMetadata`, do the same in `rederive`, fix the authored-items flip,
and add resolution rows per language to the conformance matrix (which is
exactly the kind of `allCases`-driven test this repo already knows how to
write). Recording the language at creation would also do, but lazy resolution
is load-bearing for pre-language manifests either way.

*Note for prod:* this shipped in v0.5.23 and auto-deployed; the changelog
announces Lua as a supported assignment language. Until F1 is fixed, that is
true only of the hand-authored-suite subset.

---

## F2 — DEFECT (high). No Lua-executing test has ever run in CI: the CI image has no Lua interpreter, and every Lua execution test skips silently

`.github/docker/ci-image/Dockerfile` installs `python3`, `r-base`,
`python3-pandas`, `python3-matplotlib` — **no `lua5.4`** (file untouched since
#1264, before this PR). Both the `APITests` job (`swift-ci:6.3-noble`, i.e. the
ci-image) and the `WorkerTests` job install only `file python3` as system test
deps. All Lua execution tests guard `guard Self.luaAvailable else { return }`
— where `luaAvailable` probes `/usr/bin/env lua -v` — and so skip silently:
`LuaNativeGradingTests` (4 tests — the regression guard for the very exit-127
validation defect #1280 fixed), `LuaPersonalizationDriverTests` (4 tests,
including "the done-test item that has no other guard": the two-copy Horner
seed equality), and the conformance matrix's executed Lua rows (parse checks,
inputs round-trip, real probe).

The "3143 green" therefore includes roughly ten tests whose Lua half has never
executed where it gates a merge. This is the precise failure mode the PR's own
commit message narrates as its lesson ("the suite reported green having never
parsed a line of generated Lua"), fixed for the *probe arguments* and
reintroduced one level up by the image. `theRunnerImageProvidesEveryInterpreter`
does not help: it greps the **runner** `Dockerfile` (which does have `lua5.4`),
not the CI test image the suites actually run on. The browser half is
genuinely covered (`browser-grading-smoke.yml` runs `{language: lua}` on a real
xeus-lua); the native half is not.

**Fix shape:** add `lua5.4` to the ci-image, and add the did-not-skip proof the
runbook's done test calls for — e.g. a matrix test that *fails* (not skips)
when an interpreter is absent and `CI` is set.

---

## F3 — DEFECT (moderate-high). `equal` and `unordered_equal` still disagree — including the exact 1-vs-1.0 case the fix targeted, one level down

The `%.17g` type-tagged key applies only to **top-level** elements. Anything
nested keys through `M.format`, which `tostring`s scalars (no quoting, no
int/float collapse), elides depth ≥ 2 as `{...}`, and truncates at 300 chars.
Executed against the real runtime (`equal` / `unordered_equal`):

| inputs | equal | unordered | consequence |
|---|---|---|---|
| `{{1,2},{3,4}}` vs `{{1.0,2.0},{3.0,4.0}}` | true | **false** | correct answer fails — the commit's own bug, at depth 1 |
| `{-0.0, 5}` vs `{0.0, 5}` | true | **false** | correct answer fails |
| `{{"a, b"}}` vs `{{"a","b"}}` | false | **true** | wrong answer passes (`", "` join ambiguity) |
| `{{{1,2}}}` vs `{{{9,9}}}` | false | **true** | wrong answer passes (depth elision) |
| 301-char strings differing at the tail | false | **true** | wrong answer passes (truncation) |
| `{2^53+1}` vs `{2^53}` | false | **true** | wrong answer passes (`%.17g` is a double) |
| `{chickadee.NULL}` vs `{{}}` | false | **true** | wrong answer passes (NULL formats as `{}`) |
| `{{1}}` vs `{{"1"}}` | false | **true** | wrong answer passes (tag only at top level) |

A list of pairs — `[[1,2],[3,4]]` — is ordinary course data, and integer/float
drift within it is exactly what arithmetic produces; the first row is the
same student-visible contradiction the commit message says it fixed
("passing boundaryEquality and failing unorderedEquality"). The pass-wrong
rows award marks for wrong answers, which is worse. (R's
`chickadee_unordered_equal` has different lossy semantics again — `unlist`
flattens all structure and drops the type tag, so `{1}` vs `{"1"}` *passes* in
R and fails in Lua — but that divergence predates this PR.)

**Fix shape:** a recursive canonical key (type-tagged at every level, `%q` for
strings, no truncation, `%.17g`+`math.type` for numbers), or pairwise
`M.equal` multiset matching (O(n²), fine at course sizes). Either changes only
`test_runtime.lua` + its embedded copies, not generated bytes.

---

## F4 — DEFECT (moderate). `stdoutEquality`'s capture is defeated by idiomatic student Lua; the audit's restore-on-raise worry is, however, unfounded

The generated test swaps `print`/`io` in the student's environment table
around the call. Executed against the shipped golden with real submissions:

- `local print = print` at file top (the mainstream "localize your globals"
  idiom) — output goes to real stdout, capture stays empty, and a **correct
  submission fails** with the gaslighting message `expected: "hello"
  got: ""` while "hello" is visibly printed above it. Exit 1, confirmed.
- `io.stdout:write("hello\n")` — same escape (the proxy's `__index = io`
  hands back the real file), same fail-correct. Confirmed.
- `io.write("hel"):write("lo")` — legal Lua (real `io.write` returns the
  file for chaining); the collector returns nothing, so the student crashes
  with `attempt to index a nil value` and fails as "unexpected exception".
  Confirmed.

By contrast Python captures at the stream (`contextlib.redirect_stdout`
catches `print` *and* `sys.stdout.write`) and R at the sink
(`capture.output`); Lua's shadowing is the weakest of the three, and the ways
out of it are things ordinary students type, not adversaries.

**What holds:** restoration is correct on every path — `pcall` cannot throw
past it and both resets run before any branch, so a raising call cannot leak
the collector into the harness (whose own `print`/`io.write` are never
touched). The residual restore quibble is that `student.print = nil` *discards*
rather than restores a student-defined global of the same name, but the env is
per-test and rebuilt by the next `load_student()`.

**On cheating:** yes — a student can walk `debug.getlocal` up to the test
chunk and print `expected_output` (executed: passes), and a top-level
`os.exit(0)` passes every generated test (executed: exit 0, synthesized
"passed"). Both are properties of in-process grading shared with Python
(`inspect.stack`, top-level `sys.exit(0)`) and R (`sys.frames`, `quit()`
before masking), not regressions of this PR; the sandbox boundary is the
process, not the frame. Worth a line in the threat-model docs, not a fix here.

**Fix shape for the honest-student cases:** give the `io` proxy a `write` that
returns a chainable object, add a masked `stdout` field to the proxy, and
document (in the assignment prose) that `stdoutEquality` grades `print`. None
moves generated bytes for a submission that only uses `print`.

---

## F5 — MAINTAINABILITY. The runbook's "compiler cannot see" list is both self-contradictory and incomplete — and its omissions are exactly F1

`docs/adding-a-xeus-kernel.md` says "**The compiler cannot see five more**"
(line 363) and, 80 lines later, "**Seven** things" (line 446) heading a list of
seven. The count is wrong in one of the two places; the list is seven.

More materially, the list is **incomplete against its own detection command.**
Item 5 tells the reader to run
`grep -rn "? \.r : \.python\|== \.python ?\|isRNotebook" Sources/` and fix what
it finds — but that grep matches `AssignmentLanguage.swift:209`
(`rederive` … `? .r : .python`) *today*, and `resolve` a few lines up is the
same shape spelled with `hasRScript`/`rKernelNames`. The document asserts these
sites were swept (it lists `NotebookExtractor`'s identical ternary as fixed)
while two instances of the pattern remain in the hub file the document opens by
describing. The 26-site compiler census (11 + 3 + 12) is internally consistent
and I did not independently recompile it; the invisible-site list is where the
gap is, and F1 is what fell through it.

Secondary: the `resolve`/`rederive` doc-comments still describe a two-language
world ("→ `.r`; else `.python`"), and the `job.language` comment at
`WorkerJobRoutes.swift:313` still reads "`_ck_inputs.py` vs `_ck_inputs.R`" with
no Lua — so a maintainer reading the code is told Lua is not a case here.

---

## The four argued decisions — verdicts

Attacked as asked; three hold, one is undermined by F1 rather than by its own
reasoning.

- **Enum + descriptor, not a protocol — SOUND, and the design's best call.**
  The whole value proposition ("a missing answer is a *compile error*") is real
  and I verified it bites: cutting a field out of one descriptor literal is
  caught by `theIdentifyingFieldsAreUniqueAcrossLanguages`; the `String` raw
  type genuinely forecloses associated values. The protocol does not win here.
  The catch is that the compile-error guarantee only covers what is actually a
  `switch` over the enum — and F1 is the proof that the enum's *own resolution
  functions* opt out of it by string-matching instead of switching. The
  descriptor is right; it just is not load-bearing for the one decision that
  matters most.

- **The fact/judgement split (`ModuleResolution`) — SOUND, not clever-for-its-
  own-sake.** The three derived properties (`runnerProvidedModules`,
  `studentModulePrefixes`, `supportFilesPathEnvironmentVariable`) really are
  three projections of one question, and R-vs-Lua landing on opposite answers
  for the *same* runtime-helper shape is the genuine evidence that it must be
  answered per language, not copied. `interpreterHookModules` riding on `.byName`
  is honest, not a smuggled fourth thing: it is consumed only by
  `runnerProvidedModules` via `union`, it is empty for every language but
  Python, and modelling `sitecustomize` as "a module the interpreter resolves
  on its own" is accurate. The Octave scorecard entry (mechanism ≠
  `workingDirectoryIsOnDefaultSearchPath`) is a real second axis and justifies
  the one-fact-beside-one-judgement shape. Taste-level only: "scored against
  three languages it doesn't have" is asserted in prose and can't be executed,
  so it documents intent rather than proving it.

- **`SubmissionPolicy` as a value with named exemptions, not a protocol —
  SOUND, and the inconsistency with decision #1 is justified.** The two are not
  actually inconsistent: #1 rejects a protocol because it wants a *compile
  error* per case, and `SubmissionGuarantee`/`submissionGuaranteeExemption` gets
  that same fail-closed property from `CaseIterable` × `allCases` plus the
  exhaustive switch — while additionally making an exemption a *greppable value
  with a reason* rather than an empty method body. Different tool, same
  fail-closed goal, and the "invisible opt-out" argument against a protocol is
  the correct one for a policy meant to be read as policy. Verified the reason
  string is enforced: blanking it reds `everyGuaranteeIsAnsweredForEveryLanguage`.

- **Three renderers, not one — SOUND; the goldens back the stated reason.**
  Verified from the fixtures: the `.stdoutEquality` Python golden says "wrong
  stdout" with an `expected stdout:` label and a `source:` traceback line and
  `Printed {actual!r}`, while R and Lua say "wrong output" / "Printed the
  expected output"; `exceptionExpected` uses three different first-line
  sentences. Prose genuinely diverges, and Python's bytes are `spec_hash`-frozen,
  so folding the three into one implementation would rewrite every existing
  Python assignment's manifest — a product change, not a refactor. The shared
  part that *can* be hoisted (the field labels) already was, into
  `GeneratedMessage`. Not the biggest thing in the diff to unify; correctly left
  as three.

---

## The least-confident items, resolved

- **`submissionNormalization` behaviour-preservation (esp. mixed Python+R) —
  PRESERVED.** `manifestOwningLanguage` returns nil whenever any `.py` suite
  script or required `.py` exists (`guard !suiteContains(.python),
  !hasRequiredPython`), so a mixed Python+R suite still takes `.pythonModule` —
  identical to the old `manifestTargetsRSubmission` precedence, which also bailed
  on any Python. The `resolve`-vs-routing disagreement the brief flags is real
  and intended: `resolve` calls a mixed suite `.r` (first `.R` script wins) for
  *rendering*, while routing keeps it on the Python normalizer for
  *submission prep* — two different questions, unchanged by this PR. The
  `shouldNormalizePythonSubmission` boolean is retained as a thin wrapper, so
  existing callers see identical results. No finding.

- **`studentModulePrefixes` widening — can only widen, SAFE as claimed.** The
  only consumer is `KernelEnvironment.provides` (`KernelEnvironment.swift:60`),
  which ORs the prefix check into an acceptance predicate; adding `solution`/
  `submission` can only make `provides` return true for more names, and the sole
  consumer of *that*, `KernelImportGuard`, turns a true into "don't report".
  Widening the guard's acceptance can only *suppress* a rejection, never create
  one, and the guard is documented to resolve ambiguity toward silence. Verified
  the intent test `everyNameAddressableLanguageAcceptsTheNamesTheRunnerCanWrite`
  pins it. No finding.

- **The six unsupported notebook-check kinds — right exclusion, but see F1.**
  data-frame×4 (Lua has no data frame and the env ships no packages),
  `figureCount` (no plotting lib), `astStructure` (Python AST only) are all
  genuine impossibilities, not convenience. Refusing `cellContains` `regex: true`
  is the right call over approximating: Lua patterns are not PCRE (no
  alternation, no `{n,m}`, `%d` for `\d`), so a Python-authored pattern would
  silently mis-match rather than error, awarding marks on a false basis — exactly
  the outcome refusal prevents. The catch is F1: because a real Lua assignment
  validates as Python, *none of these refusals fire in production* — they are
  correct rules on an unreachable path.

---

## Guards: do they bite? (all verified by deliberate breakage, then reverted)

Every new guard the brief flagged was broken on purpose and observed to fail
with a specific message, then reverted:

- Hand-retype a field label in a renderer → `noRendererHandTypesAFieldLabel`
  fails, naming file:line and the label.
- Copy a neighbour's `inputsFileName` into a descriptor literal →
  `theIdentifyingFieldsAreUniqueAcrossLanguages` fails.
- Blank an exemption reason → `everyGuaranteeIsAnsweredForEveryLanguage` fails.
- Append an executable line to `test_runtime.lua` without syncing the embed →
  `RuntimeSourceDriftTests.testRuntimeLuaMatchesCanonical` fails (and a
  comment-only line correctly does **not**, confirming the `--`-aware
  normaliser).
- Drop `xr` from the generated `R_KERNEL_NAMES` block → `generate-js-constants
  --check` fails; add a `zigKernelNames` static with no fenced block → it fails
  demanding the block. The generator genuinely *discovers* rather than
  hardcodes.

These are real matrices, not hardcoded pairs. The one gap is not in a guard but
in coverage: no guard asserts *resolution* answers `.lua` for a Lua assignment
(F1), which is why F1 shipped green.

---

## What's solid (so the disagreements above stay in proportion)

The message-vocabulary hoist is a real correctness win: computing the alignment
column from the widest label means a new field cannot mis-pad, and the goldens
pin the historical bytes. The `LanguageDescriptor` collapse, `ModuleResolution`,
and `SubmissionPolicy` are all well-argued and their guards bite. The
per-*script* half of Lua — classification, worker routing via
`manifestOwningLanguage`/`allCases`, notebook extraction via
`fromNotebookMetadata`, capability probing with per-language version arguments,
runtime injection, the web-upload allowlist — was generalised properly and is
the part that genuinely works end to end. The Lua renderers themselves are
correct where I executed them (all eight pattern kinds and four check kinds
pass a correct submission and fail a wrong one with readable messages); F1 is
that they are wired to a resolver that never selects them, and F3/F4 are two
comparison/capture edges inside them.

Net: the refactor's *types* are good. The defects are that the enum's own
resolution functions never joined the type-safe world the rest of the PR built
(F1), that world was never exercised in CI (F2), and two runtime helpers have
concrete wrong-mark edges (F3, F4).
