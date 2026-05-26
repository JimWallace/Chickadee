#!/usr/bin/env bash
#
# Refreshes the vendored browser libraries served from Public/.
#
# Re-run whenever bumping Pyodide / jszip / CodeMirror versions.  Output paths:
#
#   Public/pyodide/              — the one canonical Pyodide distribution
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
#   - Chickadee's own browser paths (browser-runner.js, assignment-validate.js,
#     pyodide-worker.js, setup-edit.js, notebook.js).
# The version is NOT pinned here — it is DERIVED from the JupyterLite kernel
# (jupyterlite-pyodide-kernel in Tools/jupyterlite/requirements.txt, surfaced
# in the built bundle), because that kernel's bundled core wheels are
# ABI-locked to a specific Pyodide release.  One pin, one version, no drift.
# Run scripts/build-jupyterlite.sh BEFORE this script so the bundle exists.

set -euo pipefail

JSZIP_VERSION="3.10.1"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

public_pyodide="$repo_root/Public/pyodide"
public_vendor="$repo_root/Public/vendor"

# ── Derive the canonical Pyodide version from the JupyterLite kernel ───
# The pyodide-kernel extension hardcodes its Pyodide as the pyodideUrl
# default (cdn.jsdelivr.net/pyodide/vX.Y.Z).  That is the version its bundled
# core wheels were built against, so the vended distribution MUST equal it.
kernel_static="$repo_root/Public/jupyterlite/extensions/@jupyterlite/pyodide-kernel-extension/static"
if [[ ! -d "$kernel_static" ]]; then
    echo "error: JupyterLite bundle not found ($kernel_static)." >&2
    echo "       Run scripts/setup-jupyterlite.sh && scripts/build-jupyterlite.sh first —" >&2
    echo "       the Pyodide version is derived from the kernel that build bundles." >&2
    exit 1
fi
PYODIDE_VERSION="$(
    grep -rhoE 'cdn\.jsdelivr\.net/pyodide/v[0-9]+\.[0-9]+\.[0-9]+' "$kernel_static"/*.js 2>/dev/null \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -u | head -1
)"
if [[ -z "$PYODIDE_VERSION" ]]; then
    echo "error: could not derive the Pyodide version from $kernel_static." >&2
    exit 1
fi
echo "==> Canonical Pyodide version (derived from JupyterLite kernel): $PYODIDE_VERSION"

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

# Strip any wheel exceeding GitHub's 100 MiB per-file hard limit (push is
# rejected otherwise).  These are niche scientific packages we don't expect
# any Chickadee assignment to import; if one is genuinely needed, the
# alternative is Git LFS.  loadPackagesFromImports() surfaces a
# "package not found" error for a stripped wheel — the correct fail-fast
# behaviour vs. silently falling through to a CDN.  Done dynamically (not a
# hardcoded package list) so a Pyodide version bump that newly oversizes a
# package is handled, and WARNs loudly so an actually-needed one is noticed.
while IFS= read -r -d '' big; do
    echo "    WARNING: stripping oversized wheel (>100 MiB): $(basename "$big")" >&2
    rm -f "$big" "$big.metadata"
done < <(find "$public_pyodide" -name '*.whl' -size +100M -print0)

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
