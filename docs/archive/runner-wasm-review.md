# Swift → Wasm PR Review — Runner WASM migration (Stage 5)

Review of the Embedded-Swift / WebAssembly surface introduced by the Runner WASM
migration (Stages 0–4), run against
[swift-wasm-review-checklist.md](swift-wasm-review-checklist.md). Scope: the
`RunnerCore` leaf (compiled both natively and to Embedded-Swift wasm), the
`wasm/` bridge sub-package (`Sources/RunnerWasm/main.swift`), the build script,
and the vendored artifact under `Public/runner-wasm/`.

## 1. Summary

No **blocking** issues. The migration is well-scoped: all grading logic lives in
`RunnerCore` (Foundation-free, dependency-free), shared byte-for-byte between the
native worker and the browser wasm, with a thin manual JavaScriptKit bridge. The
release wasm builds cleanly (no warnings), links, and is exercised end-to-end in
Node (real-wasm cross-runner contract test) and in a real browser (Preview smoke
run). Four **concerns**, all pre-existing design trade-offs or follow-up
optimizations, none gating: dynamic JS interop (forced — BridgeJS is incompatible
with Embedded Swift), `wasm-opt` not run, no per-PR wasm-SDK build in CI
(deliberate — the artifact is vendored like Pyodide), and no `swift test` under a
wasm runtime (mitigated by Node + browser tests of the real artifact).

## 2. Blocking

None.

## 3. Concerns

- ⚠️ **§5 JS interop is dynamic `JSObject` access, not BridgeJS.** The bridge
  (`wasm/Sources/RunnerWasm/main.swift`) uses manual `JSClosure` / `JSObject`
  marshalling. This is **required**: BridgeJS's macros are incompatible with
  Embedded Swift (documented in `wasm/Package.swift`). Mitigation: the boundary
  is small and the data is marshalled explicitly and type-checked at the edges
  (`parseSuiteItems`, `outcomesToJS`, `scriptOutput(from:)`), and the exported
  signatures are stable. Closures crossing the boundary (`scriptExists`, `run`)
  are non-escaping per call and released when `executeSuites` returns — no retain
  cycle. Acceptable.
- ⚠️ **§6 `wasm-opt` is not run** (`scripts/build-runner-wasm.sh`). The artifact
  is shipped as emitted by the PackageToJS `js` plugin. A `wasm-opt -Oz` pass
  would likely reclaim a portion of the binary. Follow-up optimization, not
  gating (the artifact is gzip-served and cached; 632 KB gzip is negligible next
  to the ~1.4 GB Pyodide it rides alongside).
- ⚠️ **§8 CI does not build against the wasm SDK per-PR.** Deliberate: the
  artifact is vendored (`Public/runner-wasm/`) exactly like Pyodide / CodeMirror,
  so contributors and CI need no wasm SDK. Mitigations: (a) `output-contract.test.mjs`
  loads and runs the **real vendored wasm** in CI's `browser-runner-tests` job;
  (b) the rule "rebuild when `RunnerCore` or the bridge changes" is documented;
  (c) the SDK is pinned (`swift-6.3.2-RELEASE_wasm-embedded`, matching the host
  toolchain in `.swift-version`).
- ⚠️ **§10 No `swift test` under a wasm runtime (WasmKit).** The Swift test suite
  runs on the host. Mitigation: the real vendored wasm is exercised in Node
  (`output-contract.test.mjs` asserts byte-identical interpretation vs the shared
  fixture, i.e. vs the worker) and in a real browser (Preview smoke run covering
  the `fetch`-load + async event-loop boundary). The grading logic itself is also
  covered host-side by `SuiteExecutionTests` / `OutputContractTests`.

## 4. Passed

- ✅ **§1 Compilation mode.** Embedded Swift for the browser (`_wasm-embedded`
  SDK; `.enableExperimentalFeature("Extern")`). The shared/native boundary is
  clean: `RunnerCore`'s `Codable` conformances are gated `#if !hasFeature(Embedded)`
  so the embedded build carries no reflection-based coding; no `Any`, existentials,
  or `Mirror` in `RunnerCore` or the bridge.
- ✅ **§2 Platform conditionals.** `RunnerCore` has no filesystem/network/process
  assumptions (the substrate is injected via `ScriptExecutor`). The one needed
  conditional — `import _Concurrency` for async lowering — is present and
  commented (see swiftlang/swift#89492).
- ✅ **§3 Foundation usage.** `RunnerCore` imports no Foundation (verified). The
  hand-rolled `JSONLite` parser and string helpers replace `JSONDecoder` /
  `Double(String)` / `trimmingCharacters` so nothing pulls Foundation or
  `strtod`/libm into the wasm build.
- ✅ **§4 Concurrency.** `executeSuites` is `async` over a single cooperative
  executor (`JavaScriptEventLoop` on wasm). No `DispatchQueue` / `Thread` /
  `pthread` / `OperationQueue` / `Task.detached`; no reliance on
  `wasip1-threads`.
- ✅ **§7 Static linking.** No `dlopen` / plugin / runtime-loaded modules;
  everything links statically.
- ✅ **§9 Pointer / ABI.** No function-pointer ↔ data-pointer casts, no
  `MemoryLayout` arithmetic, no `withUnsafePointer` across the boundary. `Int`
  usage (`executionTimeMs`, `attemptNumber`, `points`) is value-range-safe on
  wasm32.
- ✅ **§11 Build hygiene.** Release build (`-c release`) succeeds with zero
  warnings (the `JSFunction`-deprecation warning was fixed by moving to the
  unified `JSObject`). Artifact path/naming follows the vendored convention.
- ✅ **§12 Documentation.** `docs/runner-wasm-migration.md` records the staged
  plan and the embedded-async `_Concurrency` requirement; the new bridge entry
  points are commented.

## 5. Skipped / N/A

- **§5 `.d.ts` drift** — N/A; the bridge declares no TypeScript surface (globals
  are documented in the bridge header comment).
- **§9 64-bit address-space assumptions** — N/A; no address arithmetic.

## 6. Binary size delta

| | raw | gzip |
|---|---|---|
| before Stage 4 (executeSuites dead-stripped) | 1,268,694 | 454,142 |
| after Stage 4 (grading loop + interpretation + event loop reachable) | 1,734,269 | 632,797 |
| delta | +465,575 (+37%) | +178,655 (+39%) |

The growth is **load-bearing, not bloat**: `executeSuites`, `interpretScriptOutput`,
`JSONLite`, and `JavaScriptEventLoop` are now reachable from the browser bridge
(previously dead-stripped), and they replace the hand-written JS loop +
interpretation that Stage 4 deleted from `browser-runner.js`. A `wasm-opt -Oz`
pass (concern §6) could reclaim part of this. In context — a vendored, gzipped,
cached asset sharing the page with ~1.4 GB of Pyodide — 632 KB gzip is immaterial.

> CI note: the build wasn't re-run from a clean SDK install for this review; the
> sizes are from the vendored artifact built by `scripts/build-runner-wasm.sh`
> with the pinned SDK, and the embedded compile + link were verified locally.
