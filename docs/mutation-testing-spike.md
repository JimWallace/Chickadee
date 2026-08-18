# Mutation testing — spike (2026-08)

**Status: open, gated on one macOS probe run.** Nothing is adopted. Run the
`Mutation-testing probe (macOS)` workflow (`workflow_dispatch`) and read its
verdict before spending anything further.

## Why we looked

The recurring defect in this codebase is not an untested path — it is
**verification that passes while proving nothing**. Four independent instances
are on record: a regression test matching a wiring string in page HTML after the
wiring went dead, the repaint probe's filter assertion passing against a dead
poll, the S5 guard matching its own documentation, and — in #1445, the PR that
prompted this — a hover-budget test that passed three times while exercising
nothing (the fixture picked a one-word category, then the allocation floor never
engaged, then both titles landed at exactly the cap).

The house rule already exists — *"a check never seen to fail is not a check"*
([ui-ratchet-handoff.md](ui-ratchet-handoff.md)) — and it is the one discipline
here with no enforcement behind it. Mutation testing is the industrial form of
that rule: change the source, and any mutant the suite fails to kill is a hole
in the suite.

## What was measured

Both candidate tools were built and run on this repo's own platform (Linux,
Swift 6.3, SwiftPM). Neither works there.

### Muter ([muter-mutation-testing/muter](https://github.com/muter-mutation-testing/muter), @ 7f1f258, 2026-07-21)

Its README badge says macos | linux; its FAQ says macOS only. Measured, the
executable **does** build and run on Linux after one shim — but it then fails
**silently and confidently**, which for a verification tool is the worst
available outcome.

| finding | detail |
|---|---|
| Builds on Linux | after shimming `autoreleasepool` (Darwin-only, one call site, `DiscoverMutationPoints.swift:83`) |
| Discovery works | SwiftSyntax analysis found the right mutants at the right lines |
| The copy is poisoned | it `copyItem`s the whole project with **no exclusions**, so a present `.build` comes too and SwiftPM's absolute-path module cache breaks the copy (`missing required module 'SwiftShims'`). `exclude:` filters mutation *targets*, not the copy. Deleting `.build` first is the workaround, at the cost of a cold build per run |
| **It inserts no mutants** | its rewriter wrote the scaffolding (`import class Foundation.ProcessInfo`) into its working copy and emitted **no mutation switches** — the function bodies are byte-identical to the originals. Every "mutant" therefore ran the unmutated binary |
| **The score is fabricated** | it reported 0%, all mutants surviving. Applying one of those same mutations by hand makes the suite fail, so the mutants it called "survived" are ones the tests demonstrably kill |

The mechanism behind the empty rewrite: schemata are held in
`[CodeBlockItemListSyntax: MutationSchemata]` — a dictionary keyed by
**SwiftSyntax nodes** — and `MutationSwitch.apply` returns the original syntax
untouched whenever the lookup yields nothing. Whether that lookup fails only on
Linux, or generally against current toolchains, is exactly what the macOS probe
settles. Muter pins `swift-syntax from: 601.0.0` (resolved 601.0.1) while the
toolchain here is 6.3.

### swift-mutation-testing ([ericodx/swift-mutation-testing](https://github.com/ericodx/swift-mutation-testing), 2026-05-24)

Does not build on Linux at all: `no such module 'CryptoKit'` (Apple-only). That
is a real port to swift-crypto, not a shim. Its design is the better one on
paper — schematization (build once, switch mutants at runtime) rather than
rebuild-per-mutant, and explicit support for **both XCTest and Swift Testing**,
which matters because every test here is Swift Testing. It is also less actively
maintained than Muter and declares `platforms: [.macOS(.v15)]`. Worth
reconsidering only if the Muter probe fails and the appetite survives.

## The probe, and why it is shaped this way

`.github/workflows/mutation-probe.yml` — manual dispatch, macOS runner, **free**
because this repository is public. It puts the *tool* on trial, not the
codebase: a throwaway package with one **strong** test pinning a boundary and
one **weak** test that never exercises its second condition. A working mutation
tool must kill at least one and let at least one survive.

Two design points worth keeping if this is ever rewritten:

- **It establishes ground truth without Muter.** A step applies the mutation by
  hand and *requires* the suite to fail. Without it, a green probe would only
  prove Muter agreed with itself — the very failure being chased.
- **The assertion is a shape, not a score.** Which replacement a relational
  operator receives is Muter's business; discriminating at all is the property
  under test. It fails on 0% (inserted nothing), on 100% (implausible — the weak
  test cannot observe its mutant), and on no outcomes at all (crashed).

## What happens next, by verdict

- **Muter discriminates** → build the weekly scheduled run. Scope it with
  `--files-to-mutate` against the week's changed files rather than the whole
  tree; a full campaign over ~3,000 tests with a cold build per run is not
  affordable even on free minutes. It is a report, never a gate — a surviving
  mutant is a question for a human, not a build failure.
- **Muter does not discriminate** → it is not adoptable, and the finding is
  worth an upstream issue since the failure is silent. Fall back to **guard
  self-tests**: every `scripts/check-*.sh` ships a fixture it must reject, with
  a meta-check that runs them. That targets the same defect, has no platform
  question, and is a day's work. It is what #1445 did by hand — reintroduce the
  shipped pattern, watch four rules fire, restore — which is the only reason
  that guard is trusted.
