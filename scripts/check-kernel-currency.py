#!/usr/bin/env python3
"""Reports when re-vendoring the xeus kernels would change what ships.

WHY THIS EXISTS, AND WHY IT IS NOT DEPENDABOT.

Every other dependency surface here is watched by Dependabot
(.github/dependabot.yml): the Swift graph, the Docker base images, the GitHub
Actions, the five npm trees, and the JupyterLite pip pins in
Tools/jupyterlite/requirements.txt. That covers the whole JupyterLite half of
the editor, and it works — jupyterlite-xeus 5.1.0 was published on 2026-09-11
and vendored here four days later.

It cannot cover the kernels, and Dependabot's `conda` ecosystem does not close
the gap. Four independent reasons, any one of them fatal:

  1. Its file fetcher matches `environment.yml` / `environment.yaml` exactly.
     Ours are environment-python.yml, environment-r.yml, environment-lua.yml
     and environment-octave.yml — and they must stay four separate files,
     for the reason recorded at the top of each one.
  2. It resolves against `https://anaconda.org/<channel>/<package>`. Our
     channel is https://repo.prefix.dev/emscripten-forge-4x, which is not on
     anaconda.org at all; xeus-lua and xeus-octave do not exist there.
  3. Even for a name conda-forge does publish, the versions there are for
     linux-64 and friends, never emscripten-wasm32. A bump derived from them
     would not merely be useless, it would be wrong.
  4. Its update checker yields no candidate when every requirement is nil or
     "*", and ours are deliberately bare names.

So the kernels move with NO file in this repository changing. xeus-lua 0.11.0
could ship tomorrow and nothing would say so. This closes that gap.

HOW IT ANSWERS THE QUESTION. It asks the real solver, not a reimplementation
of one. `micromamba create --dry-run` against the same environment files and
the same `emscripten-wasm32` platform that `jupyter lite build` uses, then
compares the solved (name, version, build) triples to the tarballs actually
vendored under Public/jupyterlite/xeus/*/kernel_packages/.

That the solver is the oracle is the whole design, and the alternative was
tried first and thrown away. Reading repodata and asking "is a newer version
published?" reports three of our four kernel envs as out of date, every time,
forever — because strict channel priority means a conda-forge noarch
`fonttools 4.65.0` never displaces the compiled emscripten-forge build, and
because `python` is pinned to 3.13 transitively through `python_abi` rather
than by any constraint naming `python`. Getting those right means writing a
solver. We already have one, and it is the one whose answer actually ships.

A difference here means exactly one thing, with no interpretation needed: a
re-vendor would change the shipped bytes. Our own pins (`numpy <2.5.3`) are
honoured by the solve like any other constraint, so a deliberate pin reads as
current rather than as drift.

WHEN IT FAILS, run the "Re-vendor xeus kernels" workflow
(.github/workflows/revendor-kernels.yml) and commit what it produces.

Needs micromamba on PATH and network to the channels, which is why this is not
in format-lint and not in the JupyterLite job. It runs on a schedule; see
.github/workflows/kernel-currency.yml.
"""

from __future__ import annotations

import argparse
import contextlib
import io
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
VENDORED_ROOT = REPO_ROOT / "Public" / "jupyterlite" / "xeus"
ENV_DIR = REPO_ROOT / "Tools" / "jupyterlite"

# The platform the kernels are built for. jupyterlite-xeus solves for this;
# solving for the host platform would compare against entirely different builds.
PLATFORM = "emscripten-wasm32"

VENDORED_TARBALL = re.compile(r"^(?P<name>.+)-(?P<version>[^-]+)-(?P<build>[^-]+)\.tar\.gz$")


def environment_files() -> list[pathlib.Path]:
    """Every Tools/jupyterlite/environment-*.yml, in a stable order."""
    files = sorted(ENV_DIR.glob("environment-*.yml"))
    if not files:
        raise SystemExit(f"no environment-*.yml under {ENV_DIR}")
    return files


def environment_name(env_file: pathlib.Path) -> str:
    """The `name:` an environment file declares.

    This is also the directory the kernel is vendored into, so reading it is
    what keeps the two halves matched. Deriving the directory from the file
    name instead would be one more hand-maintained mapping to drift, which is
    the failure `check-xeus-vendored.sh` has already been bitten by once.
    """
    for raw in env_file.read_text().splitlines():
        line = raw.split("#", 1)[0].rstrip()
        if line.startswith("name:"):
            return line.split(":", 1)[1].strip()
    raise SystemExit(f"{env_file.name} declares no `name:`")


def vendored_packages(env_name: str) -> dict[str, tuple[str, str]]:
    """{package name: (version, build)} actually shipped for one env."""
    packages_dir = VENDORED_ROOT / env_name / "kernel_packages"
    if not packages_dir.is_dir():
        raise SystemExit(f"{env_name} is declared but not vendored ({packages_dir})")
    packages: dict[str, tuple[str, str]] = {}
    for tarball in sorted(packages_dir.iterdir()):
        match = VENDORED_TARBALL.match(tarball.name)
        if match:
            packages[match["name"]] = (match["version"], match["build"])
    if not packages:
        raise SystemExit(f"{packages_dir} holds no kernel packages")
    return packages


def solve(env_file: pathlib.Path, timeout: int) -> dict[str, tuple[str, str]]:
    """{package name: (version, build)} the solver picks for one env today."""
    micromamba = shutil.which("micromamba")
    if not micromamba:
        raise SystemExit(
            "micromamba is not on PATH. Install it as "
            ".github/workflows/revendor-kernels.yml does, or run this where the "
            "kernels are built."
        )
    with tempfile.TemporaryDirectory() as root:
        try:
            completed = subprocess.run(
                [
                    micromamba, "create",
                    "--dry-run", "--json", "--yes",
                    "--name", "chickadee-currency-probe",
                    "--root-prefix", root,
                    "--platform", PLATFORM,
                    "--file", str(env_file),
                ],
                capture_output=True,
                text=True,
                timeout=timeout,
                check=False,
            )
        except subprocess.TimeoutExpired:
            raise SystemExit(
                f"solving {env_file.name} did not finish within {timeout}s. The "
                f"channel is likely unreachable or very slow; this is a network "
                f"problem, not a currency finding."
            ) from None
    if completed.returncode != 0:
        raise SystemExit(
            f"solving {env_file.name} failed (exit {completed.returncode}):\n"
            f"{completed.stderr.strip()[-2000:]}"
        )
    try:
        result = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise SystemExit(f"solving {env_file.name} produced no JSON: {error}") from error
    if not result.get("success"):
        raise SystemExit(f"solving {env_file.name} did not succeed:\n{completed.stdout[-2000:]}")

    links = result.get("actions", {}).get("LINK", [])
    if not links:
        raise SystemExit(f"solving {env_file.name} linked nothing")
    return {p["name"]: (p["version"], p["build"]) for p in links}


def compare(
    env_name: str,
    vendored: dict[str, tuple[str, str]],
    solved: dict[str, tuple[str, str]],
) -> list[dict]:
    """Every package the solver and the vendored tree disagree about."""
    differences: list[dict] = []
    for name in sorted(set(vendored) | set(solved)):
        have, want = vendored.get(name), solved.get(name)
        if have == want:
            continue
        if have is None:
            change = "ADDED"
        elif want is None:
            change = "REMOVED"
        elif have[0] != want[0]:
            change = "VERSION"
        else:
            change = "BUILD"
        differences.append(
            {"env": env_name, "name": name, "change": change, "vendored": have, "solved": want}
        )
    return differences


def _describe(triple: tuple[str, str] | None) -> str:
    return "-".join(triple) if triple else "(absent)"


def report(differences: list[dict], env_summaries: list[str]) -> int:
    """Prints the outcome. Returns the process exit status."""
    for line in env_summaries:
        print(line)

    if not differences:
        print(
            "\ncheck-kernel-currency: OK (every environment solves to exactly the "
            "packages that are vendored; a re-vendor would change no versions)."
        )
        return 0

    print(f"\nA re-vendor would change {len(differences)} package(s):\n")
    width = max(len(f"{d['env']}/{d['name']}") for d in differences)
    for difference in differences:
        label = f"{difference['env']}/{difference['name']}".ljust(width)
        print(
            f"  {difference['change']:<7} {label}  "
            f"{_describe(difference['vendored'])} -> {_describe(difference['solved'])}"
        )
    print(
        '\ncheck-kernel-currency: the vendored kernels are behind their channels. '
        'Run the "Re-vendor xeus kernels" workflow '
        "(.github/workflows/revendor-kernels.yml) and commit the result."
    )
    return 1


def run(timeout: int) -> int:
    differences: list[dict] = []
    summaries: list[str] = []
    for env_file in environment_files():
        env_name = environment_name(env_file)
        print(f"solving {env_file.name} for {PLATFORM} ...", flush=True)
        vendored = vendored_packages(env_name)
        solved = solve(env_file, timeout)
        env_differences = compare(env_name, vendored, solved)
        differences.extend(env_differences)
        summaries.append(
            f"{env_name}: {len(vendored)} vendored, {len(solved)} solved, "
            f"{len(env_differences)} difference(s)"
        )
    return report(differences, summaries)


def self_test() -> int:
    """Proves the comparator reports each kind of change, and fails on one.

    A check never seen to fail is not a check (scripts/check-guards.sh). This
    one cannot join that harness — it needs micromamba and network, and its
    "defect" is movement in a remote channel rather than an edit to a tracked
    file — so it proves itself here, and the workflow runs this first.
    """
    failures: list[str] = []

    def check(label: str, got, want):
        if got != want:
            failures.append(f"{label}: expected {want!r}, got {got!r}")

    vendored = {
        "xeus": ("6.0.5", "h0b0027f_0"),
        "xeus-lua": ("0.10.1", "h0b0027f_0"),
        "xproperty": ("0.12.1", "h0b0027f_0"),
        "gone": ("1.0", "h0_0"),
    }
    solved = {
        "xeus": ("6.0.5", "h0b0027f_0"),
        "xeus-lua": ("0.11.0", "h0b0027f_0"),
        "xproperty": ("0.12.1", "h0b0027f_1"),
        "arrived": ("2.0", "h0_0"),
    }
    changes = {d["name"]: d["change"] for d in compare("chickadee-lua", vendored, solved)}
    check("an unchanged package is not reported", "xeus" in changes, False)
    check("a new version is VERSION", changes.get("xeus-lua"), "VERSION")
    check("a rebuilt package is BUILD", changes.get("xproperty"), "BUILD")
    check("a dropped package is REMOVED", changes.get("gone"), "REMOVED")
    check("a new package is ADDED", changes.get("arrived"), "ADDED")

    check(
        "an identical solve reports nothing",
        compare("chickadee-lua", vendored, dict(vendored)),
        [],
    )

    # The reporter must actually fail on a difference, and pass without one.
    # Its output is captured so this log does not carry a fake failure.
    with contextlib.redirect_stdout(io.StringIO()):
        drifted = report(compare("chickadee-lua", vendored, solved), [])
        clean = report([], [])
    check("a difference exits non-zero", drifted, 1)
    check("no difference exits zero", clean, 0)

    # The env-name reader must agree with what is actually vendored, which is
    # what keeps this script pointed at the right directories.
    for env_file in environment_files():
        name = environment_name(env_file)
        if not (VENDORED_ROOT / name / "kernel_packages").is_dir():
            failures.append(f"{env_file.name} names {name!r}, which is not vendored")

    if failures:
        for failure in failures:
            print(f"self-test FAIL: {failure}", file=sys.stderr)
        return 1
    print("check-kernel-currency: self-test OK.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="prove the comparator offline; needs neither micromamba nor network",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=600,
        help=(
            "per-environment solve timeout in seconds. Four of these must fit "
            "inside the timeout-minutes of .github/workflows/kernel-currency.yml, "
            "so that a hung solve fails with a sentence rather than being killed "
            "by the job"
        ),
    )
    arguments = parser.parse_args()
    return self_test() if arguments.self_test else run(arguments.timeout)


if __name__ == "__main__":
    sys.exit(main())
