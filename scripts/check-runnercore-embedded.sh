#!/usr/bin/env bash
#
# Compile RunnerCore as Embedded Swift on the HOST, with no wasm SDK.
#
# RunnerCore is compiled two ways: natively into the worker, and as Embedded
# Swift to WebAssembly for the browser grader. Only the second build enforces
# Embedded Swift's restrictions (no Foundation, no `Mirror`, no
# `String.contains(String)`, no `Codable`, …), and until this guard it ran in
# exactly one place: the runner-wasm-vendor workflow, on `main`, AFTER merge.
# A PR that made RunnerCore un-embeddable was green everywhere, merged, and
# then broke the vendor job — while the browser kept grading with the last
# artifact that built. The migration notes list "no per-PR wasm-SDK build in
# CI" as an accepted gap; this closes it without the SDK.
#
# The host toolchain ships an Embedded Swift standard library for its own
# triple, so `-enable-experimental-feature Embedded` compiles RunnerCore here in
# a few seconds. Every restriction that matters is diagnosed at compile time
# (availability, existential limits, unsupported conformances), so a host
# compile catches what the wasm compile would — the module is not linked or
# run, which is fine: link-time surprises are the runtime's, not RunnerCore's,
# and the vendor job still builds the real artifact.
#
# It compiles RunnerCore ALONE, on purpose: the wasm graph is RunnerCore plus
# JavaScriptKit, and JavaScriptKit only builds against the wasm SDK. The bridge
# in wasm/Sources is therefore not covered here; it is small and changes rarely.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

sources=()
while IFS= read -r f; do sources+=("$f"); done < <(find Sources/RunnerCore -name '*.swift' | LC_ALL=C sort)

if swiftc -c -O -wmo -parse-as-library -module-name RunnerCore \
    -enable-experimental-feature Embedded \
    "${sources[@]}" -o "$out/RunnerCore.o" 2>"$out/stderr"; then
    echo "  OK: RunnerCore compiles as Embedded Swift (${#sources[@]} files)."
    exit 0
fi

echo "  FAIL: RunnerCore does not compile as Embedded Swift."
echo "        The browser wasm build (runner-wasm-vendor) would break on main."
echo "        Diagnostics:"
grep -E "error:" "$out/stderr" | sed -E 's/\x1b\[[0-9;]*m//g' | sort -u | sed 's/^/          /'
exit 1
