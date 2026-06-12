#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_DIR="${VENV_DIR:-$ROOT_DIR/.venv-jlite}"
REQ_FILE="${REQ_FILE:-$ROOT_DIR/Tools/jupyterlite/requirements.txt}"

if [[ ! -f "$REQ_FILE" ]]; then
  echo "requirements file not found: $REQ_FILE" >&2
  exit 1
fi

if [[ ! -d "$VENV_DIR" ]]; then
  python3 -m venv "$VENV_DIR"
fi

"$VENV_DIR/bin/python" -m pip install --upgrade pip
"$VENV_DIR/bin/pip" install -r "$REQ_FILE"

# Patch the bundled pyodide-kernel wheel to enable nb_mypy at kernel startup.
# Done here (before the build) so `jupyter lite build` bundles the patched
# wheel and regenerates its all.json sha automatically; CI runs this too, so
# the committed Public/jupyterlite stays reproducible. Idempotent + fail-safe.
KERNEL_PYPI="$VENV_DIR/share/jupyter/labextensions/@jupyterlite/pyodide-kernel-extension/static/pypi"
if [[ -d "$KERNEL_PYPI" ]]; then
  "$VENV_DIR/bin/python" "$ROOT_DIR/scripts/patch-pyodide-kernel.py" "$KERNEL_PYPI"
else
  echo "warning: pyodide-kernel labextension pypi dir not found ($KERNEL_PYPI);" >&2
  echo "         nb_mypy startup activation NOT applied." >&2
fi

echo "JupyterLite toolchain ready in $VENV_DIR"
