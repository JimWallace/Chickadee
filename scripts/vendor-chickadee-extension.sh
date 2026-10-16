#!/usr/bin/env bash
# Put the prebuilt @chickadee/jupyterlite-extension into the committed
# JupyterLite bundle, as `jupyter lite build` would (notebook views, NB2).
#
# `scripts/build-jupyterlite.sh` federates the extension from
# Tools/jupyterlite/requirements.txt and applies Tools/jupyterlite/overrides.json.
# That full rebuild needs micromamba and rewrites ~100 MB of kernels, so it runs
# only in revendor-kernels.yml. Between rebuilds this script makes the same
# three changes to Public/jupyterlite:
#
#   1. extensions/@chickadee/jupyterlite-extension/ is the built labextension;
#   2. jupyter-lite.json lists it in federated_extensions, sorted by name;
#   3. overrides.json and jupyter-lite.json's settingsOverrides hold
#      Tools/jupyterlite/overrides.json.
#
# Usage:
#   scripts/vendor-chickadee-extension.sh           write the changes
#   scripts/vendor-chickadee-extension.sh --check   exit 1 if the bundle differs
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="write"
if [[ "${1:-}" == "--check" ]]; then
  MODE="check"
fi

python3 - "$ROOT_DIR" "$MODE" <<'PY'
import filecmp
import json
import pathlib
import shutil
import sys

root = pathlib.Path(sys.argv[1])
mode = sys.argv[2]
built = root / "Tools/jupyterlite/chickadee-extension/chickadee_jupyterlite_extension/labextension"
bundle = root / "Public/jupyterlite"
vendored = bundle / "extensions/@chickadee/jupyterlite-extension"
config_path = bundle / "jupyter-lite.json"
overrides_src = root / "Tools/jupyterlite/overrides.json"
overrides_dest = bundle / "overrides.json"
NAME = "@chickadee/jupyterlite-extension"

def fail(message):
    print(f"vendor-chickadee-extension: {message}", file=sys.stderr)
    sys.exit(1)

if not (built / "package.json").is_file():
    fail(f"no built labextension at {built}; run `jlpm build` in Tools/jupyterlite/chickadee-extension")

build_info = json.loads((built / "package.json").read_text())["jupyterlab"]["_build"]
entry = {key: build_info[key] for key in ("extension", "load", "style") if key in build_info}
entry["name"] = NAME

config = json.loads(config_path.read_text())
data = config["jupyter-config-data"]
federated = [e for e in data.get("federated_extensions", []) if e.get("name") != NAME]
federated.append(dict(sorted(entry.items())))
federated.sort(key=lambda e: e["name"])
overrides = json.loads(overrides_src.read_text())
wanted = dict(data, federated_extensions=federated, settingsOverrides=overrides)
# The format `jupyter lite build` writes: sorted keys, two spaces, no final newline.
wanted_text = json.dumps(dict(config, **{"jupyter-config-data": wanted}), indent=2, sort_keys=True)

def same_tree(a, b):
    if not b.is_dir():
        return False
    cmp = filecmp.dircmp(a, b)
    if cmp.left_only or cmp.right_only or cmp.diff_files or cmp.funny_files:
        return False
    return all(same_tree(a / d, b / d) for d in cmp.common_dirs)

if mode == "check":
    problems = []
    if not same_tree(built, vendored):
        problems.append(f"{vendored} is not the built labextension")
    if config_path.read_text() != wanted_text:
        problems.append(f"{config_path} does not list the extension or the overrides")
    if not overrides_dest.is_file() or overrides_dest.read_text() != overrides_src.read_text():
        problems.append(f"{overrides_dest} is not {overrides_src}")
    if problems:
        fail("; ".join(problems) + ". Run scripts/vendor-chickadee-extension.sh.")
    print("vendor-chickadee-extension: OK (the bundle carries the built extension and the overrides)")
    sys.exit(0)

if vendored.exists():
    shutil.rmtree(vendored)
shutil.copytree(built, vendored)
config_path.write_text(wanted_text)
shutil.copyfile(overrides_src, overrides_dest)
print(f"vendor-chickadee-extension: vendored {entry['load']} and {len(overrides)} setting overrides")
PY
