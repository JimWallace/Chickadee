# Mutation testing — spike (2026-08)

**Status: CLOSED, negative. Muter is not adoptable.** The macOS probe ran
(2026-08-18, run 32141581986, `macos-latest`) and reported **killed=0,
survived=3 — 0%**, the same fabricated score measured on Linux, on a run whose
ground-truth step had just proven by hand that one of those mutants is
killable. **The defect is not platform-specific.** The workflow stays on manual
dispatch so the question can be re-asked cheaply.

**The cause was isolated the same day** — one upstream commit, `99624ec` (PR
#302), already reported upstream as
[muter#307](https://github.com/muter-mutation-testing/muter/issues/307) and
still open. There is no version boundary to find. Re-running the probe before
that issue moves cannot change its answer; see
[the root cause](#the-root-cause-isolated-after-the-probe).

Do not read a Muter score from either platform as a measurement of this test
suite. The fallback — guard self-tests — is in `scripts/check-guards.sh`.

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
untouched whenever the lookup yields nothing. Why that lookup fails was isolated
after the probe returned; it is a single upstream commit, not a toolchain
boundary. See [the root cause](#the-root-cause-isolated-after-the-probe) below.

### swift-mutation-testing ([ericodx/swift-mutation-testing](https://github.com/ericodx/swift-mutation-testing), 2026-05-24)

Does not build on Linux at all: `no such module 'CryptoKit'` (Apple-only). That
is a real port to swift-crypto, not a shim. Its design is the better one on
paper — schematization (build once, switch mutants at runtime) rather than
rebuild-per-mutant, and explicit support for **both XCTest and Swift Testing**,
which matters because every test here is Swift Testing. It is also less actively
maintained than Muter and declares `platforms: [.macOS(.v15)]`. Worth
reconsidering only if the Muter probe fails and the appetite survives.

## The root cause, isolated after the probe

The probe answered "does Muter discriminate" (no) but not "why", and the spike
left the version boundary explicitly un-isolated. Reading the pipeline settles
it: the boundary is not a version. It is **one commit**, and it is on Muter's
`main` today.

[`99624ec`](https://github.com/muter-mutation-testing/muter/commit/99624ec) —
*"fix: Prevent memory exhaustion on large codebases (2000+ files)"*, PR #302,
2026-04-27, the second-newest commit in the repository — changed
`DiscoverMutationPoints` to return `.sourceCodeParsed([:])` instead of the
dictionary of trees it had just parsed, and taught `ApplySchemata` to re-parse
each file on demand instead. The chain from there is short:

| step | consequence |
|---|---|
| `state.sourceCodeByFilePath` is empty | `ApplySchemata` always takes its re-parse fallback |
| the re-parse produces a **new tree** | its nodes carry new `SyntaxIdentifier`s |
| the mapping is `[CodeBlockItemListSyntax: MutationSchemata]` | SwiftSyntax nodes hash and compare by **identity**, not structure |
| every lookup misses | `MuterRewriter.visit` falls through to `super.visit(node)` |
| nothing is rewritten | every mutant runs the unmutated binary and reports "survived" |

Two details make this conclusive rather than plausible.

- **The re-parsed tree is byte-identical to the discovered one.**
  `PrepareSourceCode` writes the prepared source — scaffolding import included —
  back to disk *before* discovery walks it, so both parses see the same bytes.
  The lookup still misses. Content drift is therefore excluded, and identity is
  the only remaining explanation. It also explains why the "mutated" file
  contains the import but no switches: the import was in the bytes already.
- **The same emptied dictionary breaks a second step.**
  `GenerateSwapFilePaths` builds its entire file list from
  `state.sourceCodeByFilePath.keys`, so Muter also generates no swap files. One
  changed line, two silent consequences.

### Verified by patch, on this toolchain

The chain above was then tested rather than trusted. Restoring only the parse-tree
cache — `.sourceCodeParsed(discovered.sourceCodeByFilePath)`, the file's tree
recorded beside its mappings, and the storage put back on `DiscoveredFiles`,
keeping every part of #302 that actually addresses memory (batching, the
concurrency semaphore, `autoreleasepool`) — and rebuilding gives, on Linux /
Swift 6.3, against the same probe package used in CI:

| Muter @ `7f1f258` | Probe.swift:3 ROR | Probe.swift:7 ROR | Probe.swift:7 logical connector | score |
|---|---|---|---|---|
| unpatched | survived | survived | survived | **0%** |
| cache restored | **killed** | **killed** | survived | **66%** |

The one survivor is the `&&` → `||` mutant the deliberately weak test cannot
observe. That is the probe's whole design — at least one killed, at least one
survived — so a fixed Muter passes it.

The working copies settle it at the byte level. Patched, the generated file
carries three well-formed switches:

```swift
public static func canVote(age: Int, registered: Bool) -> Bool {
    if ProcessInfo.processInfo.environment["Probe_RelationalOperatorReplacement_7_13_270"] != nil {
    age <= 18 && registered
    } else if ProcessInfo.processInfo.environment["Probe_ChangeLogicalConnector_7_19_276"] != nil {
    age >= 18 || registered
    } else {
    age >= 18 && registered
    }
}
```

Unpatched, the same file is the original body with the import above it and no
switches at all. Three lines of Swift separate a fabricated 0% from a correct
66%.

### Why Muter's own tests miss it

Both halves of the seam are tested. The seam is not.

- `RewriterTests.test_allOperatorsWithImplicitReturnSourceCode` builds a mapping
  from `sourceCode.source` and then calls `sut.rewrite(sourceCode.source.code)`
  — **the same tree the keys came from**. Identity holds inside the test, the
  snapshot is correct, and the test is structurally incapable of failing for the
  reason production fails.
- The five `ApplySchemataTests` that `99624ec` added to cover its own change
  construct an **empty** `SchemataMutationMapping` — so there is nothing to
  insert on either the cached or the lazy path — and assert
  `XCTAssertEqual(result.count, 0)` against a function that ends in an
  unconditional `return []`. Those assertions pass with the body deleted.

That is the finding worth carrying out of this spike. The tool bought to catch
checks that pass while proving nothing was itself disabled for three months by a
commit whose own tests did exactly that.

### Upstream state

Both facts were already known upstream when we measured them, which is worth
knowing before anyone writes an issue:

| issue | state |
|---|---|
| [muter#307](https://github.com/muter-mutation-testing/muter/issues/307) — *"Schemata silently never applied: ApplySchemata re-parses sources, so node-identity-keyed SchemataMutationMapping never matches"* | opened 2026-07-12, **open**. Same diagnosis, blames PR #302, reports zero schemata markers in the built binaries and ~420 falsely-reported regressions, and offers working patches. Unmerged. |
| [muter#308](https://github.com/muter-mutation-testing/muter/issues/308) — *"v16 mutation schemata generate corrupt or missing code in four distinct ways"* | opened 2026-07-13, **open**, no fix named. Offset-desynced rewrites yielding unparseable branches, lost do/catch bodies, a corrupted neutral path, phantom mutants. |

So the upstream-issue action item below is discharged — do not file a duplicate —
and the revisit trigger becomes a single watchable thing: a commit landing
against #307. #308 is why merging #307 would not by itself make Muter
trustworthy here.

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

## The verdict, and why the probe was worth building

Muter reported 0% on macOS with Xcode's own toolchain — the platform it is
developed and supported on. Every step before the verdict passed, including the
one that applies the mutation by hand and requires the suite to fail, so the run
establishes both halves: the mutant is killable, and Muter says it survived.

That is the whole argument for putting the tool on trial first. Pointed straight
at Chickadee, Muter would have reported a catastrophic mutation score for a
well-tested suite, every "finding" would have been noise, and the number would
have looked like a measurement. A weekly job publishing that would have been
worse than no job at all — the failure mode is a confident wrong answer, which
is the exact defect class the tool was being bought to catch.

The probe cost one workflow file and one run on a free runner.

## What happens next, by verdict

- ~~**Muter discriminates** → build the weekly scheduled run. Scope it with~~
  *(did not happen — see above)* Scope it with
  `--files-to-mutate` against the week's changed files rather than the whole
  tree; a full campaign over ~3,000 tests with a cold build per run is not
  affordable even on free minutes. It is a report, never a gate — a surviving
  mutant is a question for a human, not a build failure.
- **Muter does not discriminate** → it is not adoptable, and the finding is
  worth an upstream issue since the failure is silent. *(Already filed, by
  someone else — [muter#307](https://github.com/muter-mutation-testing/muter/issues/307),
  open. Do not file a duplicate; watch it instead.)* Fall back to **guard
  self-tests**: every `scripts/check-*.sh` ships a fixture it must reject, with
  a meta-check that runs them. That targets the same defect, has no platform
  question, and is a day's work. It is what #1445 did by hand — reintroduce the
  shipped pattern, watch four rules fire, restore — which is the only reason
  that guard is trusted.
