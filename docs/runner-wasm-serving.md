# Browser wasm runner — caching & size discipline

How the Embedded-Swift wasm runner is optimized, cached, and kept small. This is
the "ship it once per term, serve from cache thereafter, and don't let it
silently balloon" pass. Companion to [runner-wasm-migration.md](runner-wasm-migration.md)
and [runner-wasm-review.md](archive/runner-wasm-review.md).

## 1. Sizes

Reported by `scripts/build-runner-wasm.sh` on every re-vendor:

| stage | bytes |
|---|---|
| as linked (`-Osize`, `-g`) | ~1.7 MB |
| `wasm-opt -Oz --strip-debug` | 281,578 |
| gzip -9 | 138,181 |

Plus the loader, `runner-core.js`: 126 KB raw / 21 KB gzip, of which ~40 KB
raw is the BridgeJS glue (struct codecs for the typed exports) and the rest
the JavaScriptKit runtime and the WASI shim.

`wasm-opt -Oz --strip-debug` runs in the build via `npx` (binaryen — same
no-install mechanism as esbuild); if unavailable it falls back to the
unoptimized, unstripped module with a warning, and that module fails the size
ceiling. `-Oz` (size) not `-O` (speed), since this is browser-delivered.

**Until Swift 6.4 the table above read 1,742,845 → 1,522,732 → 493,864 gzip,
and ~80 % of that was DWARF.** The release build links with `-g`; the
PackageToJS plugin's "Stripping DWARF debug info" step runs through a
`wasm-opt` it looks up on `PATH`, which the vendor job's runner does not have,
so it warned and copied the module unstripped; and the build script's own
`wasm-opt -Oz` kept the `.debug_*` custom sections because nothing asked it to
drop them. The three facts were each individually documented and jointly
invisible: the size guard measured the whole file, so a module that was 1.2 MB
of debug data read as "within budget". Section-by-section it was
`.debug_info` 407 KB, `.debug_names` 294 KB, `.debug_str` 202 KB,
`.debug_line`/`.debug_ranges`/`.debug_loc` ~115 KB each, `.debug_abbrev` 45 KB
— against 207 KB of code and 64 KB of data. The remaining ~270 KB is, by
symbol: the Swift standard library's String/Unicode machinery ~94 KB (the
grapheme-stride and NFC-normalisation paths that `Character` iteration and
`String ==` pull in), RunnerCore ~68 KB, wasi-libc and the Swift runtime
~43 KB (`printf_core` 9 KB, `dlmalloc` 7 KB), JavaScriptKit ~31 KB, the
bridge ~6 KB. See `docs/runner-wasm-swift-6-4-review.md` for the measurements
and what each remaining slice would cost to remove.

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

- **budget 144 KB gzip** (warn) — creep check.
- **ceiling 176 KB gzip** (fail) — ~35 % over today's size; trips on an
  unstripped module first (the likeliest cause: `wasm-opt` missing when the
  vendor job ran), and otherwise on a true balloon (the signature of
  Embedded-Swift generic-specialization explosion).
- prints the **delta from `runner-size-baseline.txt`** (currently 138,181) so a
  disproportionate jump is visible in the build log. Update the baseline when a
  re-vendor legitimately changes the size.

Current: gzip 138,181 — **OK, within budget.** (The audit's 300 KB brotli
target, once dismissed as unreachable for a module bundling the Embedded Swift
runtime + JavaScriptKit + JavaScriptEventLoop, was never the module's floor;
it was the DWARF's. The gate stays set to catch a *balloon*, which is the real
risk, not to chase an absolute.)

## 5. Size audit (bloat vectors)

| vector | finding | action |
|---|---|---|
| Heavily-generic public APIs | only `executeSuites(executor: some ScriptExecutor)`; the wasm build instantiates it for exactly one concrete type (`BrowserScriptExecutor`) → one monomorphization | watch (would only grow if a second wasm-side conformance is added) |
| Foundation pull-in | **none** in `Sources/RunnerCore/` or `wasm/Sources/` (`rg 'import Foundation'` clean) — `JSONLite` + hand-rolled string/number helpers keep it out | none |
| Large static data | none in the wasm graph; the embedded `test_runtime.py` blobs live in `Sources/Worker/` (native only) | none |
| Unused dependencies | wasm graph = `RunnerCore` (leaf), `JavaScriptKit`, `JavaScriptEventLoop` — all used | none |
| Debug info | **was the whole story** — DWARF from the `-g` release link, kept because the plugin's strip step needs a `wasm-opt` on `PATH` and the script's `wasm-opt` call had no `--strip-debug`; ~1.2 MB of a ~1.5 MB module, for every re-vendor before Swift 6.4 | stripped in the build; the size ceiling now sits below an unstripped module |

## 6. Recommendation

**Ship-ready.** Optimized (`wasm-opt -Oz`), content-hashed + immutably cached at
the origin (verified), streaming instantiation confirmed, and a CI size guardrail
in place. The dev labs already grade with reasonable feedback. No act-now bloat
vectors; the single generic is a watch-item only.

One thing the repo can't set for you: if UW ever fronts the app with a CDN/proxy
that **strips or overrides** `Cache-Control`/`Content-Type`, replicate the two
header rules above at that layer. Today's nginx (`deploy/nginx.conf`) is a
pass-through `proxy_pass`, so the origin headers already win.
