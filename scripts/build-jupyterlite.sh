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

BUILD_ARGS=(--lite-dir "$TMP_LITE_DIR" --output-dir "$TEMP_BUILD_DIR")
if [[ -n "$SOURCE_DATE_EPOCH" ]]; then
  BUILD_ARGS+=(--source-date-epoch "$SOURCE_DATE_EPOCH")
fi

# R kernel via jupyterlite-xeus (xeus-r): build the xeus-r WASM kernel alongside
# the Pyodide Python kernel ONLY where micromamba is available. jupyterlite-xeus
# solves the emscripten-forge env at build time, which needs network to
# repo.prefix.dev / conda-forge. CI has no such network, so it skips this and
# treats the committed Public/jupyterlite/xeus/ as the authoritative vendored
# kernel (the reproducibility check excludes that path; scripts/check-xeus-vendored.sh
# guards its integrity). Rebuild the vendored kernel where micromamba +
# emscripten-forge are reachable (a maintainer machine, or this repo's spike env).
if [[ -f "$LITE_SRC_DIR/environment-r.yml" ]] && command -v micromamba >/dev/null 2>&1; then
  cp "$LITE_SRC_DIR/environment-r.yml" "$TMP_LITE_DIR/environment.yml"
  BUILD_ARGS+=(--XeusAddon.environment_file "$TMP_LITE_DIR/environment.yml")
  echo "build-jupyterlite: micromamba found — building the xeus-r kernel."
elif [[ -f "$LITE_SRC_DIR/environment-r.yml" ]]; then
  echo "build-jupyterlite: micromamba not found — skipping the xeus-r kernel build; the committed Public/jupyterlite/xeus/ is authoritative." >&2
fi

"$JUPYTER_BIN" lite build "${BUILD_ARGS[@]}"

mkdir -p "$OUTPUT_DIR"

# Keep runtime notebook storage roots while refreshing all generated assets.
RSYNC_EXCLUDES=(--exclude 'files/' --exclude 'lab/files/' --exclude 'notebooks/files/')
# If this run did NOT build the xeus-r kernel (no micromamba) but a vendored one
# is already committed, preserve it — don't let --delete wipe the manually-built
# kernel that this environment can't reproduce.
if ! command -v micromamba >/dev/null 2>&1 && [[ -d "$OUTPUT_DIR/xeus" ]]; then
  RSYNC_EXCLUDES+=(--exclude 'xeus/' --exclude 'extensions/@jupyterlite/xeus-extension/')
  echo "build-jupyterlite: preserving the committed vendored xeus-r kernel (not rebuilt this run)." >&2
fi
rsync -a --delete "${RSYNC_EXCLUDES[@]}" "$TEMP_BUILD_DIR"/ "$OUTPUT_DIR"/

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

# Rewrite the pyodide-kernel's Atomics.waitAsync polyfill worker from a data: URL
# to a blob: URL so it survives our CSP (worker-src 'self' blob:) and COEP —
# letting engines without native waitAsync (older Safari / iPadOS) boot the kernel
# cross-origin isolated. Idempotent; fails if the upstream polyfill string drifts.
python3 "$ROOT_DIR/scripts/patch-pyodide-waitasync-worker.py" "$OUTPUT_DIR"

# Inject the in-iframe kernel-boot diagnostics collector (jl-kernel-diagnostics.js)
# into the editor index.html documents. `jupyter lite build` regenerates those, so
# this re-adds the <script> tag every build. Idempotent.
python3 "$ROOT_DIR/scripts/patch-jupyterlite-diagnostics.py" "$OUTPUT_DIR"

# Stub the xeus extension's module-load fetch of the parselmouth conda->pip
# mapping (raw.githubusercontent.com). Our CSP (connect-src 'self') blocks it by
# policy, so it can never succeed — un-patched it only emits a csp_violation +
# unhandledrejection diagnostics pair on every editor boot. Idempotent; fails if
# the upstream fetch shape drifts.
python3 "$ROOT_DIR/scripts/patch-xeus-extension.py" "$OUTPUT_DIR"

"$ROOT_DIR/scripts/verify-jupyterlite.sh" "$OUTPUT_DIR"
echo "JupyterLite rebuilt at $OUTPUT_DIR"
