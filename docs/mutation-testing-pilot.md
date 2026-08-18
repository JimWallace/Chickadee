# Mutation testing — the RunnerCore pilot (2026-08-18)

**Status: it works, it found real holes, and it is affordable at the right
scope.** A patched Muter was pointed at four files of `RunnerCore` and scored
**69%** — 88 mutants killed, 39 survived, **zero build errors**, 46 minutes.
This is the first mutation score ever produced against Chickadee source that is
a measurement rather than an artifact.

Read [handoff-mutation-testing.md](handoff-mutation-testing.md) first for why
stock Muter cannot do this, and
[mutation-testing-spike.md](mutation-testing-spike.md) for the root cause.
For reading a *series* of runs rather than this one — what the score means, and
the two things that make it move for reasons unrelated to the suite — see
[mutation-trend.md](mutation-trend.md). Tracking issue **#1447**.

---

## Why a patched Muter, and why that is not a stopgap

Two independent upstream bugs sit on opposite sides of one commit, and **both
produce the identical symptom** — 0%, every mutant surviving:

| Muter | inserts mutants | reads Swift Testing failures |
|---|---|---|
| tag `16` (2023-09-16, the only release) | yes | **no** |
| `99624ec` … `7f1f258` (current `main`) | **no** | yes |
| `7f1f258` + the three-line cache restore | yes | yes |

The insertion bug is [muter#307](https://github.com/muter-mutation-testing/muter/issues/307)
(PR #302 severing AST↔schemata node identity). The Swift Testing bug is one
word — `7f1f258` added `issue` to the regex alternation, because Swift Testing
prints `with 1 issue` where XCTest prints `with 1 failure`.

Chickadee has **zero** `import XCTest` across 428 test files, so every released
Muter is blind to every failure we produce. **There has never been a Muter
build, released or tagged, that works on a suite like ours.** A fork here is
load-bearing infrastructure, not a patch we carry until upstream lands — there
is no released version to fall back to.

## What was run

```
muter run --skip-coverage --skip-update-check -f plain \
  --files-to-mutate Sources/RunnerCore/OutputInterpretation.swift \
  --files-to-mutate Sources/RunnerCore/ScriptClassification.swift \
  --files-to-mutate Sources/RunnerCore/SuiteExecution.swift \
  --files-to-mutate Sources/RunnerCore/JSONLite.swift
```

with a test command of `swift test --skip APITests`.

Three scoping decisions, each of which turned out to matter:

- **`RunnerCore`, not the server.** Vapor-free, pure logic, compiled both
  natively and to wasm, and pinned by `Tests/Fixtures/output-contract.json`. It
  is the code where a surviving mutant is genuinely alarming.
- **Files whose covering tests are subprocess-free.** This container has no
  `Rscript`, `lua`, `octave-cli` or `racket`, so those `WorkerTests` skip
  silently. A mutant covered only by a skipped test survives, and reads as a
  hole that is not there. `NotebookExtraction.swift` was left out for size, not
  for doubt.
- **`--skip APITests`.** It costs 6m33s in CI and barely touches `RunnerCore`.
  Note it still *compiles*: SwiftPM builds every test target regardless, so
  skipping buys test time, never build time.

## What it cost, measured

| | |
|---|---|
| Build Muter from source (cold, 4 CPUs) | **9m17s** — cacheable by SHA |
| Muter run, 127 mutants | **46m04s** wall clock |
| Whole pilot, launch to report | 46m55s |
| Per mutant, test phase | **~16s** |
| Mutants found | **127 from 763 LOC — one per 6 lines** |
| Project copy | **678 MB** — no exclusions, so 392 MB of vendored kernels and 256 MB of `.git` are copied every run |
| Peak disk | **3.4 GB** (the copy plus its own build tree) |

The mutant-per-LOC ratio is the number that decides the shape of any recurring
job. `Sources/` is roughly fifty times the volume of this slice, so a whole-tree
campaign is on the order of **10,000 mutants**, each costing a test run. That is
not a scheduling problem to be tuned; it is arithmetic that rules the approach
out. Scoped is the only viable shape, exactly as the handoff predicted — now
with a measured multiplier behind it.

## Did #308 show up? No.

[muter#308](https://github.com/muter-mutation-testing/muter/issues/308) reports
schemata generation emitting unparseable branches, lost do/catch bodies and
phantom mutants. It was the main reason to distrust a patched fork. On this
slice it did not appear:

- **Zero build errors.** Every one of the 127 mutants compiled.
- **88 + 39 = 127.** Every mutant is accounted for in the report, so nothing was
  silently dropped from the denominator — the failure mode that would inflate a
  score.

That is evidence, not a clearance. 763 LOC of pure value-type Swift is a
friendlier target than the Vapor layer, and none of these files contain the
do/catch shape #308 names. It does mean the risk is smaller than it read on
paper, and that a scoped run against similar code can be trusted today.

## What it found

39 survivors. They are not uniform — separating them is the whole skill of
reading a mutation report, and the split here is roughly two-thirds signal.

### Real holes, worth tests

**The suite runner's event stream is untested** (`SuiteExecution.swift:82,86,90`).
All three `RemoveSideEffects` survivors are `onEvent(...)` calls — `.missingScript`,
`.willRun`, `.didFinish`. Deleting them fails nothing. The sharpest of the three
is `.missingScript`: the code comments it as *"skip with no outcome (caller logs
via the event)"*, so if that emission ever regressed, a missing test script would
produce **no outcome and no log** — invisible in both directions.

**Content-based Python classification** (`ScriptClassification.swift:97,105`).
Line 97's `!$0.isEmpty && !$0.hasPrefix("#")` survives becoming `||`, which
would keep blank and comment lines inside the five-line window the sniffer
looks at — so a Python file behind a license header would classify differently.
Line 105 survives the `||` chain becoming `&&`, which would break content
detection almost entirely. Nothing in the suite exercises this path.

**Leading BOM and whitespace trimming** (`ScriptClassification.swift:138,145`).
Both predicates survive `||` → `&&`, which makes them never true and disables
trimming outright. No test feeds a source with a leading BOM — precisely the
shape a Windows-authored submission arrives in.

**The hand-rolled substring search** (`ScriptClassification.swift:174,175`).
Three survivors in a hand-written `contains` loop that exists to stay
Embedded-Swift-safe. Some of these mutants would index out of bounds if
executed, so their survival means the loop's boundaries are never reached in
tests. A hand-rolled algorithm with untested boundaries is the highest-value
finding per line here.

**Numeric exponent parsing** (`JSONLite.swift:210,213,217`). The exponent sign
branches survive, meaning **no test parses a footer with an exponent**. A script
emitting `{"score": 5e-1}` is legal JSON under the documented contract, and
nothing pins it.

**Whitespace-tolerant JSON** (`JSONLite.swift:35,57,59,64`). Several
`skipWhitespace()` calls can be deleted without failing anything, because every
fixture footer is tightly formatted. Instructors hand-write these footers, so
`{ "score": 1 }` is an entirely plausible input. One generously-spaced fixture
would kill several of these at once.

**`longResult` assembly** (`OutputInterpretation.swift:106`). The
`sections.isEmpty ? nil : sections.joined(...)` ternary survives being swapped,
so nothing asserts that stdout/stderr actually reach `longResult` — the field
students read for detail when a test fails.

### Not worth chasing

Some `JSONLite` survivors are unkillable by construction. Line 35's
`skipWhitespace` treats `\n` and `\r` as skippable, but the footer is *by
definition* the last non-empty **line** of stdout, so no input reaching this
parser can contain one. Those mutants cannot be killed by any test worth
writing, and a report that counts them as holes is over-reporting.

This is the irreducible cost of the technique: **a mutation score is not a
target, and chasing 100% would mean writing tests for inputs that cannot
occur.** It is a list of questions, and some of the answers are "correctly, no".

## Operational notes for anyone running it

- **The container must be able to run the whole suite.** Missing interpreters
  do not fail — they skip, and every mutant they covered then survives. A run on
  an under-provisioned image reports holes that do not exist.
- **Muter dirties the working tree**: it writes `muter.conf.yml` (pinning an
  absolute `swift` path, so never portable) and a `muter_logs/` directory —
  27 MB after this run — into the project root, plus a sibling `_mutated` copy.
  Both are in `.gitignore` now; without that they are one `git add -A` away from
  being committed.
- **`.build` must not exist** before a run, or the wholesale copy poisons it
  with SwiftPM's absolute-path module cache. Cost is a cold build every time.
- The originals are left intact — verified `git status` clean and
  `Sources/RunnerCore/` unmodified after the run.

## Is it worth a monthly run?

**The findings say yes; the shape needs to be right.** One 46-minute run
surfaced seven distinct, specific, cheap-to-fix gaps in code that already has a
contract fixture and a test suite. None of them would have been found by the
guards, because guards check structure and these are behaviours.

If it becomes a recurring job, the constraints are now measured rather than
guessed:

- **Scoped, always.** One-per-6-LOC means a whole-tree run is ~10,000 mutants.
  Rotate a small target per run — `RunnerCore`, then `Core`, then the week's
  changed files — rather than attempting coverage.
- **Monthly beats weekly.** The findings are structural gaps in stable code, not
  regressions; they do not accumulate at a weekly rate. This slice would not be
  worth re-running until its survivors are addressed.
- **A report a human reads, never a gate.** Two-thirds signal is a good ratio
  and a terrible pass/fail threshold, and the equivalent mutants above are
  permanent — a score target would mean chasing them.
- **Run it where the full suite runs.** Otherwise the missing-interpreter
  artifact turns into fictional findings.
- **Re-verify the fork every rebase.** Both upstream failure modes are silent
  and look identical to a clean 0%. `.github/workflows/mutation-probe.yml`
  exists for exactly this and takes ten minutes.

The honest counter-argument: this is a **fork of an unmaintained-for-this-purpose
tool**, carrying a patch upstream has not merged since July, against a codebase
whose test suite is already unusually well guarded. The findings above are real
but none is a live defect — they are absent tests, not broken behaviour. Whether
that is worth a standing monthly commitment is a judgement about appetite, not
about whether the tool works. It works.
