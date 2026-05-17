#!/usr/bin/env bash
#
# Refreshes the vendored browser libraries served from Public/.
#
# Re-run whenever bumping Pyodide / jszip / CodeMirror versions in this
# script or in Tools/vendor/package.json.  Output paths:
#
#   Public/pyodide/              — full Pyodide v$PYODIDE_VERSION distribution
#   Public/vendor/jszip.min.js   — jszip $JSZIP_VERSION (used by browser-runner)
#   Public/vendor/codemirror.js  — bundled ESM, see Tools/vendor/codemirror-entry.js
#
# Public/pyodide and Public/vendor are checked in (~1.4 GB on disk for
# Pyodide; the git pack is ~300 MB).  This mirrors how Public/jupyterlite
# is handled and matches CLAUDE.md's "Source-of-truth ... rebuild" pattern.
# Every contributor and every CI runner gets the same bytes without a
# network fetch at build time, and we don't leak student IPs to
# cdn.jsdelivr.net / esm.sh on page load.

set -euo pipefail

PYODIDE_VERSION="0.27.0"
JSZIP_VERSION="3.10.1"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

public_pyodide="$repo_root/Public/pyodide"
public_vendor="$repo_root/Public/vendor"

# ── Pyodide ───────────────────────────────────────────────────────────
echo "==> Fetching Pyodide $PYODIDE_VERSION"
rm -rf "$public_pyodide"
mkdir -p "$public_pyodide"
tmp_pyodide="$(mktemp -d)"
trap 'rm -rf "$tmp_pyodide"' EXIT
curl -fsSL \
    "https://github.com/pyodide/pyodide/releases/download/${PYODIDE_VERSION}/pyodide-${PYODIDE_VERSION}.tar.bz2" \
    -o "$tmp_pyodide/pyodide.tar.bz2"
tar -xjf "$tmp_pyodide/pyodide.tar.bz2" -C "$tmp_pyodide"
cp -R "$tmp_pyodide/pyodide/." "$public_pyodide/"

# Strip wheels that exceed GitHub's 100 MB per-file hard limit.  Each
# entry here is a niche scientific package we don't expect any Chickadee
# assignment to ask students to import; if one is needed in future, the
# alternative is Git LFS.  loadPackagesFromImports() will surface a
# "package not found" error for these specific wheels, which is the
# correct fail-fast behaviour vs. silently falling through to a CDN.
rm -f "$public_pyodide"/python_flint-*.whl "$public_pyodide"/python_flint-*.whl.metadata

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

echo "==> Vendor refresh complete."
echo "    Public/pyodide/              $(du -sh "$public_pyodide" | cut -f1)"
echo "    Public/vendor/jszip.min.js   $(du -sh "$public_vendor/jszip.min.js" | cut -f1)"
echo "    Public/vendor/codemirror.js  $(du -sh "$public_vendor/codemirror.js" | cut -f1)"
