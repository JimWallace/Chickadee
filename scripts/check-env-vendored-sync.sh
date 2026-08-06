#!/usr/bin/env bash
# Asserts that the vendored xeus kernels actually contain what
# Tools/jupyterlite/environment-*.yml asks for.
#
# The gap this closes, which shipped. Adding a package to an environment file
# changes NOTHING until `scripts/build-jupyterlite.sh` regenerates the kernel —
# and for a long time that was believed to be a maintainer-machine-only step, so
# it was easy to edit the env file, describe the packages as available in a
# changelog, and never notice they were not. That is exactly what happened with
# scipy, sympy, scikit-learn and statsmodels: the env file listed them, the
# shipped bytes had none of them, and the failure would have surfaced as an
# ImportError at grade time for a student.
#
# Nothing caught it, because every other guard checks the vendored bytes against
# THEMSELVES (check-xeus-vendored.sh) or the build against its own output
# (verify-jupyterlite.sh). None compared the declared intent to the shipped
# result. This does, and it is cheap: no build, no network, just two files.
#
# When this fails, the fix is to re-vendor — which is no longer manual: run the
# "Re-vendor xeus kernels" workflow (.github/workflows/revendor-kernels.yml), or
# locally, with micromamba on PATH:
#
#     scripts/setup-jupyterlite.sh
#     scripts/build-jupyterlite.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT_DIR" <<'PY'
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
failures = []

# environment-<lang>.yml  ->  the vendored env directory it builds.
ENVS = {
    "environment-python.yml": "chickadee-python",
    "environment-r.yml": "chickadee-r",
    "environment-lua.yml": "chickadee-lua",
}


def declared_dependencies(env_file: pathlib.Path) -> list[str]:
    """Package names under `dependencies:`, stripped of version constraints.

    A hand-rolled reader rather than a YAML parse, so this guard has no
    dependency of its own and runs anywhere python3 does. The files are ours and
    the shape is a flat list; anything more exotic (a nested `pip:` block) is
    reported rather than silently skipped.
    """
    names = []
    in_deps = False
    for raw in env_file.read_text().splitlines():
        line = raw.split("#", 1)[0].rstrip()
        if not line.strip():
            continue
        if re.match(r"^dependencies:\s*$", line):
            in_deps = True
            continue
        if in_deps and not line.startswith((" ", "\t", "-")):
            break  # a new top-level key ends the list
        if not in_deps:
            continue
        item = re.match(r"^\s*-\s+(.*)$", line)
        if not item:
            continue
        spec = item.group(1).strip()
        if spec.endswith(":"):
            failures.append(f"{env_file.name}: nested `{spec}` block is not understood by this guard")
            continue
        # "numpy >=2,<3" / "numpy>=2" / "numpy" -> "numpy"
        names.append(re.split(r"[\s<>=!~]", spec, 1)[0])
    return names


for env_file_name, env_dir_name in sorted(ENVS.items()):
    env_file = root / "Tools" / "jupyterlite" / env_file_name
    env_dir = root / "Public" / "jupyterlite" / "xeus" / env_dir_name
    if not env_file.is_file():
        continue
    meta_path = env_dir / "empack_env_meta.json"
    if not meta_path.is_file():
        failures.append(f"{env_file_name} declares an env but {meta_path} is missing")
        continue

    meta = json.loads(meta_path.read_text())
    vendored = {p["name"] for p in meta.get("packages", [])}
    declared = declared_dependencies(env_file)
    if not declared:
        failures.append(f"{env_file_name}: no dependencies parsed — the guard is not reading the file")
        continue

    missing = [name for name in declared if name not in vendored]
    if missing:
        failures.append(
            f"{env_file_name} lists {', '.join(missing)}, but the vendored "
            f"{env_dir_name} does not contain "
            f"{'them' if len(missing) > 1 else 'it'}. Adding a name to the env file "
            "changes nothing until the kernel is rebuilt — re-vendor (see this "
            "script's header)."
        )
    else:
        print(
            f"check-env-vendored-sync: OK ({env_file_name}: all "
            f"{len(declared)} declared package(s) present in {env_dir_name})."
        )

if failures:
    for failure in failures:
        print(f"check-env-vendored-sync: {failure}", file=sys.stderr)
    sys.exit(1)
PY
