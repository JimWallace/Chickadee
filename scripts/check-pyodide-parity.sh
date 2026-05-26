#!/usr/bin/env bash
#
# Pyodide parity guard.
#
# Asserts that the Pyodide distribution we vendor under Public/pyodide is the
# SAME version the embedded JupyterLite pyodide-kernel is pinned to.
#
# Why this exists
# ---------------
# The JupyterLite *editor* kernel and Chickadee's own browser paths
# (browser-runner grading, /validate, setup-edit) must run the identical
# Python runtime, served locally.  If the vendored Pyodide drifts from the
# version the kernel expects, two things break:
#
#   1. The kernel's bundled core wheels (pyodide_kernel, piplite, ipykernel)
#      are ABI-tagged for a specific Pyodide/Python release.  Pointing the
#      kernel at a mismatched vendored Pyodide makes them fail to import.
#   2. To dodge (1) the kernel silently falls back to loading Pyodide from
#      cdn.jsdelivr.net — which is exactly the latent condition that turned
#      the #574 CSP cleanup into a student-facing outage (the CSP dropped the
#      CDN allowance while the editor still depended on it).
#
# Keeping the two versions locked together means the editor can always be
# served Pyodide locally, the CSP needs no third-party origin, and the
# environment a student authors in matches the one we grade in.
#
# This check reads only checked-in artifacts (no venv / rebuild needed), so it
# is cheap enough to run on every PR.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_JSON="$ROOT_DIR/Public/pyodide/package.json"
KERNEL_STATIC_DIR="$ROOT_DIR/Public/jupyterlite/extensions/@jupyterlite/pyodide-kernel-extension/static"

fail() {
  echo "pyodide-parity: FAIL — $1" >&2
  exit 1
}

[[ -f "$PKG_JSON" ]] || fail "vendored Pyodide package.json not found at $PKG_JSON (run scripts/setup-vendor.sh)"
[[ -d "$KERNEL_STATIC_DIR" ]] || fail "JupyterLite pyodide-kernel extension not found at $KERNEL_STATIC_DIR (run scripts/build-jupyterlite.sh)"

# Vendored Pyodide release version — package.json carries the true release
# version (the lock's info.version can read e.g. 0.28.0.dev0 because Pyodide's
# JS package and Python distribution use separate version streams).
VENDORED_VERSION="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('version',''))" "$PKG_JSON")"
[[ -n "$VENDORED_VERSION" ]] || fail "could not read version from $PKG_JSON"

# Version the kernel is pinned to — the jupyterlite-pyodide-kernel extension
# hardcodes its Pyodide as the pyodideUrl default (cdn.jsdelivr.net/pyodide/vX.Y.Z).
# This is the version its bundled core wheels were built against, so the
# vendored distribution MUST match it whether or not pyodideUrl is overridden.
KERNEL_VERSION="$(
  grep -rhoE 'cdn\.jsdelivr\.net/pyodide/v[0-9]+\.[0-9]+\.[0-9]+' "$KERNEL_STATIC_DIR"/*.js 2>/dev/null \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -u | head -1
)"
[[ -n "$KERNEL_VERSION" ]] || fail "could not determine the kernel's pinned Pyodide version from $KERNEL_STATIC_DIR"

if [[ "$VENDORED_VERSION" != "$KERNEL_VERSION" ]]; then
  {
    echo "pyodide-parity: FAIL — vendored Pyodide ($VENDORED_VERSION) != kernel-pinned Pyodide ($KERNEL_VERSION)."
    echo
    echo "  The JupyterLite editor kernel expects Pyodide $KERNEL_VERSION but Public/pyodide"
    echo "  vendors $VENDORED_VERSION.  Until these match, the editor kernel cannot be served the"
    echo "  vendored Pyodide and falls back to the CDN (the #574 outage condition)."
    echo
    echo "  Fix: set PYODIDE_VERSION=$KERNEL_VERSION in scripts/setup-vendor.sh and re-run it,"
    echo "  or pin a jupyterlite-pyodide-kernel in Tools/jupyterlite/requirements.txt whose"
    echo "  Pyodide matches the vendored version."
  } >&2
  exit 1
fi

echo "pyodide-parity: OK — vendored and kernel-pinned Pyodide both at $VENDORED_VERSION"
