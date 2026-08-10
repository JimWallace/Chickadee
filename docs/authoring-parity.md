# Authoring parity across the six languages

What an instructor authoring in R, Lua, Octave, C++ or Racket can and cannot do
that a Python author can — which of those differences are defects, which are
correct refusals, and what it costs to close the ones worth closing.

Written 2026-08 after the language-support UI audit (#1319). That audit fixed
the *presentation* layer — copy that named Python or C++ where the system had
six languages and two upload-only ones. This document is about the capability
layer underneath it, and about four defects the audit missed.

**Read the "deliberately open" section before proposing work here.** Several of
these gaps are correct as they stand, and have been re-litigated more than once.

---

## The measured state

| capability | Python | R | Lua | Octave | C++ | Racket |
|---|---|---|---|---|---|---|
| Pattern-family kinds | 8/8 | 8/8 | 8/8 | 8/8 | 8/8 | 8/8 |
| Notebook checks | 10/10 | 9/10 | 4/10 | 5/10 | 0 (n/a) | 0 (n/a) |
| Custom-script templates | 9 | 0 | 0 | 0 | 0 | 0 |
| Auto-compute expected | in-page kernel | server | server | server | server | server |
| Solution function scan | yes | no | no | no | n/a | n/a |

**Both bottom rows have since moved.** The scan row was closed by the parity
work (R, Lua and Octave parsers behind `FunctionScanSyntax`), and the
auto-compute row reads *in-page kernel* for every language that has an editor
kernel — Python, R, Lua and Octave. The two on the server driver are C++ and
Racket, which have no kernel to run; `OctaveAutoComputeRuntimeTests` pins that
correspondence, so the split cannot quietly become a gap again. The table is
left as measured so the sections below, which argue from it, still read straight.

Two rows mislead as stated:

- **Templates.** Three *shell* templates are offered on every language, but
  their bodies name Python — `FILE="solution.py"` and
  `python3 -c "import solution; …"` (`TestScriptTemplates.swift`). A non-Python
  author gets three templates, all wrong for them, which is worse than zero.
- **Function scan.** The gap is three languages, not five. C++ and Racket are
  upload-only, so there is no solution notebook to scan;
  `notebookFunctionScanSupport` already separates the missing-parser reason from
  the structural one.

---

## Defects (things that are simply wrong)

### 1. Raw-script variable inlining — FIXED

Three code paths answered "which language is this script?" three ways, and the
banner written above the inlined block was a hardcoded `#` line in every
language. `#` is a comment in Python, R, Octave and shell; it is Lua's length
operator, a Racket reader prefix, and a C++ preprocessor directive. A Lua or
Racket assignment with global inputs plus a hand-written test produced a file
the interpreter refused to load — and because the banner is also the strip
sentinel, re-saving compounded it rather than repairing it.

Separately, `rawScriptOverlayWrites` (the `PUT /suite` path, which is the
*primary web authoring path*) chose the language with a hand-written switch on
`py`/`r` and `default: nil`, so four languages silently received no variables at
all while MCP `author_script` and the single-script save delivered them.

`LanguageDescriptor.lineCommentPrefix` is now the one place that answers the
comment question, `supportsRawScriptInlining` is the one place that answers
"can this language host an inlined block" (false only for C++, whose graded
scripts are `.sh` wrappers), and all three paths resolve through
`AssignmentLanguage(scriptExtension:)`.

A fourth defect surfaced while fixing it: Racket's `#lang` line must stay first,
and declarations must land *inside* the module it opens. A `(define …)` above
`#lang` is a read error no comment placement rescues, so `#lang` now keeps line 1
the way a shebang does.

`RawScriptVariableInliningTests` covers all six languages, and its execution
suite writes the emitted file and runs it in each interpreter present on the
host — which is the only kind of assertion that would have caught the original
bug.

### 2. "Create notebook" always writes a Python kernelspec

`defaultNotebookData(title:)` in `NotebookScaffoldHelpers.swift` hardcodes
`xpython` / `Python (xeus-python)` / `"language": "python"`, and is called from
four sites with no language argument. Select R in the language selector, click
"Create assignment notebook", and you get a Python notebook: the assignment
still resolves R (a recorded manifest language outranks the kernelspec), so
generated tests are `.R` while the editor boots `xpython` and the student writes
R into a Python kernel. On a draft with no recorded language yet, the Python
kernelspec becomes a *sticky* signal.

Every fact needed is already on `EditorSupport.notebookKernel`.

Related, same area: the Files table offers a "Solution Notebook" row and a
"create solution from assignment notebook" button on C++ and Racket assignments,
which have no notebook workflow. MCP's `update_solution` handles this correctly
with a `solutionFile` parameter; the web UI has no equivalent, so a web-only C++
author has no supported way to supply the reference solution that
`compute-expected` and every `= solution.foo(...)` expression depend on.

### 3. Markdown-section scaffolding is refused as collateral

`autoScaffoldFromSolutionNotebook` bails on `scan.functions.isEmpty` before
writing sections, and the scan returns nothing at all for a language it cannot
read. But section names come from `## ` markdown headers and have nothing to do
with the code language. So five languages get no auto-scaffolded suite sections
for a reason that only applies to function extraction.

`NotebookScanResult` conflates two answers; `unsupportedReason` should scope to
`functions`, not to `sectionNames`.

### 4. A residual of the upload-only copy defect, and the guard's blind spot

`UpdateSolutionTool` still says "For a language with no notebook workflow (C++),
pass solutionFile instead". Racket has been the second such language since it
shipped. `MCPLanguageCoverageTests`' subset guard misses it because the guard
triggers on the literal token `uploadOnly` and this sentence says "no notebook
workflow" — the guard needs its *trigger phrases* widened, not its match rule
loosened (loosening it would flag the legitimately-C++-only prose about `.sh`
generated extensions).

---

## Gaps that are correct as they stand

Do not open work items for these. Each has been checked against the substrate
rather than assumed.

**Lua's four data-frame kinds and `figureCount`.** Lua has no data-frame type,
and `emscripten-forge-4x` ships no Lua library packages at all — which is why
`KernelImportGuard` declines `.lua` outright. Not a packaging decision anyone
can reverse by paying a boot cost. Permanent.

**Octave's four data-frame kinds.** No `table` in core Octave; Octave Forge's
`dataframe` is not on the channel. The stronger reason, and the one to cite:
**check support is per-language, not per-grading-mode.** An Octave assignment
may be browser- or worker-graded, and the same saved check must mean the same
thing in both. A kind only the native substrate could run would let a
grading-mode toggle silently invalidate saved checks. Permanent unless both
substrates can serve it.

**`astStructure` outside Python.** Its predicate vocabulary (`for_loop`,
`list_comprehension`, `lambda`, `recursion`, `import:<module>`) is Python
semantics, not generic structure: `lambda` in R would match every function,
`list_comprehension` has no analogue, `import:` would have to silently mean
`library()`. The renderer also walks the preserved `_submission.ipynb` with
Python's `ast` at grade time. A check whose name means something different per
language is worse than no check. `cellContains` remains the escape hatch.
Permanent.

**`cellContains` with `regex: true` on Lua.** Lua patterns are not PCRE — no
alternation, no `{n,m}`, `%d` for `\d`. A pattern authored against the Python or
R renderer would not error; it would match the wrong thing and award marks on
that basis. Refused at save, and surfaced in the authoring form since #1319.
Permanent. Octave answers the opposite (its `regexp` is PCRE, verified against
`octave-cli`), which is what shows these are per-language judgements rather than
copied ones.

**All ten notebook checks and the function scan on C++ and Racket.** Both are
`EditorSupport.uploadOnly`: no submitted notebook for a check to inspect, no
solution notebook to scan. C++'s upload-only status is a *decision* (grading a
different compiler than the course teaches is a pedagogy defect); Racket's is
*contingent* (no Scheme-family kernel exists on the channel). Only Racket's is
reviewable, and only if a kernel appears.

**Moving Python auto-compute to the server.** The in-page evaluator is
xeus-python — the same kernel that grades browser-graded Python — so the split
gives Python *more* fidelity than uniformity would: the expected value is
computed on the exact interpreter and package set the generated test will be
asserted against. The old reason to move it (retiring `Public/pyodide`) no
longer applies; that worker already migrated. **CLAUDE.md's roadmap note listing
`pyodide-worker.js` as a Pyodide blocker is stale.**

**In-page kernels for R/Lua/Octave auto-compute — OVERRULED, and the reasoning
above is why it was worth writing down.** The argument here weighed only
fidelity, and on fidelity it is correct: those kernels ship bare, so there is no
package-version surface for a server driver to diverge on. It weighed the wrong
thing. The edit page exists to support in-browser authoring, and an author
changing a case should see what their solution returns without a server
round-trip — a kernel boot the author waits for once is a better trade than a
round-trip they pay for on every case. The boot is also lazy: it happens when
auto-compute is first used, not on every visit as this claimed.

R shipped first, then Lua, then Octave. Every kernel language now computes in
the page; only C++ and Racket route to the server, because neither has a kernel.

**Per-language custom-script template sets.** Seven of the nine Python templates
are already available in every language as pattern-family kinds, in a better
form: server-rendered, spec-hashed, re-renderable, and pinned by execution
tests. `structural_check` is Python-only by nature. Only `differential` has no
equivalent, and it is reachable with a family plus auto-compute. Writing 45
templates would be a second implementation of renderers that already exist, and
would turn a one-line vocabulary change into a 54-file edit.

| template | pattern-family equivalent | available in |
|---|---|---|
| `exists` | the automatic existence guard | all 6 |
| `correctness` | `boundaryEquality` | all 6 |
| `corner_cases` | `boundaryEquality`, several cases | all 6 |
| `exception` | `exceptionExpected` | all 6 |
| `type_check` | `returnTypeCheck` | all 6 |
| `performance` | `performanceThreshold` | all 6 |
| `variable_equality` | `variableEquality` | all 6 |
| `structural_check` | the `astStructure` notebook check | Python only, by nature |
| `differential` | none | — |

**CodeMirror modes for Lua, Octave and Racket.** Requires re-vendoring
`Public/vendor/codemirror.js`; the payoff is syntax colour.

---

## Work, in order

1. **Raw-script inlining.** *(done — see Defect 1.)*
2. **Language-aware notebook scaffolding.** `defaultNotebookData(title:language:)`
   from `EditorSupport.notebookKernel`; refuse for upload-only languages and
   replace the notebook rows in the Files table with a reference-solution *file*
   control backed by the same write `update_solution`'s `solutionFile` path uses.
3. **Split the scan's two answers** so section scaffolding runs for every
   language. Prerequisite for 5.
4. **Copy and guard.** `update_solution`'s sentence via `LanguageProse`; widen
   the coverage guard's trigger phrases; give `shellTestScript` the assignment's
   language so its three templates stop naming `solution.py`; correct the stale
   doc comment on `AuthoringLanguageFacts.expressionEvaluation`, which still
   describes a browser-only evaluator that hides the control on non-Python.
5. **R, Lua and Octave function parsers.** Factor `extractTopLevelFunctions`
   into a per-language `parseDefinition` selected behind the existing exhaustive
   `notebookFunctionScanSupport`, and move those three arms as each parser
   lands. Name and parameter names for all three; defaults for R; return-variable
   names for Octave; no type hints anywhere, which is the same state an
   un-annotated Python function already produces. Do **not** write a grammar
   table: Octave puts return variables before the name, Lua has three definition
   forms, and R's is an assignment whose RHS is a `function` literal. A table
   expressive enough for all of them is a parser generator; one that is not will
   silently miss definitions, which is the failure mode this whole apparatus
   exists to end.
6. **Close the template row in writing.** Put the cross-reference table above in
   the Add Test picker on non-Python assignments, derived from the kind list.
