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
# Chickadee's own extension: the editor theme, the chickadee:* bridge commands
# and the ck:* page events. Its labextension is prebuilt and committed, so this
# install needs no Node.js. Between full rebuilds,
# scripts/vendor-chickadee-extension.sh puts it into the bundle. It is installed
# here rather than named in requirements.txt; that file says why.
"$VENV_DIR/bin/pip" install "$ROOT_DIR/Tools/jupyterlite/chickadee-extension"

echo "JupyterLite toolchain ready in $VENV_DIR"
