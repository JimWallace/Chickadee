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

# Editor kernels via jupyterlite-xeus: xpython (Python) and xr (R), each from
# its OWN emscripten-forge env — Tools/jupyterlite/environment-{python,r}.yml.
#
# The two envs are separate on purpose. jupyterlite-xeus packs one
# `kernel_packages` payload per env and a kernel fetches its whole env at boot,
# so a single shared Python+R env made every Python boot pull all of r-base and
# every R boot pull numpy/pandas/matplotlib — slow enough to time out the editor
# probes ("kernel never reported idle"). `environment_file` is list-valued, so
# passing it twice yields two envs and two payloads.
#
# Built ONLY where micromamba is available: jupyterlite-xeus solves the envs at
# build time, which needs network to repo.prefix.dev / conda-forge. CI has no
# such network, so it skips this and treats the committed
# Public/jupyterlite/xeus/ as the authoritative vendored kernels (the
# reproducibility check excludes that path; scripts/check-xeus-vendored.sh
# guards their integrity). Rebuild where micromamba + emscripten-forge are
# reachable (a maintainer machine, or this repo's spike env).
#
# NOTE: --XeusAddon.environment_file is resolved RELATIVE TO --lite-dir, so each
# must be passed as a bare filename, not the absolute path it was copied to.
XEUS_ENVS=(environment-python.yml environment-r.yml)
XEUS_ENVS_PRESENT=()
for env_file in "${XEUS_ENVS[@]}"; do
  [[ -f "$LITE_SRC_DIR/$env_file" ]] && XEUS_ENVS_PRESENT+=("$env_file")
done
if [[ ${#XEUS_ENVS_PRESENT[@]} -gt 0 ]] && command -v micromamba >/dev/null 2>&1; then
  for env_file in "${XEUS_ENVS_PRESENT[@]}"; do
    cp "$LITE_SRC_DIR/$env_file" "$TMP_LITE_DIR/$env_file"
    BUILD_ARGS+=(--XeusAddon.environment_file "$env_file")
  done
  echo "build-jupyterlite: micromamba found — building the xeus kernels from ${XEUS_ENVS_PRESENT[*]}."
elif [[ ${#XEUS_ENVS_PRESENT[@]} -gt 0 ]]; then
  echo "build-jupyterlite: micromamba not found — skipping the xeus kernel build; the committed Public/jupyterlite/xeus/ is authoritative." >&2
fi

"$JUPYTER_BIN" lite build "${BUILD_ARGS[@]}"

mkdir -p "$OUTPUT_DIR"

# Keep runtime notebook storage roots while refreshing all generated assets.
RSYNC_EXCLUDES=(--exclude 'files/' --exclude 'lab/files/' --exclude 'notebooks/files/')
# If this run did NOT build the xeus kernels (no micromamba) but a vendored set
# is already committed, preserve it — don't let --delete wipe the manually-built
# kernels that this environment can't reproduce.
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
# mapping (raw.githubusercontent.com), and cache-bust the extension's chunk +
# remoteEntry URLs so browsers holding pre-stub bytes under the immutable
# cache policy re-fetch them (see the script docstring). Our CSP (connect-src
# 'self') blocks the fetch by policy, so it can never succeed — un-patched it
# only emits a csp_violation + unhandledrejection diagnostics pair on every
# editor boot. Idempotent; fails if the upstream shapes drift.
python3 "$ROOT_DIR/scripts/patch-xeus-extension.py" "$OUTPUT_DIR"

# Drop pyodide-http's Pyodide-only `to_js(dict_converter=...)` call from the
# vendored xeus-python env. xeus-python -> xeus-python-shell-lite ->
# pyodide-http is an unavoidable dependency chain, the shell calls patch_all()
# at kernel startup, and the first patched HTTP call (the notebook page's Drive
# mount) then dies on pyjs's to_js — leaving the kernel stuck at
# `kernel_starting` forever. Idempotent; fails if the upstream source drifts.
python3 "$ROOT_DIR/scripts/patch-xeus-python-http.py" "$OUTPUT_DIR"

"$ROOT_DIR/scripts/verify-jupyterlite.sh" "$OUTPUT_DIR"
echo "JupyterLite rebuilt at $OUTPUT_DIR"
