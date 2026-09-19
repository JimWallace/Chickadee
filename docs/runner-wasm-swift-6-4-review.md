# The browser wasm on Swift 6.4 — what the toolchain move changed, measured

Status: **slices 1–3 shipped** (#1548, #1550, and the language-mode PR
after it). Slice 4 was spiked, measured and deliberately NOT shipped; the
numbers are in the table so the decision can be revisited with them. Companion to
[runner-wasm-migration.md](runner-wasm-migration.md) (the design) and
[runner-wasm-serving.md](runner-wasm-serving.md) (caching and the size guard).

The question was whether anything in Swift 6.4 helps the wasm build — smaller,
faster, or better engineered. The honest answer is that the toolchain move
itself (#1541) bought ~3 % on the wire and nothing else on its own, and that
the largest finding has nothing to do with Swift 6.4: **the artifact was five
times its real size for its entire life, and no guard could see it.** Two 6.4
changes then matter for the code (`Double(String)` in Embedded Swift, and
BridgeJS building under the Embedded SDK), one 6.4 headline does not apply
(`EmbeddedRestrictions`), and one thing that was always possible turned out to
be the cheapest guard in the repo (a host-side Embedded compile).

Everything below was measured on the pinned toolchain — Swift 6.4.0 with the
`swift-6.4.0-RELEASE_wasm-embedded` SDK, JavaScriptKit 0.59.0, binaryen's
`wasm-opt` 112 via npx — against the Node output-contract harness
(`Tests/BrowserRunnerJSTests/output-contract.test.mjs`), which drives the real
artifact through every case in `Tests/Fixtures/output-contract.json`.

## 1. The artifact was 80 % DWARF

Section sizes of the vendored module as of v0.5.178 (built on 6.3.2) and again
after #1541 (6.4.0), which were within 50 bytes of each other:

| section | bytes |
|---|---|
| `.debug_info` | 407,248 |
| `.debug_names` | 294,305 |
| **code** | **206,870** |
| `.debug_str` | 201,783 |
| `.debug_ranges` | 115,790 |
| `.debug_loc` | 115,402 |
| **data** | **63,553** |
| `.debug_abbrev` | 44,614 |
| `.debug_line` | 25,829 |
| everything else | ~2,800 |

1,478,247 bytes on disk, 492,677 gzipped; 270 KB of it was the program. Three
facts, each documented on its own, produced this together:

1. The release build links with `-g` (visible in the frontend command line:
   `-g -debug-info-format=dwarf -dwarf-version=4 … -O`).
2. The PackageToJS plugin's `--debug-info-format` defaults to `none`, and its
   "Stripping DWARF debug info…" step runs `wasm-opt --strip-dwarf` — a
   `wasm-opt` it looks up on `PATH`. The vendor job's `ubuntu-latest` runner
   has none, so the plugin printed `Warning: wasm-opt is not installed,
   optimizations will not be applied` and copied the module unstripped.
3. `scripts/build-runner-wasm.sh` then ran its own `wasm-opt -Oz --converge
   --strip-producers` via npx. binaryen keeps custom sections it is not told
   to drop, and nothing said `--strip-debug`.

The size guard measured the whole file, so a module that was 1.2 MB of debug
data read as "within budget", and the budget was set FROM that number ("528 KB
warn, 672 KB fail, ~35 % over today's size"). The serving doc even recorded
that "394 KB brotli is the floor" for a module bundling the Embedded runtime
and JavaScriptKit. It was the DWARF's floor.

The fix is one flag. With `--strip-debug`, the same module the plugin hands
over becomes:

| variant | raw | gzip |
|---|---|---|
| as vendored (6.4, `-Oz`, DWARF kept) | 1,478,296 | 492,710 |
| `-Oz --strip-debug` | 269,935 | 129,815 |
| `-Os --strip-debug` | 270,736 | 130,006 |
| `-O3 --strip-debug` | 273,030 | 129,551 |
| `-Osize` at the Swift level, then `-Oz --strip-debug` | 259,914 | 126,840 |

The optimiser level is a wash (the plugin's `-Os` and our `-Oz` are within
0.3 %); `-Osize` on the Swift side is worth ~10 KB raw and is enabled, since
the bridge runs once per submission. All 37 Node tests pass against every row.
The guard's thresholds now sit at 144 KB / 176 KB gzip, below any unstripped
module, so the likeliest future regression — `wasm-opt` unavailable when the
vendor job runs — fails the ceiling instead of hiding under it.

**What the 6.4 move itself bought:** 509,249 → 492,677 gzip (−3.3 %), from the
compiler and stdlib, with no change to the build.

## 2. What the remaining 270 KB is

From the name section of the unstripped build (`wasm-objdump -x -j Code`,
853 functions, 252 KB of code before `-Oz`), grouped by demangled module:

| slice | bytes | what it is |
|---|---|---|
| Swift stdlib, String/Unicode | ~94,000 | `_opaqueCharacterStride` (4.5 KB ×2), NFC normaliser, `_slowCompare`, `String.Iterator.next`, `Character` subscripts |
| RunnerCore | ~68,000 | `interpretScriptOutput` 3.6 KB, `isSafeTopLevelStatement` 3.6 KB, the JSON parser, `sanitizeCellForModule`, `extractPython`, … |
| wasi-libc + Swift runtime (C) | ~43,000 | `printf_core` 8.8 KB, `dlmalloc`/`dlfree`/`dispose_chunk` ~10 KB, `swift_task_create_common` 1.9 KB |
| JavaScriptKit | ~31,000 | the dynamic `JSObject`/`JSValue` bridge and its specialisations |
| RunnerWasm (the bridge) | ~6,400 | `parseSuiteItems` 2.5 KB, `outcomesToJS` 2.1 KB |
| JavaScriptEventLoop | ~230 | |
| data segment | 63,553 | the Unicode data tables (`-lswiftUnicodeDataTables`) and string literals |

The one slice with an obvious lever is the first. RunnerCore works in
`Character`s — `Array(text)` in the JSON parser and in `containsSubstring`,
`Character` comparisons in the classifiers — and `String ==` normalises to NFC,
which is what drags the grapheme-stride and normalisation paths in. The inputs
are script names, shebang lines and JSON footers; a UTF-8-view rewrite would
drop most of the ~94 KB and the data tables with it. It is also the largest
diff for the smallest user-visible gain: the artifact is content-hashed and
served `immutable`, so a student pays the 134 KB once per term, and the
grading runtime it gates on is a 20–140 MB kernel env. Not worth doing for
size; noted here so nobody rediscovers it as a mystery.

`printf_core` is worth one sentence: nothing in RunnerCore prints, so it rides
in on the Swift runtime's fatal-error reporting and JavaScriptKit's `print`
path. Not removable from here.

## 3. Swift 6.4 changes that apply

### `Double(String)` links in Embedded Swift — and the fold it replaced was wrong

`JSONLite.parseDoubleLiteral` was a 55-line mantissa-times-power-of-ten fold,
written because `Double(String)` lowered to `_swift_stdlib_strtod_clocale`,
which the Embedded runtime did not provide (#771, a link error the moment the
browser reached `executeSuites`). Swift 6.4's Embedded Swift post lists
"floating point parsing" as reimplemented; a probe that calls `Double(String)`
from a `JSClosure` links under the 6.4 Embedded SDK and returns correct values
in Node for `1.5e-3`, `123.456e-7`, `1e308` and `9007199254740993`.

The fold was not merely longer. Each `mantissa * 10` rounds, and so does the
final multiply by a power of ten built by repeated multiplication, so the
result is one unit in the last place off for ordinary inputs and worse at the
extremes. Compared against `Double(String)` natively, 9 of 12 probes differed:

| literal | fold | `Double(String)` |
|---|---|---|
| `0.3` | 0.30000000000000004 | 0.3 |
| `0.7` | 0.7000000000000001 | 0.7 |
| `4.35` | 4.3500000000000005 | 4.35 |
| `8.5e-5` | 8.499999999999999e-05 | 8.5e-05 |
| `1e308` | 9.999999999999998e+307 | 1e+308 |
| `1.7976931348623157e308` | inf | 1.7976931348623157e+308 |
| `2.2250738585072014e-308` | 0.0 | 2.2250738585072014e-308 |

A footer's `score` is multiplied by `points` and a `metric` is compared for
ranking, so this reached grades — on BOTH runners, since RunnerCore is the one
implementation. The existing `JSONFooterNumberParsingTests` held throughout
because they assert within `1e-12`, which is the right shape for "the exponent
applied" and the wrong one for "the value is the value";
`JSONFooterNumberExactnessTests` pins the table above with `==`. The parser is
now `Double(String(slice))` behind the same `[0-9.eE+-]` prefilter, so none of
the spellings `Double` accepts beyond JSON (`inf`, `nan`, hex floats) can reach
it. Cost: ~12 KB raw in the wasm for the correctly rounded implementation,
which is the right trade.

### BridgeJS builds under Embedded Swift — the bridge's central constraint is gone

`wasm/Package.swift` and the bridge both said "no BridgeJS (incompatible with
Embedded Swift)", and the Stage 5 review accepted dynamic `JSObject` interop
as "forced". JavaScriptKit's own `Examples/Embedded` now applies the BridgeJS
plugin and uses `@JS`, and Swift 6.4's release notes cite its "safe bridging"
as up to 40× faster than dynamic bridging. Tried here, on our exact pins:

- A `@JS public func` (sync, `String` in and out), a `@JS public struct` with
  `String`/`Int` fields passed in an array and returned, and an `async` export
  taking an `async` JS callback all compile under the Embedded SDK, and all
  three behave in Node — the struct arrives as a plain `{cellType, source}`
  object or via `exports.BridgeCell.init(...)`, and the async callback round
  trip returns the right value.
- The one thing that failed was a struct whose synthesised init was
  `internal`: the generated glue is `@_transparent` and needs `public init`.
- Size: the experimental build carried BOTH bridges (the dynamic one still
  registered) at 278,862 raw / 133,896 gzip against 269,935 / 129,815, i.e.
  +9 KB before removing the ~6 KB dynamic bridge and the JavaScriptKit
  specialisations it alone uses. Net cost after migration: about zero. The
  generated glue is 19 KB of Swift and 30 KB of JS before bundling.

Speed is irrelevant here — the bridge is called a handful of times per
submission — so the reason to migrate is engineering, and it is a good one.
Today `main.swift` is ~280 lines, four of its five exports are near-identical
hand-marshalled closures (`runnerExtractR`/`Lua`/`Octave` differ by one
function name), every field crosses the boundary as an untyped `JSValue` with
a `?? ""` or `?? 0` default, and the JS contract lives in a comment. With
`@JS` the contract is a generated `bridge-js.d.ts`, structs are structs,
`[SuiteItem]` is `[SuiteItem]`, and the marshalling code is deleted. It is
scoped as **slice 2** below rather than done here because it changes the JS
surface (`exports.*` from `init()` instead of `globalThis.runner*` globals),
which touches `browser-runner.js`, both Node harnesses and the loader, and
that deserves its own PR and review.

### `EmbeddedRestrictions` — the headline that does not apply

Swift 6.4 adds a diagnostic group, enabled as
`.treatWarning("EmbeddedRestrictions", as: .warning)` in `swiftSettings`, so a
non-embedded build can warn about code Embedded Swift would reject. That is
exactly what RunnerCore wants, so it was tried first. On 6.4 it produced no
diagnostic for `Mirror`, `String(describing: any)`, `String.contains(String)`,
`uppercased()`, a non-final class, untyped `throws` or a `[String: Int]`
subscript — natively, with `-c -O`. Those are all `@available(*, unavailable)`
under `-enable-experimental-feature Embedded`, which is a different mechanism
from the diagnostic group, and the group's members (as far as a probe shows)
are language-level shapes RunnerCore does not use. The compiler recognises the
group (an unknown one warns), it just has nothing to say about this code. Do
not add it expecting coverage; the next item is the real guard.

### Existentials, untyped throws, metatypes

6.4's Embedded Swift accepts `any P` (no generic calls on it), untyped
`throws`, and metatypes. RunnerCore uses none of these: `executeSuites` takes
`some ScriptExecutor` (one monomorphisation, deliberately), nothing throws, and
the enums are `String`-backed. The comments in `TestOutcome.swift`,
`TestStatus.swift` and `TestTier.swift` about `Codable` being unavailable in
Embedded remain true — `Codable` is reflection-shaped and 6.4 did not change
that.

## 4. The cheapest guard in the repo

The Stage 5 review listed "no per-PR wasm-SDK build in CI" as an accepted
gap, on the reasoning that the SDK install is slow and the artifact is
vendored. Both are true and neither is the constraint: the HOST toolchain
ships an Embedded Swift standard library for its own triple, so

```sh
swiftc -c -O -wmo -parse-as-library -module-name RunnerCore \
    -enable-experimental-feature Embedded Sources/RunnerCore/*.swift -o /dev/null
```

compiles RunnerCore as Embedded Swift on Linux x86_64 in **7 seconds**, on
both 6.3 and 6.4, and fails with the same availability errors the wasm build
would (`'Mirror' is unavailable`, `conformance of 'AnyCollection<Element>' to
'Collection' is unavailable: unavailable in embedded Swift`). Nothing is
linked or run — that is the vendor job's task, and link-time surprises are
the runtime's, not RunnerCore's — but every restriction that has broken this
build so far was a compile-time one. `scripts/check-runnercore-embedded.sh`
runs it in `format-lint`, with a `check-guards.sh` fixture that appends a
`Mirror` to RunnerCore and asserts the guard fails. The bridge in
`wasm/Sources` is not covered (JavaScriptKit only builds against the wasm
SDK); it is 280 lines that change rarely, and slice 2 shrinks it further.

## 5. Slices

| slice | what | measured effect | status |
|---|---|---|---|
| 1 | `--strip-debug` + `-Osize`, thresholds rebaselined, `Double(String)`, host Embedded guard, stale-output clean, comment corrections | 1,478 KB → 273 KB raw; 493 KB → 134 KB gzip; correctly rounded footer numbers; embed-breakage caught per PR | **this PR** |
| 2 | The bridge is BridgeJS `@JS` exports (`wasm/Sources/RunnerWasm/Bridge.swift`): typed structs for cells, suite items, script output and outcomes, async `executeSuites` with typed async JS callbacks, and the generated `.d.ts` vendored as `Public/runner-wasm/runner-core.d.ts` as the contract. The legacy `globalThis.runner*` entry points are a 60-line JS adapter (`wasm/loader/runner-core-entry.js`, the esbuild entry) over the typed exports, so browser-runner.js and every existing Node test kept their contract unchanged | −190 lines of hand-marshalling Swift; **+9 KB raw / +4 KB gzip** on the wasm (281,578 / 138,181) and +6 KB gzip on the loader (BridgeJS's struct codecs cost more than the dynamic bridge they replaced; the "about zero" prediction below was wrong by that much); `runner-core-exports.test.mjs` pins the typed surface and the adapters' tolerances | **shipped** |
| 3 | Swift 6 language mode for the wasm package (`swiftLanguageModes: [.v6]`), the same mode as the main package. JavaScriptKit's Embedded example pins `.v5` and the hand-marshalled bridge needed it (non-`Sendable` `JSObject`s behind an `async` protocol); with BridgeJS the executor holds the plugin's typed closures inside one call and the package builds with zero diagnostics | none on size; strict concurrency on the bridge | **shipped** |
| 4 | RunnerCore scanning and comparing UTF-8 bytes (no `Character`, no `String ==` / `hasPrefix` / `contains` on Strings, no `[String: _]`; the JSON object as a member list; a byte-wise `TestTier.matching(rawValue:)` in the bridge, because the synthesised `init?(rawValue:)` alone re-linked 33 KB of normalisation tables) | **spiked, measured, not shipped**: 281,578 / 138,181 → 177,343 / 80,331 (−37 % raw, −42 % gzip; the grapheme and normalisation code and both tables gone, data segment 63 KB → 8 KB). A bridge-only build with RunnerCore unreferenced is 108,255 / 48,544, so RunnerCore's own logic is the ~69 KB that remains. Cost: every scanner in RunnerCore rewritten on bytes (~600 lines touched, one new helper file), with 574 Node and 450 native tests green and a behaviour test for the places a byte scanner could plausibly differ (non-ASCII trailing white space, an indented first column, a repeated footer key). The maintainer's call was that ~58 KB gzip on an immutable once-per-term download is not worth carrying that code; the spike lives on a local branch and this row is what a later revisit starts from | not shipped |

Two things deliberately NOT changed. The "artifact rebuilt only on `main`"
model stays: a PR still runs against the checked-in artifact (this PR
re-vendors in-PR, as #1541 did, because the build script itself changed and
the rebaselined ceiling would otherwise fail on the old artifact), and the
`score`/`metric` "assert once present" pattern in the Node harness is what
makes the model tolerable. And `wasm-opt` is still fetched
via npx rather than installed on the vendor runner: putting it on `PATH` would
let the plugin's own strip step work, but the build script strips explicitly
now and does not depend on which of the two ran.
