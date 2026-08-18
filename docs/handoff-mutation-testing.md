# Handoff — re-evaluating mutation testing

**Status: closed, negative, dormant.** Nothing to build today. This exists so
the question can be re-asked in ten minutes instead of re-investigated in a day.
Tracking issue: **#1447**. Measurements: [mutation-testing-spike.md](mutation-testing-spike.md).

## Why we wanted it

The recurring defect in this codebase is **verification that passes while
proving nothing** — four instances on the record, including a hover-budget test
that passed three times while exercising nothing. Mutation testing is the
industrial instrument for exactly that: mutate the source, and any mutant the
suite fails to kill is a hole in the suite.

That motivation has not changed. Only the tooling failed.

## What was measured — do not redo this

[Muter](https://github.com/muter-mutation-testing/muter) @ `7f1f258`, on both
platforms, reports a **fabricated 0%**: it discovers mutants correctly, inserts
none, and reports every one as "survived".

| | Linux (Swift 6.3, SwiftPM) | macOS (`macos-latest`, Xcode toolchain) |
|---|---|---|
| Mutants discovered | 3, correct operators and lines | 3, correct operators and lines |
| Result | 0 killed, 3 survived | 0 killed, 3 survived |

The macOS run is the decisive one: the step immediately before it applies the
mutation **by hand** and requires the suite to fail. In one run — the mutant is
provably killable, and Muter says it survived.

**Mechanism**, inspected in Muter's own working copy: the "mutated" source
carries its scaffolding (`import class Foundation.ProcessInfo`) and **no
mutation switches** — the function bodies are byte-identical. Schemata live in
`[CodeBlockItemListSyntax: MutationSchemata]`, a dictionary keyed by SwiftSyntax
nodes, and `MutationSwitch.apply` returns the original syntax untouched whenever
that lookup is empty.

Two incidental findings, if you do revisit:

- **Linux needs one shim.** `autoreleasepool` is Darwin-only, one call site
  (`DiscoverMutationPoints.swift:83`). Shimmed, Muter builds and runs on Linux.
- **A warm `.build` breaks it.** Muter `copyItem`s the whole project with *no
  exclusions*, and SwiftPM's absolute-path module cache poisons the copy
  (`missing required module 'SwiftShims'`). `exclude:` filters mutation
  *targets*, not the copy. Delete `.build` first; the cost is a cold build.

**The version boundary was NOT isolated.** Two environments differing in OS,
architecture and compiler agree on the result, so "it needs Swift 6.3 support"
is a guess. Trigger on observed behaviour, not a version number.

## How to re-ask the question

**Actions → "Mutation-testing probe (macOS)" → Run workflow.** Manual dispatch,
free on this public repo, ~10 minutes. One run answers it.

The probe is built to distrust the tool, and both properties are load-bearing:

- **It establishes ground truth without Muter** — a step applies the mutation
  by hand and requires the suite to fail. Without it, a green probe would only
  prove Muter agreed with itself.
- **It asserts a shape, not a score.** One strong test pinning a boundary, one
  weak test that cannot observe its mutant. It fails on 0% (inserted nothing),
  on 100% (implausible), and on no outcomes at all (crashed).

If you rewrite it, keep both. They are the difference between a probe and a
rubber stamp.

## When it is worth re-running

A Muter release mentioning schemata or mutant insertion, swift-syntax 602+, or
Swift 6.3+ support. Watching the repo's releases is cheaper than watching the
issue tracker.

## If it works

Do **not** point it at the whole codebase. The shape:

- **Scoped** — `--files-to-mutate` over the week's changed files. A full
  campaign across ~3,000 tests with a cold build per run is not affordable even
  on free minutes.
- **Scheduled**, not per-PR.
- **A report, never a gate.** A surviving mutant is a question for a human;
  failing a build on a mutation score punishes the wrong thing.

Ask before building the weekly job — it is a standing commitment of CI time and
attention, not a one-off.

## The alternative, already assessed

[ericodx/swift-mutation-testing](https://github.com/ericodx/swift-mutation-testing)
does not build on Linux (`no such module 'CryptoKit'`, Apple-only). Its design
is better on paper — schematization rather than rebuild-per-mutant, and explicit
support for both XCTest and **Swift Testing**, which matters because every test
here is Swift Testing — but porting off CryptoKit to swift-crypto is real work,
and it is less actively maintained. Reconsider only if Muter stays broken and
the appetite survives.

## What shipped instead

`scripts/check-guards.sh` + `scripts/guard-fixtures/` — every guard must be
**seen to fail** on a fixture reproducing the defect it exists to catch. Same
target, no platform question, no external dependency. Mutation testing would
extend that discipline from the guard layer to the unit layer; it does not
replace it.
