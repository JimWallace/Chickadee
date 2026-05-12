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

remote_entry = build_dir / "extensions" / "@jupyterlite" / "pyodide-kernel-extension" / "static" / "remoteEntry.a117bd216cefa0b341fe.js"
if not remote_entry.is_file():
    fail(f"missing extension asset: {remote_entry}")

config_utils = (build_dir / "config-utils.js").read_text()
if "const originalList = (config || {}).federated_extensions || [];" not in config_utils:
    fail("config-utils.js is missing federated extension list fix")
if "config.federated_extensions = allExtensions;" not in config_utils:
    fail("config-utils.js is missing federated extension assignment fix")

print("JupyterLite verification passed.")
PY
