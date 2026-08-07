# Should C++ become an `AssignmentLanguage`? A decision memo

*Written at the close of the Octave work (the fourth language), against the
question the task brief posed narrowly: does the course want generated test
families and personalization for C++, or does it want to grade C++
assignments? No C++ code was written for this memo, deliberately.*

## Recommendation

**No. C++ should not become an `AssignmentLanguage`.** Chickadee already
grades C++ today through the shell-script contract plus
`TestProperties.makefile`, with zero `AssignmentLanguage` involvement, and
that path is not a workaround — it is the designed seam for compiled
languages. Becoming an `AssignmentLanguage` would buy the authoring surface
(generated families, notebook checks, personalization, an in-browser kernel)
at the highest per-language cost yet examined, and two of the three purchases
are worth little for a C++ course: notebook checks presuppose a notebook
workflow C++ courses do not use, and the in-browser kernel grades a
*different compiler* than the course toolchain — a pedagogical defect no
engineering removes. The one genuinely missed capability, per-student
personalization, is reachable today through the existing seed contract
without any new language machinery.

If a C++ course materializes, the work worth doing is a documented `.sh` +
makefile template for C++ labs — an afternoon, not an arc.

## 1. The invocation mismatch, concretely

Every `ScriptInterpreter` case resolves to one shape
(`Sources/Worker/ScriptInvocation.swift`): `envInvocation(interpreter:script:)`
— `/usr/bin/env <command> <file>`. One file handed to one command, producing
an exit code. The four assignment languages, plus ruby/perl/node/php, all fit
because an interpreter *is* a function from a source file to a process.

C++ is compile → link → run: multiple inputs (the student's translation unit,
the test's, headers), an intermediate artifact, then an execution — three
stages with distinct failure modes the single-exit-code contract cannot
carry. `interpreterProbe` has the same assumption one level up: advertising
`g++ --version` says a compiler binary exists, not that the link environment
(libstdc++ headers, the sanitizer runtime a course might require) is whole.
Grafting a build graph onto `ScriptInterpreter` would also break the
per-script timeout semantics (compile time charged against run budgets) and
the `TestSetupCache` keying (an artifact cache would need to join it).

**Chickadee already answered this question, at the right level.**
`TestProperties.makefile` runs `make` once per collection before any script;
a build failure is `buildStatus: "failed"` with `outcomes: []` — the
collection-level state that exists precisely because compiled languages fail
before any test can be attributed. The suite scripts then run the produced
binaries and map exit codes exactly as every other suite does. That is the
correct seam, and "Do not add per-language build strategies in Swift" is
already a standing rule (CLAUDE.md, What Not To Do). An
`AssignmentLanguage.cpp` would have to either duplicate the makefile's job
inside `ScriptInvocation` or generate tests that assume the makefile ran —
the first violates the rule, the second means the generated tests only work
inside a hand-authored build the generator cannot see.

## 2. The literal problem

`literal(_:)` renders a `JSONValue` — a dynamically typed value. All four
current languages accept any such value somewhere (Octave was the near miss:
its `[...]` silently coerces, so mixed arrays became cells — but cells
*exist*). C++ has no universal container to retreat to: every literal needs a
type, at the point of rendering, and the type participates in overload
resolution against the student's function signature — which pattern families
do not model. They model *values*.

Concretely, per kind:

- `boundaryEquality` / `unorderedEquality` / `variableEquality` /
  `stdoutEquality` args and expecteds: `[1, "two"]` has **no rendering** —
  refuse heterogeneous cases at save time. Homogeneous cases still need a
  type story: is `[1, 2, 3]` a `std::vector<int>`, a `std::array<int, 3>`,
  an initializer list bound to whatever the parameter declares? `auto`
  deduction answers scalars (and surprises even there: `1` is `int`, `1.5`
  `double`, `"x"` a `const char*` that compares by pointer unless routed
  through `std::string`), and answers containers not at all. JSON `null` has
  no C++ value; `std::optional` would impose a signature convention on
  students. The honest shape is a **declared type per family** — a new
  schema field, editor UI, validator, and MCP surface, i.e. the renderer
  grows a type system. Budget accordingly: the ~1,000-line renderer arc the
  other languages cost is the *floor*, before the type system.
- `returnTypeCheck`: RTTI names are mangled and implementation-defined;
  the kind would grade `typeid` strings no instructor wrote. Refuse.
- `performanceThreshold`: timing under Clang-REPL (unoptimized, JIT) versus
  `g++ -O2` diverges by integer factors; a threshold that passes one runner
  and fails the other is a wrong mark by construction. Refuse, or make it
  native-only — which breaks the "one implementation, two substrates"
  invariant the whole RunnerCore design exists to keep.
- `exceptionExpected` maps tolerably (C++ exceptions, `what()` substring) —
  one kind of eight surviving unrestricted is the measure of the fit.

## 3. The pedagogical risk, settled first as instructed

`xeus-cpp` is genuinely interactive (CppInterOp / Clang-REPL), and the
runbook's survey already flagged the consequence: an interpreter is not a
compiler. Incremental-TU semantics have no separate compilation, so
link-time failure modes — the ODR violations, missing definitions, and
undefined references that C++ courses *teach* — either cannot occur or
surface as different diagnostics from different tooling. Chickadee's
architecture makes this worse, not better: instructor validation runs on the
**native worker** (g++/the course toolchain) while browser grading runs
Clang-REPL, so the two-compilers split is not a corner case — it is the
designed flow. A submission that validates green for the instructor and
fails for a student (or the reverse) because the *compilers* disagree grades
something other than what the course teaches. For Python, R, Lua and Octave
the kernel and the native interpreter are the same implementation of the
same language; for C++ they are not, and no substrate work closes that.

## 4. What the course would actually gain, against what it has

| capability | today (`.sh` + makefile) | as `AssignmentLanguage` |
|---|---|---|
| grade C++ submissions | **yes, shipping** | yes |
| partial credit, tiers, dependsOn | yes (script contract) | yes |
| compile-failure reporting | yes (`buildStatus`) | same mechanism |
| pattern families | no | restricted kinds + a new type system |
| notebook checks | no | moot — no notebook workflow to check |
| per-student personalization | **yes, via the seed contract** | marginally more ergonomic |
| in-browser grading/editing | no | a different compiler than the course's |

The personalization row deserves the detail, because it is the one real gap
the brief's question names: `CHICKADEE_ASSIGNMENT_SEED` is exported into
every test subprocess today, so a makefile can generate a per-student header
(`seed.h`) and the suite script can pass the seed to the binary — per-student
*inputs* without `AssignmentLanguage`. What the shell path cannot do is
server-side `=` expressions (`PersonalizationEvaluator` would need a C++
driver — the compile-a-driver-per-preview cost makes this the worst language
for it) and instructor previews of resolved values. That is a genuine but
narrow loss, and it is the whole loss.

Against it, the costs: a vendored 24 MB kernel env plus its boot cost, a
compiler toolchain pinned on both images, the renderer-plus-type-system arc,
and the permanent two-compiler maintenance surface — for the highest-risk
literal semantics of any candidate surveyed.

## 5. The rule that forecloses the middle option

"Vendor xeus-cpp for in-browser *practice* but grade through the shell path"
is not available: a vendored kernel registers its kernelspec in the editor,
an authorable language must be a gradable one, and Chickadee has exactly one
rule here — *a language is supported or it is not present*
(docs/adding-a-xeus-kernel.md). Lua spent one release on the wrong side of
that rule and the measured consequences are why it is a rule.

## Disposition

Keep C++ on the shell-script + makefile path. When a C++ course is actually
scheduled, write `docs/cpp-lab-template.md` (a worked `.sh` + makefile lab
with seed-based personalization) — that is the deliverable the course needs,
and it costs a day. Revisit `AssignmentLanguage.cpp` only if a course asks
specifically for *generated test families* in C++, and price it then as: the
renderer arc + a declared-type schema + the two-compiler divergence accepted
in writing by the instructor who owns the marks.
