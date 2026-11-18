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
# It compares whole specs, in both directions, against the `specs` that the
# build records in each env's empack_env_meta.json: the dependency lines it
# was solved from. So a changed constraint (`numpy <2.5.3`) and a package
# dropped from the file but still vendored both fail, as an added package does.
# The environments are found by globbing environment-*.yml, and each file's
# `name:` names its vendored directory, so a new environment is checked
# without an edit here.
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

def env_name(env_file: pathlib.Path) -> str | None:
    """The top-level `name:` of an environment file: its vendored directory."""
    for raw in env_file.read_text().splitlines():
        match = re.match(r"^name:\s*(\S+)\s*$", raw.split("#", 1)[0])
        if match:
            return match.group(1)
    return None


def normalized(spec: str) -> str:
    """`numpy <2.5.3` and `numpy<2.5.3` are the same request."""
    return re.sub(r"\s+", "", spec)


def spec_name(spec: str) -> str:
    """"numpy >=2,<3" / "numpy>=2" / "numpy" -> "numpy"."""
    return re.split(r"[\s<>=!~]", spec, maxsplit=1)[0]


def declared_dependencies(env_file: pathlib.Path) -> list[str]:
    """The dependency specs under `dependencies:`, as written.

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
        names.append(spec)
    return names


env_files = sorted((root / "Tools" / "jupyterlite").glob("environment-*.yml"))
if not env_files:
    failures.append("no Tools/jupyterlite/environment-*.yml found — the guard is not reading the tree")

for env_file in env_files:
    env_file_name = env_file.name
    env_dir_name = env_name(env_file)
    if env_dir_name is None:
        failures.append(f"{env_file_name} has no top-level `name:`, so its vendored env cannot be found")
        continue
    env_dir = root / "Public" / "jupyterlite" / "xeus" / env_dir_name
    meta_path = env_dir / "empack_env_meta.json"
    if not meta_path.is_file():
        failures.append(f"{env_file_name} declares an env but {meta_path} is missing")
        continue

    meta = json.loads(meta_path.read_text())
    vendored = {p["name"] for p in meta.get("packages", [])}
    built_from = {normalized(s): s for s in meta.get("specs", [])}
    declared = declared_dependencies(env_file)
    if not declared:
        failures.append(f"{env_file_name}: no dependencies parsed — the guard is not reading the file")
        continue
    if not built_from:
        failures.append(f"{meta_path} records no `specs` — the build no longer says what it was solved from")
        continue

    problems = []
    missing = [spec_name(s) for s in declared if spec_name(s) not in vendored]
    if missing:
        problems.append(
            f"{env_file_name} lists {', '.join(missing)}, but the vendored "
            f"{env_dir_name} does not contain "
            f"{'them' if len(missing) > 1 else 'it'}. Adding a name to the env file "
            "changes nothing until the kernel is rebuilt — re-vendor (see this "
            "script's header)."
        )
    declared_by_name = {spec_name(s): s for s in declared}
    built_by_name = {spec_name(s): s for s in built_from.values()}
    for name, spec in declared_by_name.items():
        if name in missing or name not in built_by_name:
            continue
        if normalized(spec) != normalized(built_by_name[name]):
            problems.append(
                f"{env_file_name} asks for `{spec}`, but the vendored {env_dir_name} "
                f"was built from `{built_by_name[name]}`. Re-vendor (see this script's header)."
            )
    for name, spec in built_by_name.items():
        if name in declared_by_name:
            continue
        problems.append(
            f"the vendored {env_dir_name} was built from `{spec}`, which "
            f"{env_file_name} no longer lists. Removing a name from the env file "
            "removes nothing until the kernel is rebuilt — re-vendor (see this "
            "script's header)."
        )
    if problems:
        failures.extend(problems)
    else:
        print(
            f"check-env-vendored-sync: OK ({env_file_name}: the "
            f"{len(declared)} declared spec(s) are the ones {env_dir_name} was built from)."
        )

if failures:
    for failure in failures:
        print(f"check-env-vendored-sync: {failure}", file=sys.stderr)
    sys.exit(1)
PY
