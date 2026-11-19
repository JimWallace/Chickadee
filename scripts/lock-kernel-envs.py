#!/usr/bin/env python3
"""Lock the xeus kernel environments, or check that the locks still hold.

WHY. An environment file names packages, mostly with no version. Solving it
gives whatever the channel holds that day, so before the locks every rebuild
of the kernels, for any reason, also upgraded every package in them. A lock
names the exact package files, by URL, with their sha256 (and md5 where the
channel publishes one).
`scripts/build-jupyterlite.sh` installs each kernel from its lock and never
solves, so a rebuild changes a package only when a lock changes.

Each `Tools/jupyterlite/environment-<x>.yml` has one lock,
`Tools/jupyterlite/locks/environment-<x>-lock.yml`. The locks are in their own
directory because micromamba reads a lock only under a `-lock.yml` name, and
that name beside the environment files would match their `environment-*.yml`
glob. The format is conda-lock's version 1, which micromamba installs with
`--file`. It is written as JSON, which is also YAML, so this script needs no
YAML library.

USAGE
    scripts/lock-kernel-envs.py           solve every environment and write its lock
    scripts/lock-kernel-envs.py --check   check the locks offline (see below)

Writing needs micromamba on PATH and network to the channels. It solves with
the flags `scripts/check-kernel-currency.py` uses, so the weekly currency check
and a fresh lock agree about what the channels hold.

`--check` needs neither. It fails when:
  * an environment file has no lock;
  * a lock was made from a different environment file (the lock records a hash
    of the file's specs and channels, with comments and blank lines removed, so
    editing a comment does not make a lock stale);
  * a lock and the vendored kernel_packages/ name different packages, so the
    bytes that ship are not the ones the lock describes.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
ENV_DIR = REPO_ROOT / "Tools" / "jupyterlite"
LOCK_DIR = ENV_DIR / "locks"
VENDORED_ROOT = REPO_ROOT / "Public" / "jupyterlite" / "xeus"
PLATFORM = "emscripten-wasm32"
SOLVE_TIMEOUT_SECONDS = 600

# A vendored tarball: <name>-<version>-<build>.tar.gz, with the content-hash
# suffix the build adds to an archive it rewrites (prune-kernel-packages.py).
VENDORED_TARBALL = re.compile(
    r"^(?P<name>.+)-(?P<version>[^-]+)-(?P<build>[^-]+?)(?:\.chickadee\.[0-9a-f]{12})?\.tar\.gz$"
)
# A locked package file: <name>-<version>-<build>.tar.bz2 or .conda.
LOCKED_FILE = re.compile(r"^(?P<name>.+)-(?P<version>[^-]+)-(?P<build>[^-]+?)\.(?:tar\.bz2|conda)$")


def fail(message: str) -> None:
    print(f"lock-kernel-envs: {message}", file=sys.stderr)
    sys.exit(1)


def environment_files() -> list[pathlib.Path]:
    files = sorted(ENV_DIR.glob("environment-*.yml"))
    if not files:
        fail(f"no environment-*.yml under {ENV_DIR}")
    return files


def lock_path(env_file: pathlib.Path) -> pathlib.Path:
    return LOCK_DIR / f"{env_file.stem}-lock.yml"


def environment_name(env_file: pathlib.Path) -> str:
    for raw in env_file.read_text().splitlines():
        match = re.match(r"^name:\s*(\S+)\s*$", raw.split("#", 1)[0])
        if match:
            return match.group(1)
    fail(f"{env_file.name} declares no `name:`")
    return ""


def environment_channels(env_file: pathlib.Path) -> list[str]:
    channels: list[str] = []
    in_channels = False
    for raw in env_file.read_text().splitlines():
        line = raw.split("#", 1)[0].rstrip()
        if not line.strip():
            continue
        if re.match(r"^channels:\s*$", line):
            in_channels = True
            continue
        if in_channels and not line.startswith((" ", "\t", "-")):
            break
        item = re.match(r"^\s*-\s+(\S+)\s*$", line) if in_channels else None
        if item:
            channels.append(item.group(1))
    if not channels:
        fail(f"{env_file.name} lists no channels")
    return channels


def content_hash(env_file: pathlib.Path) -> str:
    """A hash of what the solve reads: every line, less comments and blanks."""
    lines = []
    for raw in env_file.read_text().splitlines():
        line = raw.split("#", 1)[0].rstrip()
        if line.strip():
            lines.append(line)
    return hashlib.sha256("\n".join(lines).encode()).hexdigest()


def solve(env_file: pathlib.Path) -> list[dict]:
    micromamba = shutil.which("micromamba")
    if not micromamba:
        fail("micromamba is not on PATH (scripts/install-micromamba.sh installs the pinned one)")
    with tempfile.TemporaryDirectory() as root:
        try:
            completed = subprocess.run(
                [
                    micromamba, "create",
                    "--dry-run", "--json", "--yes",
                    "--name", "chickadee-lock-probe",
                    "--root-prefix", root,
                    "--platform", PLATFORM,
                    "--file", str(env_file),
                ],
                capture_output=True,
                text=True,
                timeout=SOLVE_TIMEOUT_SECONDS,
                check=False,
            )
        except subprocess.TimeoutExpired:
            fail(f"solving {env_file.name} did not finish within {SOLVE_TIMEOUT_SECONDS}s")
    if completed.returncode != 0:
        fail(f"solving {env_file.name} failed (exit {completed.returncode}):\n"
             f"{completed.stderr.strip()[-2000:]}")
    try:
        result = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        fail(f"solving {env_file.name} produced no JSON: {error}")
    links = result.get("actions", {}).get("LINK", []) if result.get("success") else []
    if not links:
        fail(f"solving {env_file.name} linked nothing")
    for package in links:
        # sha256 is required; md5 is recorded when the channel has one (some
        # emscripten-forge packages carry only sha256).
        for field in ("name", "version", "url", "sha256"):
            if not package.get(field):
                fail(f"solving {env_file.name}: {package.get('name', '?')} has no {field}, "
                     "so it cannot be locked")
    return links


def lock_document(env_file: pathlib.Path, links: list[dict]) -> dict:
    return {
        "version": 1,
        "metadata": {
            "content_hash": {PLATFORM: content_hash(env_file)},
            "channels": [{"url": url, "used_env_vars": []}
                         for url in environment_channels(env_file)],
            "platforms": [PLATFORM],
            "sources": [f"Tools/jupyterlite/{env_file.name}"],
        },
        "package": [
            {
                "name": p["name"],
                "version": p["version"],
                "manager": "conda",
                "platform": PLATFORM,
                "dependencies": {},
                "url": p["url"],
                "hash": {**({"md5": p["md5"]} if p.get("md5") else {}), "sha256": p["sha256"]},
                "category": "main",
                "optional": False,
            }
            for p in sorted(links, key=lambda p: p["name"])
        ],
    }


def write_locks() -> int:
    LOCK_DIR.mkdir(exist_ok=True)
    for env_file in environment_files():
        links = solve(env_file)
        path = lock_path(env_file)
        text = json.dumps(lock_document(env_file, links), indent=1) + "\n"
        changed = not path.is_file() or path.read_text() != text
        path.write_text(text)
        print(f"lock-kernel-envs: {path.relative_to(REPO_ROOT)}: {len(links)} packages"
              f"{'' if changed else ' (unchanged)'}")
    return 0


def locked_packages(lock: dict) -> tuple[dict[str, tuple[str, str]], list[str]]:
    """{name: (version, build)} from a lock, and the URLs it could not read."""
    packages, unreadable = {}, []
    for entry in lock.get("package", []):
        match = LOCKED_FILE.match(entry.get("url", "").rsplit("/", 1)[-1])
        if not match:
            unreadable.append(repr(entry.get("url")))
            continue
        packages[match["name"]] = (match["version"], match["build"])
    return packages, unreadable


def vendored_packages(env_name: str) -> dict[str, tuple[str, str]] | None:
    packages_dir = VENDORED_ROOT / env_name / "kernel_packages"
    if not packages_dir.is_dir():
        return None
    packages = {}
    for tarball in sorted(packages_dir.iterdir()):
        match = VENDORED_TARBALL.match(tarball.name)
        if match:
            packages[match["name"]] = (match["version"], match["build"])
    return packages


def check() -> int:
    failures = []
    for env_file in environment_files():
        path = lock_path(env_file)
        rel = path.relative_to(REPO_ROOT)
        if not path.is_file():
            failures.append(f"{env_file.name} has no lock at {rel}. "
                            "Run scripts/lock-kernel-envs.py.")
            continue
        try:
            lock = json.loads(path.read_text())
        except json.JSONDecodeError as error:
            failures.append(f"{rel} is not a readable lock ({error}). "
                            "Run scripts/lock-kernel-envs.py.")
            continue
        recorded = lock.get("metadata", {}).get("content_hash", {}).get(PLATFORM)
        if recorded != content_hash(env_file):
            failures.append(f"{rel} was made from a different {env_file.name}. "
                            "Run scripts/lock-kernel-envs.py to lock it again.")
            continue
        locked, unreadable = locked_packages(lock)
        if unreadable:
            failures.append(f"{rel}: cannot read a package file name from "
                            f"{', '.join(unreadable)}")
            continue
        if not locked:
            failures.append(f"{rel} locks no packages")
            continue
        env_name = environment_name(env_file)
        vendored = vendored_packages(env_name)
        if vendored is None:
            failures.append(f"{env_file.name} is locked but {env_name} is not vendored. "
                            "Re-vendor (.github/workflows/revendor-kernels.yml).")
            continue
        drift = []
        for name in sorted(set(locked) | set(vendored)):
            if locked.get(name) != vendored.get(name):
                drift.append(f"{name}: locked {_describe(locked.get(name))}, "
                             f"vendored {_describe(vendored.get(name))}")
        if drift:
            failures.append(f"the vendored {env_name} is not what {rel} locks. Re-vendor "
                            "(.github/workflows/revendor-kernels.yml):\n    "
                            + "\n    ".join(drift))
            continue
        print(f"lock-kernel-envs: OK ({rel}: {len(locked)} packages, "
              f"matching {env_file.name} and the vendored {env_name}).")
    for failure in failures:
        print(f"lock-kernel-envs: {failure}", file=sys.stderr)
    return 1 if failures else 0


def _describe(pair: tuple[str, str] | None) -> str:
    return f"{pair[0]} ({pair[1]})" if pair else "nothing"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    parser.add_argument("--check", action="store_true",
                        help="check the locks offline; needs neither micromamba nor network")
    args = parser.parse_args()
    return check() if args.check else write_locks()


if __name__ == "__main__":
    sys.exit(main())
