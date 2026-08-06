#!/usr/bin/env bash
#
# Refreshes the vendored browser libraries served from Public/.
#
# Re-run whenever bumping Pyodide / jszip / CodeMirror versions.  Output paths:
#
#   Public/vendor/jszip.min.js   — jszip $JSZIP_VERSION (used by browser-runner)
#   Public/vendor/codemirror.js  — bundled ESM, see Tools/vendor/codemirror-entry.js
#
# Public/pyodide and Public/vendor are checked in (~1.4 GB on disk for
# Pyodide; the git pack is ~300 MB).  This mirrors how Public/jupyterlite
# is handled and matches CLAUDE.md's "Source-of-truth ... rebuild" pattern.
# Every contributor and every CI runner gets the same bytes without a
# network fetch at build time, and we don't leak student IPs to
# cdn.jsdelivr.net / esm.sh on page load.
#
# SINGLE CANONICAL PYODIDE.  There is exactly one vended Pyodide, served at
# /pyodide, and BOTH consumers load it:
#   - the JupyterLite editor kernel (via pyodideUrl in
#     Tools/jupyterlite/jupyter-lite.json), and
#   - Chickadee's own browser paths (browser-runner.js, grading-worker.js,
#     assignment-validate.js, pyodide-worker.js, setup-edit.js, notebook.js).
# The version is NOT pinned here — it is DERIVED from the JupyterLite kernel
# (jupyterlite-pyodide-kernel in Tools/jupyterlite/requirements.txt, surfaced
# in the built bundle), because that kernel's bundled core wheels are
# ABI-locked to a specific Pyodide release.  One pin, one version, no drift.
# Run scripts/build-jupyterlite.sh BEFORE this script so the bundle exists.

set -euo pipefail

JSZIP_VERSION="3.10.1"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

public_vendor="$repo_root/Public/vendor"

# ── Derive the canonical Pyodide version from the JupyterLite kernel ───
# ── jszip ─────────────────────────────────────────────────────────────
echo "==> Fetching jszip $JSZIP_VERSION"
mkdir -p "$public_vendor"
curl -fsSL \
    "https://cdn.jsdelivr.net/npm/jszip@${JSZIP_VERSION}/dist/jszip.min.js" \
    -o "$public_vendor/jszip.min.js"

# ── CodeMirror bundle ─────────────────────────────────────────────────
echo "==> Bundling CodeMirror via npm + esbuild"
cd "$repo_root/Tools/vendor"
npm install --silent --no-audit --no-fund
npx esbuild codemirror-entry.js \
    --bundle \
    --format=esm \
    --target=es2020 \
    --minify \
    --outfile="$public_vendor/codemirror.js"

# ── jupyter-iframe-commands host bridge ───────────────────────────────
# The parent-frame half of the iframe command bridge (comlink folded in).
# Pairs with the `jupyter-iframe-commands` labextension federated into the
# JupyterLite bundle (Tools/jupyterlite/requirements.txt).
echo "==> Bundling jupyter-iframe-commands host bridge via esbuild"
npx esbuild iframe-commands-host-entry.js \
    --bundle \
    --format=esm \
    --target=es2020 \
    --minify \
    --outfile="$public_vendor/iframe-commands-host.js"

# ── xeus kernel bootstrap (browser-graded R) ──────────────────────────
# The mambajs slice Public/r-grading-worker.js uses to unpack the vendored
# `chickadee-r` conda env into the kernel's emscripten filesystem. IIFE, not
# ESM: the grading worker is a classic worker (it needs importScripts for the
# kernel's emscripten glue). See Tools/vendor/xeus-bootstrap-entry.mjs for why
# this is built from npm source instead of reusing the federated
# @jupyterlite/xeus-extension chunks.
#
# untarjs ships its unpacking wasm as a bundler-resolved `import ... from
# './unpack.wasm'`. That default is only consulted when no locateWasm is
# supplied, and r-grading-worker.js always supplies one — so the import is
# dropped (--loader:.wasm=empty) and the wasm is vended explicitly instead,
# under a name that says which subsystem owns it.
echo "==> Bundling xeus kernel bootstrap via esbuild"
npx esbuild xeus-bootstrap-entry.mjs \
    --bundle \
    --format=iife \
    --target=es2020 \
    --minify \
    --loader:.wasm=empty \
    --outfile="$public_vendor/xeus-bootstrap.js"
cp node_modules/@emscripten-forge/untarjs/lib/unpack.wasm \
   "$public_vendor/xeus-unpack.wasm"

# Inject Chickadee's extra pure-Python wheels (nb_mypy + deps) that aren't in
# the upstream Pyodide distribution, so a re-vendor never silently drops them.
# Pinned + sha-verified; see Tools/vendor/pyodide-extra-packages.json.
python3 "$repo_root/scripts/add-pyodide-extras.py"

# Belt-and-suspenders: confirm the just-vended Pyodide matches the kernel.
# Since the version is derived from the kernel above this should always pass;
# it catches a stale Public/pyodide that wasn't actually rewritten.
"$repo_root/scripts/check-pyodide-parity.sh"

echo "==> Vendor refresh complete."
echo "    Public/pyodide/              $(du -sh "$public_pyodide" | cut -f1)"
echo "    Public/vendor/jszip.min.js   $(du -sh "$public_vendor/jszip.min.js" | cut -f1)"
echo "    Public/vendor/codemirror.js  $(du -sh "$public_vendor/codemirror.js" | cut -f1)"
echo "    Public/vendor/xeus-bootstrap.js $(du -sh "$public_vendor/xeus-bootstrap.js" | cut -f1)"
