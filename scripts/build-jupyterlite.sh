#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_DIR="${VENV_DIR:-$ROOT_DIR/.venv-jlite}"
LITE_SRC_DIR="${LITE_SRC_DIR:-$ROOT_DIR/Tools/jupyterlite}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/Public/jupyterlite}"
TEMP_BUILD_DIR="${TEMP_BUILD_DIR:-}"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-}"

JUPYTER_BIN="$VENV_DIR/bin/jupyter"
if [[ ! -x "$JUPYTER_BIN" ]]; then
  echo "missing $JUPYTER_BIN" >&2
  echo "Run scripts/setup-jupyterlite.sh first." >&2
  exit 1
fi

if [[ ! -f "$LITE_SRC_DIR/jupyter-lite.json" ]]; then
  echo "missing lite source config: $LITE_SRC_DIR/jupyter-lite.json" >&2
  exit 1
fi

TMP_LITE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/chickadee-jlite-src.XXXXXX")"
if [[ -n "$TEMP_BUILD_DIR" ]]; then
  rm -rf "$TEMP_BUILD_DIR"
else
  TEMP_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/chickadee-jlite-out.XXXXXX")"
fi
trap 'rm -rf "$TMP_LITE_DIR" "$TEMP_BUILD_DIR"' EXIT
cp "$LITE_SRC_DIR/jupyter-lite.json" "$TMP_LITE_DIR/jupyter-lite.json"

if [[ -n "$SOURCE_DATE_EPOCH" ]]; then
  "$JUPYTER_BIN" lite build \
    --lite-dir "$TMP_LITE_DIR" \
    --output-dir "$TEMP_BUILD_DIR" \
    --source-date-epoch "$SOURCE_DATE_EPOCH"
else
  "$JUPYTER_BIN" lite build \
    --lite-dir "$TMP_LITE_DIR" \
    --output-dir "$TEMP_BUILD_DIR"
fi

mkdir -p "$OUTPUT_DIR"

# Keep runtime notebook storage roots while refreshing all generated assets.
rsync -a --delete \
  --exclude 'files/' \
  --exclude 'lab/files/' \
  --exclude 'notebooks/files/' \
  "$TEMP_BUILD_DIR"/ "$OUTPUT_DIR"/

mkdir -p "$OUTPUT_DIR/files" "$OUTPUT_DIR/lab/files" "$OUTPUT_DIR/notebooks/files"

python3 - "$OUTPUT_DIR/config-utils.js" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
text = text.replace(
    "const originalList = Object.keys(config || {})['federated_extensions'] || [];",
    "const originalList = (config || {}).federated_extensions || [];",
)
if (
    "allExtensions.sort((a, b) => a.name.localeCompare(b.name));\n  config.federated_extensions = allExtensions;\n  return config;"
    not in text
):
    text = text.replace(
        "allExtensions.sort((a, b) => a.name.localeCompare(b.name));\n  return config;",
        "allExtensions.sort((a, b) => a.name.localeCompare(b.name));\n  config.federated_extensions = allExtensions;\n  return config;",
    )
path.write_text(text)
PY

"$ROOT_DIR/scripts/verify-jupyterlite.sh" "$OUTPUT_DIR"
echo "JupyterLite rebuilt at $OUTPUT_DIR"
