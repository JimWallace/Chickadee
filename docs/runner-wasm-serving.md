# Browser wasm runner — caching & size discipline

How the Embedded-Swift wasm runner is optimized, cached, and kept small. This is
the "ship it once per term, serve from cache thereafter, and don't let it
silently balloon" pass. Companion to [runner-wasm-migration.md](runner-wasm-migration.md)
and [runner-wasm-review.md](runner-wasm-review.md).

## 1. Sizes

Reported by `scripts/build-runner-wasm.sh` on every re-vendor:

| stage | bytes |
|---|---|
| unoptimized | 1,742,845 |
| `wasm-opt -Oz` | 1,522,732 |
| gzip -9 | 493,864 |
| **brotli -q11 (on the wire)** | **403,345 (~394 KB)** |

`wasm-opt -Oz` runs in the build via `npx` (binaryen — same no-install mechanism
as esbuild); if unavailable it falls back to the unoptimized module with a
warning. `-Oz` (size) not `-O` (speed), since this is browser-delivered.

## 2. Caching

The artifact is **content-hashed** at build time — `RunnerWasm.<hash>.wasm` —
so the bytes behind a URL never change. Headers are set at the **Vapor origin**
by `RunnerWasmCacheMiddleware` (registered just outside `FileMiddleware`); the
production nginx reverse proxy passes `/` straight through, so they reach the
browser unmodified. Verified empirically with `curl -I` against a running server:

```
GET /runner-wasm/RunnerWasm.<hash>.wasm
  content-type: application/wasm
  cache-control: public, max-age=31536000, immutable

GET /runner-wasm/runner-core.js
  content-type: application/javascript
  cache-control: no-cache
```

- The hashed **`.wasm`** is immutable for a year → downloaded once, then served
  from cache until a re-vendor changes the bytes (≈ once per term). `immutable`
  means the browser won't even revalidate on reload.
- The **loader** (`runner-core.js`) keeps a stable name and embeds the current
  hash, so it's `no-cache` (revalidate-before-use → cheap 304 via FileMiddleware's
  ETag) and always resolves to the current wasm. `browser-runner.js` itself is
  already busted per-release by `?v=#appVersion()` in `notebook.leaf`.
- `application/wasm` is required for `WebAssembly.instantiateStreaming`; the
  middleware forces it so a future MIME-map change can't silently disable
  streaming.

## 3. Streaming instantiation

The vendored loader already uses `WebAssembly.instantiateStreaming` (compiles
during download) with a `WebAssembly.instantiate` fallback (PackageToJS runtime,
`runner-core.js`). Confirmed present; no change needed.

## 4. Size budget

`scripts/check-runner-wasm-size.sh` runs in the build and in CI (format-lint
job). It gates on **gzip** (universally available, incl. CI runners without
binaryen) and additionally reports **brotli**:

- **budget 528 KB gzip** (warn) — creep check.
- **ceiling 672 KB gzip** (fail) — ~35 % over today's size; trips only on a true
  balloon (the signature of Embedded-Swift generic-specialization explosion).
- prints the **delta from `runner-size-baseline.txt`** (currently 493,864) so a
  disproportionate jump is visible in the build log. Update the baseline when a
  re-vendor legitimately changes the size.

Current: gzip 493,864 — **OK, within budget.** (The audit's 300 KB brotli target
isn't realistic for a module that legitimately bundles the Embedded Swift
runtime + JavaScriptKit + JavaScriptEventLoop; 394 KB brotli is the floor. The
gate is set to catch a *balloon*, which is the real risk, not to chase an
unreachable absolute.)

## 5. Size audit (bloat vectors)

| vector | finding | action |
|---|---|---|
| Heavily-generic public APIs | only `executeSuites(executor: some ScriptExecutor)`; the wasm build instantiates it for exactly one concrete type (`BrowserScriptExecutor`) → one monomorphization | watch (would only grow if a second wasm-side conformance is added) |
| Foundation pull-in | **none** in `Sources/RunnerCore/` or `wasm/Sources/` (`rg 'import Foundation'` clean) — `JSONLite` + hand-rolled string/number helpers keep it out | none |
| Large static data | none in the wasm graph; the embedded `test_runtime.py` blobs live in `Sources/Worker/` (native only) | none |
| Unused dependencies | wasm graph = `RunnerCore` (leaf), `JavaScriptKit`, `JavaScriptEventLoop` — all used | none |

## 6. Recommendation

**Ship-ready.** Optimized (`wasm-opt -Oz`), content-hashed + immutably cached at
the origin (verified), streaming instantiation confirmed, and a CI size guardrail
in place. The dev labs already grade with reasonable feedback. No act-now bloat
vectors; the single generic is a watch-item only.

One thing the repo can't set for you: if UW ever fronts the app with a CDN/proxy
that **strips or overrides** `Cache-Control`/`Content-Type`, replicate the two
header rules above at that layer. Today's nginx (`deploy/nginx.conf`) is a
pass-through `proxy_pass`, so the origin headers already win.
