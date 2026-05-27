#!/usr/bin/env bash
#
# Build the RunnerCore wasm bridge (wasm/ sub-package) and stage the artifact
# under Public/runner-wasm/.
#
# RunnerCore is the substrate-free grading logic shared with the native worker.
# This script compiles it (plus the thin JavaScriptKit @JS bridge in
# wasm/Sources/RunnerWasm/) to wasm via the PackageToJS plugin, so the browser
# runner can call the SAME extraction code instead of a hand-written JS copy.
#
# Prerequisites (one-time, see docs):
#   * Swift toolchain matching the wasm SDK (currently 6.3.2 — see .swift-version)
#   * The Swift WebAssembly SDK installed:
#       swift sdk install <swift-6.3.2 wasm artifactbundle url> --checksum <sum>
#     and exported as SWIFT_WASM_SDK (defaults to swift-6.3.2-RELEASE_wasm).
#
# The vendored output is checked in (like Public/pyodide, Public/vendor) so CI
# and contributors don't need the wasm SDK; rebuild only when RunnerCore or the
# bridge changes.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sdk="${SWIFT_WASM_SDK:-swift-6.3.2-RELEASE_wasm}"
out_dir="$repo_root/Public/runner-wasm"

cd "$repo_root/wasm"

echo "Building RunnerWasm for wasm (SDK: $sdk)…"
swift package --swift-sdk "$sdk" js

pkg=".build/plugins/PackageToJS/outputs/Package"

echo "Staging artifact into $out_dir …"
rm -rf "$out_dir"
mkdir -p "$out_dir"
cp -R "$pkg/." "$out_dir/"

echo "Done. Vendored RunnerCore wasm bridge at Public/runner-wasm/."
echo "NOTE: browser wiring (esbuild-bundle the wasi shim for no-CDN load + load"
echo "      from browser-runner.js) is the next step and not done by this script yet."
