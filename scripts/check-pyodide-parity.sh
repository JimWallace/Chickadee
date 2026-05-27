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

# Extras + kernel-boot guard.
#
# Pyodide looks packages up by their PEP 503 canonical name (nb_mypy -> nb-mypy),
# so the lock KEY must be canonical.  Two failure modes this catches:
#   1. A re-vendor that forgot scripts/add-pyodide-extras.py silently drops
#      nb_mypy and disables editor type-checking.
#   2. A package the editor kernel loads EAGERLY at boot (loadPyodideOptions.
#      packages) isn't resolvable in the lock under its canonical name — then
#      loadPackage() throws "No known package" and the whole editor kernel dies
#      at boot (kernel-unhealthy / watchdog_timeout).  This is the regression
#      that shipped in v0.4.289: the lock keyed nb_mypy with an underscore while
#      the kernel requested it canonically.
EXTRAS_MANIFEST="$ROOT_DIR/Tools/vendor/pyodide-extra-packages.json"
LOCK_JSON="$ROOT_DIR/Public/pyodide/pyodide-lock.json"
KERNEL_CONFIG="$ROOT_DIR/Public/jupyterlite/jupyter-lite.json"
python3 - "$EXTRAS_MANIFEST" "$LOCK_JSON" "$KERNEL_CONFIG" <<'PY'
import json, os, re, sys

def canon(name):
    return re.sub(r"[-_.]+", "-", name).lower()

extras_path, lock_path, kernel_cfg_path = sys.argv[1], sys.argv[2], sys.argv[3]
lock_keys = set(json.load(open(lock_path))["packages"])

if os.path.exists(extras_path):
    manifest = json.load(open(extras_path))["packages"]
    missing = [p["name"] for p in manifest if canon(p["name"]) not in lock_keys]
    if missing:
        print(f"pyodide-parity: FAIL — extras missing from lock (by canonical name): {missing}", file=sys.stderr)
        print("  Run scripts/add-pyodide-extras.py (or scripts/setup-vendor.sh) to restore them.", file=sys.stderr)
        sys.exit(1)
    print(f"pyodide-parity: OK — {len(manifest)} extra package(s) present in lock")

if os.path.exists(kernel_cfg_path):
    cfg = json.load(open(kernel_cfg_path))
    # litePluginSettings lives under jupyter-config-data in the built config.
    settings = (cfg.get("jupyter-config-data") or cfg).get("litePluginSettings") or {}
    kernel = settings.get("@jupyterlite/pyodide-kernel-extension:kernel") or {}
    boot_pkgs = ((kernel.get("loadPyodideOptions") or {}).get("packages")) or []
    unresolved = [p for p in boot_pkgs if canon(p) not in lock_keys]
    if unresolved:
        print(f"pyodide-parity: FAIL — kernel boot packages not resolvable in lock: {unresolved}", file=sys.stderr)
        print("  Each loadPyodideOptions.packages entry must match a canonical key in pyodide-lock.json;", file=sys.stderr)
        print("  the kernel loads them eagerly, so an unresolved name kills the editor kernel at boot.", file=sys.stderr)
        sys.exit(1)
    print(f"pyodide-parity: OK — {len(boot_pkgs)} kernel boot package(s) resolve in lock")
PY
