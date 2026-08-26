# Mutation testing — the RunnerCore pilot (2026-08-18)

**Status: it works, it found real holes, and it is affordable at the right
scope.** A patched Muter was pointed at four files of `RunnerCore` and scored
**69%** — 88 mutants killed, 39 survived, **zero build errors**, 46 minutes.
This is the first mutation score ever produced against Chickadee source that is
a measurement rather than an artifact.

**Read "What it found" with the correction in it, and do not quote the 69%.**
The survivors were verified one at a time by hand afterwards, and roughly half of
the ones written up here as holes were already covered — Muter reports mutants it
never inserted, and those always read as survived. Six were real and now have
tests; following one of them turned up an unrelated product defect (#1457).

The pilot predates `Tools/mutation/report.py`, so **every number on this page is
un-filtered**. The first full sweep of the same target, with filtering, scored
**84%** — 122 killed, 23 survivors, 64 phantoms removed. That is the figure to
compare against.

**The question this page ends on — "is it worth a monthly run?" — was answered
with a weekly one.** `mutation-weekly.yml` sweeps the whole logic tier
(RunnerCore + Core + Worker, ~2,750 mutants, 12 shards) every Tuesday;
`mutation-pr.yml` covers just what a pull request changed. This page stays the
method-and-cost record those workflows cite; the current scope and its
reasoning live in `Tools/mutation/config.json`, and the running state of the
whole effort in
[handoff-mutation-testing.md](handoff-mutation-testing.md).

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

## What it found — verified, and half of it was not there

39 survivors. Separating them is the whole skill of reading a mutation report,
and the first pass at it (below, in the original wording) got it substantially
wrong: it read Muter's list and reasoned about the code, without checking
whether each mutant was real.

**It was checked afterwards, mechanically.** Every claimed survivor was applied
to the real source by hand and the suite the sweep runs (`swift test --skip
APITests`, 760 tests, 14 seconds) was run against it. A suite that fails means
the mutant is killable and Muter's "survived" was wrong. A suite that passes
means a genuine gap.

| site | claimed | verified |
|---|---|---|
| `SuiteExecution` `onEvent(.willRun)` / `.didFinish` | hole | **real** |
| `ScriptClassification` comment/blank filter (`&&`→`\|\|`) | hole | **real** |
| `ScriptClassification` `if __name__ == ` keyword | hole | **real** |
| `ScriptClassification` leading-trim set (space, BOM) | hole | **real** |
| `ScriptClassification` horizontal-whitespace trim | hole | **real** |
| `JSONLite` exponent parsing | hole | **real, but not the mutant claimed** — see below |
| `OutputInterpretation:106` `longResult` ternary | hole | already killed — 7 of the 14 `output-contract.json` cases assert a non-null `longResult` |
| `JSONLite` `skipWhitespace()` deletions | hole | already killed |
| `JSONLite` exponent `+` branch | hole | already killed |
| `ScriptClassification` `containsSubstring` loop bounds | "highest-value finding" | already killed |
| `ScriptClassification` empty-needle guard | — | **equivalent mutant**: every caller passes a non-empty string literal, so no test can reach it |

So of the eleven sites examined, **six were real, four were already covered, and
one is unkillable by construction.** That ratio is the argument for
`Tools/mutation/report.py`, which did not exist when this pilot ran: it audits
Muter's output against the guards actually present in the mutated copy and
quarantines the mutants that were never inserted.

**One methodological trap, which flipped four verdicts.** The first verification
pass mutated whole `||` chains at once — `a || b || c` → `a && b && c` — which is
a *stronger* mutation than Muter's `ChangeLogicalConnector`, which changes one
connector per mutant. Under the strong version the suite failed, and those sites
were wrongly written off as covered. Re-run with faithful single-connector
mutations, three of them survived. If you re-verify a report, **mutate exactly
what the tool mutated**, one operator at a time.

### The real ones, and what they cost

**The suite runner's event stream.** Deleting `onEvent(.willRun(...))` or
`onEvent(.didFinish(...))` failed nothing: the suite asserted the returned
outcomes, and the events are a separate output. They are not decoration —
`RunnerDaemon+JobProcessing` turns them into the `test_execution_start` /
`test_execution_end` / `timeout` structured log events that
`docs/operational-diagnostics.md` documents. Losing one blinds the runner's
observability without moving a single mark, which is the hardest kind of
regression to notice. (`.missingScript`, the third event, was already covered.)

**Content-based Python classification.** `!$0.isEmpty && !$0.hasPrefix("#")`
survived becoming `||`, which keeps every line and so fills the five-line
sniffing window with a licence header. Every existing case put its Python
keyword on the first or second line, where the difference does not show. So did
the five-way keyword `||`: turning the last connector into `&&` — dropping
`if __name__ == ` as an independent signal — failed nothing, because every case
also contained `import` or `def`.

**Leading BOM and whitespace trimming.** Both predicates survived a
single-connector `||` → `&&`. Nothing fed the classifier a BOM, which is exactly
how a Windows-authored or spreadsheet-exported file arrives, and an untrimmed
BOM makes `#!` stop being a prefix — so the script falls through to the content
sniff and classifies `.unknown`.

**The exponent's value — and an attribution worth getting right.** The pilot
listed three survivors in the exponent parser. The one testable faithfully (the
`+` branch) turned out to be **already killed**. But probing the area with a
sign flip — `exponentSign = -1` → `1` — failed nothing, and that mutation is
**not one Muter generates**: its operators are relational, logical-connector,
side-effect removal and ternary swap, and none of them rewrites a numeric
literal. So this gap is real and was found *near* the report rather than *in*
it.

The reason is worth more than the finding. `JSONFooterNumberParsingTests`
already parsed `1e3`, `2.5E-2` and `1.0e+4` — but it asserted only that the footer was
*recognised*, which stays true when the arithmetic is wrong. The file's own
header comment said as much ("proves the number parsed") without anyone reading
it as a gap. This is the codebase's signature defect — a check that passes while
proving nothing — inside a test written to pin a parser.

Tests for all six now exist, and each was **seen to fail** under its mutation
before being committed.

### The first full sweep corroborated the hand verification

The weekly sweep ran end to end for the first time on 2026-08-19, over the same
`RunnerCore` at commit `321220b` — before these tests landed. It scored **84%**:
122 killed, 23 real survivors, with **64 phantoms filtered out**, meaning
`report.py` removed nearly three quarters of Muter's reported survivors.

Its real survivors in the two files examined here are, exactly:

| file | survivors |
|---|---|
| `ScriptClassification.swift` | L97, L105, L138, L145 |
| `SuiteExecution.swift` | L86, L90 |

Those are the six sites verified real by hand, with nothing extra and nothing
missing. **Two independent methods — Muter's schemata cross-checked against the
mutated copy, and hand-applying each mutation to the real source — agree
completely.** That is the best evidence available that the phantom filter is
sound rather than merely plausible, and it is why the pilot's own numbers (taken
before the filter existed) should not be quoted.

The sweep's remaining 17 survivors are in `JSONLite` (10) and
`NotebookExtraction` (7) — the latter deliberately excluded from the pilot for
size — and are the standing triage list, in issue **#1459**.

### What following a thread turned up

Writing the leading-trim tests surfaced a real product defect, unrelated to any
mutant: in Swift `"\r\n"` is a **single** `Character` equal to neither `"\r"` nor
`"\n"`, so `split(separator: "\n" as Character)` returns one element for a
CRLF string. `OutputInterpretation` splits stdout that way, so a test script
emitting CRLF has its JSON footer ignored entirely — the student sees the raw
stdout as the summary and the footer's `score` is discarded, silently replacing
partial credit with full marks on a pass. Filed as **#1457**.

That is the honest case for the technique: the mutation report's own hit rate was
about half, but the sites it pointed at were worth reading carefully, and reading
them carefully found something the report never mentioned.

### Not worth chasing

Some `JSONLite` survivors are unkillable by construction. Line 35's
`skipWhitespace` treats `\n` and `\r` as skippable, but the footer is *by
definition* the last non-empty **line** of stdout, so no input reaching this
parser can contain one. `containsSubstring`'s empty-needle guard is the same
shape: no caller passes an empty needle, so no test can reach the branch.

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
