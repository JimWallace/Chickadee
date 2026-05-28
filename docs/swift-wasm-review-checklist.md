# Swift → Wasm PR Review Checklist

You are reviewing a Swift PR that targets WebAssembly. For each item below, inspect the diff and the surrounding code, then report findings as one of: ✅ pass, ⚠️ concern (with line refs), or ❌ violation (with line refs and a suggested fix). Skip items that don't apply, but say so explicitly — don't silently drop them.

Be concrete. Cite file paths and line numbers. If a check requires running a build or inspecting output, do it.

---

## 1. Compilation mode

- [ ] Is this targeting **Embedded Swift** (browser) or **standard Swift/WASI** (server/edge)? Find the evidence in `Package.swift`, build scripts, or CI config.
- [ ] Does the code match the mode? Embedded Swift code must not use `Any`, existentials with unconstrained protocols, runtime reflection (`Mirror`), or features that require the full runtime.
- [ ] If the PR mixes modes (e.g. shared library used by both an embedded browser target and a WASI server target), is the boundary clean? No conditional `Any` usage that compiles in one mode and not the other.

## 2. Platform conditionals

- [ ] All platform-specific code is gated with `#if os(WASI)` or `#if arch(wasm32)` as appropriate. No silent assumptions that filesystem, network, threading, or process APIs exist.
- [ ] Imports that don't exist on Wasm (Darwin, Glibc specifics, Dispatch in some modes) are conditionally imported.
- [ ] Stubs for unavailable functionality fail loudly (precondition or typed throw), not silently. A no-op fallback on Wasm is a bug waiting to happen in production.

## 3. Foundation usage

- [ ] Is Foundation actually needed? Each `import Foundation` should justify its weight. Prefer swift-stdlib types, swift-collections, swift-algorithms, or Wasm-friendly community packages.
- [ ] Flag specific heavy/problematic Foundation APIs: `FileManager`, `URLSession`, `Process`, `Timer`, `RunLoop`, `NotificationCenter`, anything KVO-shaped.
- [ ] Check if any `Date`/`URL`/`Data` usage can be swapped for lighter alternatives in hot paths.

## 4. Concurrency and threading

- [ ] No assumption that `wasm32-unknown-wasip1-threads` is available unless the project's SDK target explicitly says so. Confirm against the SDK ID in build config.
- [ ] Swift Concurrency (`async`/`await`, actors, `Task`) usage is fine on Wasm but verify there's no implicit reliance on multiple cooperative threads.
- [ ] No `DispatchQueue.global().async`, `Thread`, `pthread_*`, or `OperationQueue` in code paths that run on Wasm.
- [ ] No `Task.detached` patterns that assume true parallelism.

## 5. JS interop (if browser-targeted)

- [ ] New JS boundary code uses **BridgeJS** (macros + generated glue), not raw `JSObject`/`JSValue` dynamic access. Dynamic access is acceptable for one-offs or prototypes; flag it in production paths.
- [ ] BridgeJS-exported Swift functions have stable, type-safe signatures. No `Any`, no untyped dictionaries crossing the boundary.
- [ ] JS imports declared in Swift match the actual JS surface area. No drift between the `.d.ts` (if used) and the Swift declarations.
- [ ] Closures passed to JS have a documented lifetime story. Retain cycles across the Swift↔JS boundary are easy to introduce and hard to debug.

## 6. Binary size

- [ ] Build the release Wasm binary and report its size before and after `wasm-opt -O` (or `-Oz` for size-critical targets). If the build pipeline doesn't run `wasm-opt`, flag it.
- [ ] Compare against the size before this PR (use the parent commit). Significant unexplained growth (>10%) needs justification in the PR description.
- [ ] Check for accidentally pulled-in heavy dependencies. Run `swift package show-dependencies` and compare to the previous state.
- [ ] No generic explosion: highly generic public APIs with many concrete instantiations balloon Embedded Swift binaries. Flag new generic surface area.

## 7. Static linking constraints

- [ ] No assumption of dynamic linking (`dlopen`, plugin architectures, runtime-loaded modules). Wasm dynamic linking is not specified yet.
- [ ] Module boundaries make sense given everything links statically — no abstractions that only pay off with dynamic dispatch across module boundaries.

## 8. SwiftPM and SDK config

- [ ] `Package.swift` platform constraints don't exclude Wasm targets accidentally. Check `.platforms` and `.target` conditions.
- [ ] CI builds against a Wasm SDK on every PR, not just on a nightly. The SDK version is pinned (e.g. `swift-6.3-RELEASE_wasm` or `_wasm-embedded`), not floating.
- [ ] No `swift sdk` invocations using snapshot toolchains in release pipelines without a deliberate reason.

## 9. Pointer and ABI gotchas

- [ ] No code that assumes function pointers and data pointers share an address space. On Wasm they don't — they live in separate tables. Cast operations between `UnsafePointer<Void>` and function pointers are a red flag.
- [ ] No `MemoryLayout` arithmetic that assumes a 64-bit address space. wasm32 means `Int` is 32-bit for pointer-sized math.
- [ ] Anything using `withUnsafePointer` across an FFI/JS boundary has a clear memory ownership contract.

## 10. Testing

- [ ] Tests run under the Wasm SDK, not just the host toolchain. A green `swift test` on macOS proves nothing about Wasm behaviour.
- [ ] If using WasmKit or another runtime for testing, the runtime version is pinned.
- [ ] Browser-facing code has at least smoke-level JS-side tests (does the exported function actually call from JS, does the imported JS function actually round-trip).

## 11. Build hygiene

- [ ] No build warnings introduced for the Wasm target. Warnings for the macOS target that don't appear on Wasm (or vice versa) are worth investigating.
- [ ] Release build succeeds with optimizations on (`-c release`), not just debug.
- [ ] Generated `.wasm` artifact path and naming follow whatever convention the project already uses.

## 12. Documentation

- [ ] If this PR adds a new Wasm-targeted module or significantly changes the JS boundary, the README or relevant docs are updated.
- [ ] Any new platform conditionals are commented with a one-line "why" — future-me will not remember.

---

## Final report format

Produce the report as:

1. **Summary** — one paragraph, blocking issues vs nits.
2. **Blocking** — ❌ items, with file:line and suggested fix.
3. **Concerns** — ⚠️ items, with file:line and rationale.
4. **Passed** — ✅ items, one line each.
5. **Skipped / N/A** — with a brief reason.
6. **Binary size delta** — before/after numbers if you ran the build.

If you couldn't run the build (no SDK installed, network restricted, etc.), say so at the top and proceed with static analysis only.
