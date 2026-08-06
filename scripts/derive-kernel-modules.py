#!/usr/bin/env python3
"""Derive the set of importable top-level module names from a vendored xeus env.

Writes `importable-modules.json` next to the env's `empack_env_meta.json`.

Why this exists
---------------
Pyodide resolved imports at run time from a ~363-package index. A xeus env is
fixed when the kernel is built, and under the editor's `connect-src 'self'` CSP
there is no runtime install escape hatch — so anything not baked in is an
unrecoverable `ImportError`, and for a graded test that means it surfaces when a
student submits rather than when an instructor saves.

Knowing the package set at authoring time is what turns that into a save-time
error. The server reads this file to do exactly that.

Why it reads the tarballs and not `environment-python.yml`
----------------------------------------------------------
The env file states an *intent*; the vendored `kernel_packages/` are what
actually ships. Those diverge whenever someone adds a dependency without
re-running `scripts/build-jupyterlite.sh` — which is now
.github/workflows/revendor-kernels.yml, but is still a deliberate act rather
than part of the ordinary build. Deriving from the env file
would accept `import scipy` while the shipped kernel has no scipy — precisely
the grade-time failure this is meant to prevent. Deriving from the bytes cannot
over-promise, and starts allowing a package the moment it is really vendored.

It also sidesteps the distribution-name-vs-import-name problem entirely: the
tarball says `site-packages/sklearn`, so there is no `scikit-learn` → `sklearn`
table to maintain and get wrong.

Stdlib names
------------
The env's python tarball carries the stdlib `.py` modules, but its C extension
modules are statically linked into the wasm binary and appear in no file list.
So the stdlib set is the union of the tarball's own modules and this
interpreter's `sys.stdlib_module_names` (which includes builtins). That union is
deliberately PERMISSIVE: it may include a module emscripten does not really
support (`multiprocessing`), which means a missed catch. The opposite error —
rejecting a save over a stdlib import that works fine — is much worse, because
it blocks an instructor from doing legitimate work.

Usage:
    scripts/derive-kernel-modules.py Public/jupyterlite/xeus/chickadee-python
"""

from __future__ import annotations

import json
import pathlib
import re
import sys
import tarfile

SITE_PACKAGES = re.compile(r"^lib/python3\.\d+/site-packages/(?P<entry>[^/]+)")
# R installs every package — base and add-on alike — under one directory, so an
# R env needs no stdlib/site-packages distinction and, unlike Python, no help
# from the building interpreter at all: `library(stats)` and `library(dplyr)`
# are both just directories here.
R_LIBRARY = re.compile(r"^lib/R/library/(?P<entry>[^/]+)")
STDLIB = re.compile(r"^lib/python3\.\d+/(?P<entry>[^/]+)$")
STDLIB_DIR = re.compile(r"^lib/python3\.\d+/(?P<entry>[^/]+)/")

# Directory entries under site-packages that are metadata, not importable.
NOT_A_MODULE = re.compile(r"\.(dist-info|egg-info|egg-link|pth)$|^__pycache__$")


def module_name(entry: str) -> str | None:
    """The importable name for a site-packages/stdlib directory entry."""
    if NOT_A_MODULE.search(entry):
        return None
    if entry.endswith(".py"):
        stem = entry[:-3]
        return stem if stem.isidentifier() else None
    # Extension modules: `foo.cpython-313-wasm32-emscripten.so` → `foo`.
    if entry.endswith(".so"):
        stem = entry.split(".")[0]
        return stem if stem.isidentifier() else None
    if "." in entry:
        return None
    return entry if entry.isidentifier() else None


def scan_r(env_dir: pathlib.Path) -> set[str]:
    """Package names `library()`-able from this R env's tarballs."""
    packages = env_dir / "kernel_packages"
    if not packages.is_dir():
        sys.exit(f"derive-kernel-modules: no kernel_packages under {env_dir}")
    found: set[str] = set()
    for archive in sorted(packages.glob("*.tar.gz")):
        with tarfile.open(archive, "r:gz") as tar:
            for name in tar.getnames():
                if match := R_LIBRARY.match(name):
                    entry = match.group("entry")
                    if entry and not entry.startswith("."):
                        found.add(entry)
    return found


def scan(env_dir: pathlib.Path) -> tuple[set[str], set[str]]:
    """(package modules, stdlib modules) importable from this env's tarballs."""
    packages = env_dir / "kernel_packages"
    if not packages.is_dir():
        sys.exit(f"derive-kernel-modules: no kernel_packages under {env_dir}")

    package_modules: set[str] = set()
    stdlib_modules: set[str] = set()

    for archive in sorted(packages.glob("*.tar.gz")):
        is_python_itself = archive.name.startswith("python-3.")
        with tarfile.open(archive, "r:gz") as tar:
            for name in tar.getnames():
                if match := SITE_PACKAGES.match(name):
                    if resolved := module_name(match.group("entry")):
                        package_modules.add(resolved)
                elif is_python_itself:
                    match = STDLIB.match(name) or STDLIB_DIR.match(name)
                    if not match:
                        continue
                    entry = match.group("entry")
                    if entry in {"site-packages", "lib-dynload", "config"}:
                        continue
                    if resolved := module_name(entry):
                        stdlib_modules.add(resolved)

    return package_modules, stdlib_modules


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(f"usage: {sys.argv[0]} <path to a vendored xeus env directory>")
    env_dir = pathlib.Path(sys.argv[1])
    meta_path = env_dir / "empack_env_meta.json"
    if not meta_path.is_file():
        sys.exit(f"derive-kernel-modules: not a vendored env (no {meta_path})")

    meta = json.loads(meta_path.read_text())

    # R is the simpler half and shares only the file's shape. Detected from the
    # env's own package list rather than its directory name, so a renamed env
    # still works.
    if any(p["name"] == "r-base" for p in meta.get("packages", [])):
        write_index(env_dir, meta, modules=sorted(scan_r(env_dir)), stdlib=[], host_python=None)
        return

    package_modules, stdlib_from_tarball = scan(env_dir)
    stdlib = sorted(stdlib_from_tarball | set(sys.stdlib_module_names))

    # The tarball supplies the env's pure-Python stdlib; `sys.stdlib_module_names`
    # supplies the C extension modules, which are statically linked into the wasm
    # and appear in no file list. That second half comes from THIS interpreter, so
    # a host whose minor version differs from the kernel's yields a slightly
    # different list — measured: 314 names on a 3.11 host, 308 on 3.12, for the
    # same 3.13 kernel. (Not monotonic: an older host contributes names 3.13 has
    # since removed, and misses ones it added.)
    #
    # Both directions are tolerable, but not equally: extra names are a missed
    # catch, while missing ones make the authoring import check reject a stdlib
    # import that actually works. Warn rather than fail — an approximate list
    # still beats none, and a maintainer on the wrong interpreter should not be
    # blocked from rebuilding. The re-vendor workflow pins the matching version.
    env_python = next(
        (p["version"] for p in meta.get("packages", []) if p["name"] == "python"), None
    )
    host_python = f"{sys.version_info.major}.{sys.version_info.minor}"
    if env_python and not env_python.startswith(host_python + "."):
        print(
            f"derive-kernel-modules: WARNING host Python is {host_python} but the "
            f"{env_dir.name} kernel is {env_python}. The stdlib list is derived "
            "partly from this interpreter, so it may be missing names the kernel "
            "has. Rebuild on a matching interpreter for an exact list.",
            file=sys.stderr,
        )

    write_index(
        env_dir,
        meta,
        modules=sorted(package_modules),
        stdlib=stdlib,
        host_python=host_python,
        kernel_python=env_python,
    )


def write_index(
    env_dir: pathlib.Path,
    meta: dict,
    modules: list[str],
    stdlib: list[str],
    host_python: str | None,
    kernel_python: str | None = None,
) -> None:
    """Write `importable-modules.json` for either language."""
    out = {
        "_comment": (
            "GENERATED by scripts/derive-kernel-modules.py from this directory's "
            "kernel_packages/. Do not hand-edit — re-run the script after "
            "re-vendoring the kernel. Asserted by scripts/check-xeus-vendored.sh."
        ),
        "env": meta.get("prefix") and env_dir.name or env_dir.name,
        "specs": sorted(meta.get("specs", [])),
        "packages": sorted({p["name"] for p in meta.get("packages", [])}),
        "modules": modules,
        "stdlibModules": stdlib,
        # Recorded because the Python stdlib list depends on it (see above), so
        # a surprising diff has a visible cause rather than looking like drift.
        # Both are null for R, which derives entirely from the tarballs.
        "derivedOnPython": host_python,
        "kernelPython": kernel_python,
    }

    destination = env_dir / "importable-modules.json"
    destination.write_text(json.dumps(out, indent=2) + "\n")
    print(
        f"derive-kernel-modules: {destination} "
        f"({len(out['modules'])} package modules, {len(stdlib)} stdlib)"
    )


if __name__ == "__main__":
    main()
