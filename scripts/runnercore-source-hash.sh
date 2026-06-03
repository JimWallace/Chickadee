#!/usr/bin/env bash
#
# Deterministic content hash of every input that determines the vendored
# browser wasm artifact (Public/runner-wasm/). The wasm is built from the shared
# RunnerCore grading core plus the wasm bridge; whenever any of those inputs
# change, the vendored artifact must be rebuilt or the in-browser grader runs
# stale logic against fresh source (the class of bug behind #801).
#
# `Public/runner-wasm/source.sha` records this hash at vendor time, and the
# `runner-wasm-vendor` workflow compares the two to decide whether a re-vendor
# is needed. Output: a single sha256 hex string on stdout.
#
# Note: this hashes the *inputs* (source), NOT the wasm bytes — the build is not
# guaranteed bit-reproducible (esbuild / wasm-opt versions), so we gate on
# source change and commit whatever bytes the build produces.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

{
    find Sources/RunnerCore -type f -name '*.swift'
    find wasm/Sources -type f -name '*.swift'
    printf '%s\n' \
        wasm/Package.swift \
        wasm/Package.resolved \
        scripts/build-runner-wasm.sh
} | LC_ALL=C sort -u | while IFS= read -r f; do
    [ -f "$f" ] || continue
    # filename + content hash, so a rename or an edit both change the digest
    printf '%s  %s\n' "$f" "$(shasum -a 256 "$f" | cut -d' ' -f1)"
done | shasum -a 256 | cut -d' ' -f1
