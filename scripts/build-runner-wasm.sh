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

echo "Building RunnerWasm (Embedded Swift, SDK: $sdk)…"
swift package --swift-sdk "$sdk" js -c release

pkg=".build/plugins/PackageToJS/outputs/Package"

echo "Bundling a self-contained, no-CDN browser ESM with esbuild…"
( cd "$pkg" && npm install --silent )

rm -rf "$out_dir"
mkdir -p "$out_dir"
npx --yes esbuild "$pkg/index.js" --bundle --format=esm --outfile="$out_dir/runner-core.js"
cp "$pkg/RunnerWasm.wasm" "$out_dir/RunnerWasm.wasm"

echo "Done. Vendored:"
echo "  $out_dir/runner-core.js   ($(wc -c < "$out_dir/runner-core.js") bytes)"
echo "  $out_dir/RunnerWasm.wasm  ($(wc -c < "$out_dir/RunnerWasm.wasm") bytes)"
