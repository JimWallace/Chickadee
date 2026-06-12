#!/usr/bin/env bash
#
# Build the RunnerCore wasm bridge (wasm/ sub-package) and vendor a
# self-contained, no-CDN browser artifact under Public/runner-wasm/.
#
# RunnerCore is the substrate-free grading logic shared with the native worker.
# This compiles it (plus the manual JavaScriptKit bridge in
# wasm/Sources/RunnerWasm/main.swift) to wasm with the EMBEDDED Swift SDK — a
# ~350 KB-gzipped artifact, ~60x smaller than the standard wasm runtime — so the
# browser runner can call the SAME extraction code instead of a hand-written JS
# copy.
#
# Prerequisites (one-time, see docs/runner-wasm-migration.md):
#   * Swift toolchain matching the wasm SDK (6.3.2 — see .swift-version)
#   * The Embedded Swift WebAssembly SDK installed and named via SWIFT_WASM_SDK
#     (defaults to swift-6.3.2-RELEASE_wasm-embedded).
#   * Node + npx (for esbuild) to bundle the WASI shim locally (no CDN: FIPPA).
#
# Output (checked in, like Public/pyodide / Public/vendor — CI and contributors
# need no wasm SDK; rebuild only when RunnerCore or the bridge changes):
#   Public/runner-wasm/runner-core.js   — self-contained ESM loader (init/exports)
#   Public/runner-wasm/RunnerWasm.wasm  — the embedded wasm module
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sdk="${SWIFT_WASM_SDK:-swift-6.3.2-RELEASE_wasm-embedded}"
out_dir="$repo_root/Public/runner-wasm"

cd "$repo_root/wasm"

# NOTE: do NOT set JAVASCRIPTKIT_EXPERIMENTAL_EMBEDDED_WASM here. The embedded
# wasm SDK already forces Embedded mode globally, so JavaScriptKit +
# JavaScriptEventLoop compile embedded without it — and setting it flips the
# PackageToJS output from the required WASI *reactor* model (exported
# `_initialize`) to a *command* (`_start`), which JavaScriptKit's runtime
# rejects ("supports only WASI reactor ABI").

echo "Building RunnerWasm (Embedded Swift, SDK: $sdk)…"
swift package --swift-sdk "$sdk" js -c release

pkg=".build/plugins/PackageToJS/outputs/Package"

echo "Bundling a self-contained, no-CDN browser ESM with esbuild…"
( cd "$pkg" && npm install --silent )

rm -rf "$out_dir"
mkdir -p "$out_dir"
npx --yes esbuild "$pkg/index.js" --bundle --format=esm --outfile="$out_dir/runner-core.js"

unopt_size=$(wc -c < "$pkg/RunnerWasm.wasm")

# Optimize for size — this is a browser-delivered artifact, so -Oz (size) over
# -O (speed). wasm-opt ships with binaryen; run it via npx so no system install
# is needed (same mechanism as esbuild above). If it's unavailable (offline),
# fall back to the unoptimized module with a warning — the build still produces
# a correct, working artifact.
opt_wasm="$out_dir/.RunnerWasm.opt.wasm"
if npx --yes wasm-opt --version >/dev/null 2>&1; then
    echo "Optimizing with wasm-opt -Oz --converge --strip-producers…"
    # --converge: re-run passes to fixpoint for a little extra size.
    # --strip-producers: drop the toolchain "producers" metadata section (the
    # exported grading functions the JS loader calls are unaffected).
    npx --yes wasm-opt -Oz --converge --strip-producers "$pkg/RunnerWasm.wasm" -o "$opt_wasm"
else
    echo "WARNING: wasm-opt unavailable — vendoring the UNOPTIMIZED module."
    cp "$pkg/RunnerWasm.wasm" "$opt_wasm"
fi
opt_size=$(wc -c < "$opt_wasm")

# Content-hash the filename so the artifact can be cached immutably: new bytes →
# new filename → clean cache bust; unchanged bytes → identical filename → served
# from cache effectively forever (see RunnerWasmCacheMiddleware).
hash=$(shasum -a 256 "$opt_wasm" | cut -c1-12)
wasm_name="RunnerWasm.${hash}.wasm"
mv "$opt_wasm" "$out_dir/$wasm_name"

# Point the generated loader at the hashed filename (it fetches
# `new URL("RunnerWasm.wasm", import.meta.url)`). The loader keeps its stable
# name and is served must-revalidate, so it always resolves to the current hash.
sed -i.bak "s/RunnerWasm\.wasm/${wasm_name}/g" "$out_dir/runner-core.js"
rm -f "$out_dir/runner-core.js.bak"

gzip_size=$(gzip -9 -c "$out_dir/$wasm_name" | wc -c)
if command -v brotli >/dev/null 2>&1; then
    brotli_size="$(brotli -q 11 -c "$out_dir/$wasm_name" | wc -c) bytes"
else
    brotli_size="(brotli not installed — install binaryen/brotli to measure)"
fi

echo "Done. Vendored:"
echo "  $out_dir/runner-core.js        ($(wc -c < "$out_dir/runner-core.js") bytes, loader)"
echo "  $out_dir/$wasm_name  (content-hashed)"
echo ""
echo "Wasm size:"
echo "  unoptimized:  ${unopt_size} bytes"
echo "  wasm-opt -Oz: ${opt_size} bytes"
echo "  gzip -9:      ${gzip_size} bytes"
echo "  brotli -q11:  ${brotli_size}"
echo ""
echo "Size budget:"
"$repo_root/scripts/check-runner-wasm-size.sh" || true
