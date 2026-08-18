# Handoff — re-evaluating mutation testing

**Status: closed, negative, dormant — with a precise trigger.** Nothing to build
today. This exists so the question can be re-asked in ten minutes instead of
re-investigated in a day. Tracking issue: **#1447**. Measurements:
[mutation-testing-spike.md](mutation-testing-spike.md).

**If you read one thing:** the trigger is now upstream issue
[muter#307](https://github.com/muter-mutation-testing/muter/issues/307), not a
release note and not a version number. Until a commit lands there, re-running
the probe cannot change its answer — see "Do not re-run the probe yet" below.

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

Two incidental findings, if you do revisit:

- **Linux needs one shim.** `autoreleasepool` is Darwin-only, one call site
  (`DiscoverMutationPoints.swift:83`). Shimmed, Muter builds and runs on Linux.
- **A warm `.build` breaks it.** Muter `copyItem`s the whole project with *no
  exclusions*, and SwiftPM's absolute-path module cache poisons the copy
  (`missing required module 'SwiftShims'`). `exclude:` filters mutation
  *targets*, not the copy. Delete `.build` first; the cost is a cold build.

## Why it fails — isolated 2026-08-18

The spike could not isolate a version boundary and said so: two environments
differing in OS, architecture and compiler agreed on the result, which ruled out
a platform explanation but left "it needs Swift 6.3 support" as a guess. It was
the wrong shape of question. **There is no version boundary. There is a
commit.**

Muter [`99624ec`](https://github.com/muter-mutation-testing/muter/commit/99624ec)
— *"fix: Prevent memory exhaustion on large codebases (2000+ files)"*, PR #302,
2026-04-27 — made discovery stop handing its parsed syntax trees to the step
that rewrites them:

```swift
return [
    .mutationMappingsDiscovered(mappings),
    .sourceCodeParsed([:]),
]
```

`ApplySchemata` therefore always takes its re-parse fallback and rewrites a
**freshly parsed tree**. The schemata are held in
`[CodeBlockItemListSyntax: MutationSchemata]`, and SwiftSyntax nodes hash and
compare by **identity**, not by structure — a node's `SyntaxIdentifier` is its
root plus its index in that root. Every key in the mapping is an identity into
the tree discovery parsed, so against a re-parsed tree **no key can ever
match**. `MuterRewriter.visit` falls through to `super.visit(node)`, and every
mutable expression is written back unchanged.

That accounts for the exact artifact the spike observed. The scaffolding import
survives because `PrepareSourceCode` writes it to disk *before* discovery walks
the file, so it is already in the bytes; only the switches are missing. It also
explains the second, quieter consequence: `GenerateSwapFilePaths` derives its
whole file list from the same emptied dictionary, so Muter generates no swap
files either.

The re-parsed tree is byte-identical to the discovered one — preparation wrote
it to disk first — which is what makes this **conclusively an identity failure
rather than content drift**, and why no amount of toolchain or platform
variation moves the result.

**Confirmed by experiment, not by reading.** Restoring just that cache — three
lines, keeping every part of #302 that actually addresses memory (batching, the
concurrency semaphore, `autoreleasepool`) — and rebuilding was enough, on the
same Linux toolchain, against the same probe package:

| Muter @ `7f1f258` | killed | survived | score |
|---|---:|---:|---|
| unpatched | 0 | 3 | 0% (fabricated) |
| parse-tree cache restored | 2 | 1 | 66% |

Both relational mutants die; the single survivor is the `&&` → `||` one, which
no test in the probe can distinguish. That is exactly the shape the probe
demands — at least one killed, at least one survived. The patched run's working
copy carries three well-formed schemata switches; the unpatched run's carries
none.

**Why Muter's own suite does not catch it.** Both halves of the seam are
covered; the seam is not. `RewriterTests` builds a mapping from
`sourceCode.source` and then rewrites `sourceCode.source.code` — the same tree
the keys came from — so the snapshot proves the rewriter works exactly when
identity holds, which in production it does not. And the five
`ApplySchemataTests` that `99624ec` added to cover the change build an **empty**
`SchemataMutationMapping` and assert `XCTAssertEqual(result.count, 0)` against a
function whose body ends in an unconditional `return []`. Those assertions hold
with the body deleted. Nothing in the suite crosses discovery → apply carrying a
non-empty mapping.

So the mutation-testing tool was disabled for three months by a change whose own
new tests could not observe it. That is this codebase's own defect — a check
that passes while proving nothing — inside the instrument we were buying to cure
it, and it is the strongest argument available for the discipline that shipped
instead.

## Upstream already knows — do not file a duplicate

The spike's remaining action item was "worth an upstream issue since the failure
is silent". It is already filed, by someone else, with the same diagnosis:

| | |
|---|---|
| [muter#307](https://github.com/muter-mutation-testing/muter/issues/307) | *"Schemata silently never applied: ApplySchemata re-parses sources, so node-identity-keyed SchemataMutationMapping never matches"* — opened 2026-07-12, **open**. Blames PR #302. Reporter measured zero schemata marker strings in the built test binaries and ~420 falsely-reported regressions, and **offers working patches** that retain the discovery parse trees. Unmerged. |
| [muter#308](https://github.com/muter-mutation-testing/muter/issues/308) | *"v16 mutation schemata generate corrupt or missing code in four distinct ways"* — opened 2026-07-13, **open**, no fix named. Offset-desynced rewrites producing unparseable mutant branches, a lost original body on do/catch, a corrupted neutral path, and phantom mutants. |

#308 is the reason "just carry the #307 patch ourselves" is not the obvious move.
#307 is a few lines and would make Muter insert mutants again — measured above;
#308 says that once it does, what it inserts is not reliably valid Swift.
Adopting a patched fork would mean owning both, on a tool whose failure mode is
a confident wrong number.

## Do not re-run the probe yet

**Actions → "Mutation-testing probe (macOS)" → Run workflow.** Manual dispatch,
free on this public repo, ~10 minutes. One run answers it — but only once
something has changed, and as of this writing nothing has: `7f1f258` is still
Muter's HEAD, `16` is still the newest tag, and both issues are open. Dispatching
it today re-measures a known constant.

Re-run it when a commit lands on Muter that restores the discovery-to-apply
identity relationship — most likely the #307 patches, whose merge is the thing to
watch. Pass the new ref via the workflow's `muter_ref` input rather than editing
the file. Watching that one issue is cheaper than watching releases, and much
cheaper than watching the tag list, which has not moved since before the bug.

When that lands, expect the probe to pass: the measurement above is what a fixed
Muter does against it. That makes the re-run a confirmation rather than a
gamble — which is also why running it *now*, against a ref that provably cannot
insert a mutant, is worth nothing.

The probe is built to distrust the tool, and both properties are load-bearing:

- **It establishes ground truth without Muter** — a step applies the mutation
  by hand and requires the suite to fail. Without it, a green probe would only
  prove Muter agreed with itself.
- **It asserts a shape, not a score.** One strong test pinning a boundary, one
  weak test that cannot observe its mutant. It fails on 0% (inserted nothing),
  on 100% (implausible), and on no outcomes at all (crashed).

If you rewrite it, keep both. They are the difference between a probe and a
rubber stamp.

## If it works

Do **not** point it at the whole codebase. The shape:

- **Scoped** — `--files-to-mutate` over the week's changed files. A full
  campaign across ~3,000 tests with a cold build per run is not affordable even
  on free minutes.
- **Scheduled**, not per-PR.
- **A report, never a gate.** A surviving mutant is a question for a human;
  failing a build on a mutation score punishes the wrong thing.

Ask before building the weekly job — it is a standing commitment of CI time and
attention, not a one-off. Given #308, budget a second probe run against a real
Chickadee file before trusting any number it produces: the probe package is
three lines of Swift and will not exercise the corruption modes #308 describes.

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

That discipline is what the root cause above argues for. Muter's regression was
shipped with tests, and passed them, because its tests asserted a constant and
its rewriter test rewrote the same tree it had just read. A fixture that must be
*seen to fail* is the cheapest check neither of those mistakes survives.
