#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${1:-$ROOT_DIR/Public/jupyterlite}"
CONFIG_PATH="$BUILD_DIR/jupyter-lite.json"

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "missing config: $CONFIG_PATH" >&2
  exit 1
fi

python3 - "$CONFIG_PATH" "$BUILD_DIR" <<'PY'
import json
import pathlib
import sys

config_path = pathlib.Path(sys.argv[1])
build_dir = pathlib.Path(sys.argv[2])
cfg = json.loads(config_path.read_text())
data = cfg.get("jupyter-config-data", {})

def fail(message: str) -> None:
    print(message, file=sys.stderr)
    sys.exit(1)

if data.get("defaultKernelName") != "python":
    fail("defaultKernelName must be 'python'")

if data.get("fullLabextensionsUrl") != "./extensions":
    fail("fullLabextensionsUrl must be './extensions'")

federated = data.get("federated_extensions", [])
names = {entry.get("name") for entry in federated if isinstance(entry, dict)}
if "@jupyterlite/pyodide-kernel-extension" not in names:
    fail("pyodide federated extension missing from jupyter-lite.json")

piplite_urls = (
    data.get("litePluginSettings", {})
    .get("@jupyterlite/pyodide-kernel-extension:kernel", {})
    .get("pipliteUrls", [])
)
if not piplite_urls:
    fail("pipliteUrls missing from pyodide kernel settings")

# The editor kernel must load Pyodide from the one vended same-origin copy,
# not the jupyterlite-pyodide-kernel CDN default (cdn.jsdelivr.net).  This is
# the structural guard against the #574 regression class: if pyodideUrl is
# unset or external, the editor depends on a third-party origin (and on the
# CSP allowing it).  Keep it a same-origin absolute path (served from
# Public/pyodide).
pyodide_url = (
    data.get("litePluginSettings", {})
    .get("@jupyterlite/pyodide-kernel-extension:kernel", {})
    .get("pyodideUrl")
)
if not pyodide_url:
    fail(
        "pyodideUrl is unset — the editor kernel would fall back to the "
        "cdn.jsdelivr.net default. Pin it to the local /pyodide copy in "
        "Tools/jupyterlite/jupyter-lite.json."
    )
if "://" in pyodide_url or pyodide_url.startswith("//"):
    fail(f"pyodideUrl must be a same-origin local path, got external: {pyodide_url}")
if not pyodide_url.startswith("/"):
    fail(f"pyodideUrl must be a same-origin absolute path beginning with '/', got: {pyodide_url}")

remote_entry_dir = build_dir / "extensions" / "@jupyterlite" / "pyodide-kernel-extension" / "static"
remote_entries = [p for p in sorted(remote_entry_dir.glob("remoteEntry.*.js")) if not p.name.endswith(".map")]
if not remote_entries:
    fail(f"missing extension asset: no remoteEntry.*.js under {remote_entry_dir}")
if len(remote_entries) > 1:
    fail(f"unexpected: multiple remoteEntry.*.js under {remote_entry_dir}: {[p.name for p in remote_entries]}")

config_utils = (build_dir / "config-utils.js").read_text()
if "const originalList = (config || {}).federated_extensions || [];" not in config_utils:
    fail("config-utils.js is missing federated extension list fix")
if "config.federated_extensions = allExtensions;" not in config_utils:
    fail("config-utils.js is missing federated extension assignment fix")

# Sha-cascade guard for the nb_mypy kernel patch (scripts/patch-pyodide-kernel.py).
# piplite verifies the kernel wheel against the sha256 recorded in all.json, and
# the build derives the pipliteUrls ?sha256= from all.json. If the patched wheel,
# all.json, and pipliteUrls ever fall out of sync, piplite rejects the wheel and
# the editor kernel never loads. Assert the chain here so that becomes a build
# failure, not a (browser-only) surprise.
import hashlib

pypi_dir = remote_entry_dir / "pypi"
kernel_wheels = sorted(pypi_dir.glob("pyodide_kernel-*.whl"))
if not kernel_wheels:
    fail(f"no pyodide_kernel-*.whl under {pypi_dir}")
kernel_wheel = kernel_wheels[0]
wheel_sha = hashlib.sha256(kernel_wheel.read_bytes()).hexdigest()

all_json_path = pypi_dir / "all.json"
all_index = json.loads(all_json_path.read_text())
recorded_sha = None
for pkg in all_index.values():
    for files in pkg.get("releases", {}).values():
        for entry in files:
            if entry.get("filename") == kernel_wheel.name:
                recorded_sha = entry.get("digests", {}).get("sha256")
if recorded_sha != wheel_sha:
    fail(
        f"pyodide_kernel wheel sha256 {wheel_sha} != all.json digest {recorded_sha} — "
        "piplite would reject the kernel wheel (run scripts/setup-jupyterlite.sh to re-patch)"
    )

all_json_sha = hashlib.sha256(all_json_path.read_bytes()).hexdigest()
piplite_shas = [u.split("sha256=", 1)[1] for u in piplite_urls if "sha256=" in u]
if all_json_sha not in piplite_shas:
    fail(f"sha256(all.json)={all_json_sha} not referenced by pipliteUrls {piplite_shas}")

print("JupyterLite verification passed.")
PY
