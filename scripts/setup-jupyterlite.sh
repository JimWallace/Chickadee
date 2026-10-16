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
# From the repository root: requirements.txt names the Chickadee extension by
# a path, and pip resolves a path in a requirements file from the current
# directory.
(cd "$ROOT_DIR" && "$VENV_DIR/bin/pip" install -r "$REQ_FILE")

echo "JupyterLite toolchain ready in $VENV_DIR"
