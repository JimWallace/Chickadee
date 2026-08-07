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
# Lua's two install roots: `share/lua/<ver>/` for pure-Lua modules and
# `lib/lua/<ver>/` for C ones. `require("a.b")` maps to `a/b.lua`, so only the
# FIRST path component is a top-level name — matching how the Python scan treats
# site-packages entries.
LUA_LIBRARY = re.compile(r"^(?:share|lib)/lua/\d+\.\d+/(?P<entry>[^/]+)")
# Octave Forge packages install under `share/octave/packages/<name>-<version>/`
# (m-files) and `lib/octave/packages/<name>-<version>/` (compiled oct-files);
# the `<name>` half is what `pkg load <name>` takes.
OCTAVE_PACKAGE = re.compile(r"^(?:share|lib)/octave/packages/(?P<entry>[^/]+?)(?:-[0-9][^/]*)?/")
# The interpreter's own bundled function files, grouped by topic directory —
# `share/octave/<version>/m/<group>/...`. Not loadable names (they are simply
# on the load path at start), but they are what proves an Octave index was
# derived from real bytes when the package half is empty.
OCTAVE_BUNDLED_GROUP = re.compile(r"^share/octave/\d[^/]*/m/(?P<entry>[^/]+)/")
STDLIB = re.compile(r"^lib/python3\.\d+/(?P<entry>[^/]+)$")
STDLIB_DIR = re.compile(r"^lib/python3\.\d+/(?P<entry>[^/]+)/")

# Directory entries under site-packages that are metadata, not importable.
NOT_A_MODULE = re.compile(r"\.(dist-info|egg-info|egg-link|pth)$|^__pycache__$")

# Lua 5.4's standard libraries, which `require` resolves out of
# `package.loaded` without touching the filesystem.
LUA_STDLIB = [
    "coroutine", "debug", "io", "math", "os", "package", "string", "table", "utf8",
]


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


def owner_of(meta: dict) -> dict[str, str]:
    """Tarball filename → the conda package name that ships it."""
    return {p["filename"]: p["name"] for p in meta.get("packages", [])}


def scan_r(env_dir: pathlib.Path, meta: dict) -> tuple[set[str], dict[str, str]]:
    """(`library()`-able names, name → owning conda package) from this R env."""
    packages = env_dir / "kernel_packages"
    if not packages.is_dir():
        sys.exit(f"derive-kernel-modules: no kernel_packages under {env_dir}")
    by_file = owner_of(meta)
    found: set[str] = set()
    owners: dict[str, str] = {}
    for archive in sorted(packages.glob("*.tar.gz")):
        owner = by_file.get(archive.name)
        with tarfile.open(archive, "r:gz") as tar:
            for name in tar.getnames():
                if match := R_LIBRARY.match(name):
                    entry = match.group("entry")
                    if entry and not entry.startswith("."):
                        found.add(entry)
                        if owner:
                            owners.setdefault(entry, owner)
    return found, owners


def scan_lua(env_dir: pathlib.Path, meta: dict) -> tuple[set[str], dict[str, str]]:
    """(`require`-able names, name → owning conda package) from this Lua env.

    Expected to come back EMPTY, and that is the correct answer rather than a
    bug: emscripten-forge carries no Lua library packages, so the vendored env
    is the kernel and nothing else. An empty `moduleOwners` is what makes the
    browser grader's on-demand install path correctly resolve nothing and let a
    `require` failure stand as the plain error a student needs to see.

    Written as a real scan anyway — if a Lua package ever appears on the
    channel, this picks it up with no further work, and a scan that hard-coded
    "empty" would silently keep saying so.
    """
    packages = env_dir / "kernel_packages"
    if not packages.is_dir():
        sys.exit(f"derive-kernel-modules: no kernel_packages under {env_dir}")
    by_file = owner_of(meta)
    found: set[str] = set()
    owners: dict[str, str] = {}
    def lua_module_name(entry: str) -> str | None:
        # `foo.lua` and `foo.so` are modules; `foo/` is the package `foo` (its
        # submodules are `foo.bar`, which `require` resolves through the
        # directory rather than as separate top-level names). Anything else with
        # a dot in it is not a Lua module name. Deliberately NOT module_name(),
        # which is Python-shaped and would drop `foo.lua` for having a dot.
        stem = entry
        for suffix in (".lua", ".so"):
            if entry.endswith(suffix):
                stem = entry[: -len(suffix)]
                break
        if "." in stem or not stem:
            return None
        return stem

    for archive in sorted(packages.glob("*.tar.gz")):
        owner = by_file.get(archive.name)
        with tarfile.open(archive, "r:gz") as tar:
            for name in tar.getnames():
                if match := LUA_LIBRARY.match(name):
                    if resolved := lua_module_name(match.group("entry")):
                        found.add(resolved)
                        if owner:
                            owners.setdefault(resolved, owner)
    return found, owners


def scan_octave(env_dir: pathlib.Path, meta: dict) -> tuple[set[str], set[str], dict[str, str]]:
    """(`pkg load`-able names, bundled function-file groups, name → owning package).

    The loadable half is expected to come back EMPTY, as Lua's scan is:
    emscripten-forge carries no Octave Forge packages, so there is nothing `pkg
    load` could take and an empty `moduleOwners` is what makes the browser
    grader's on-demand install path correctly resolve nothing. Written as a
    real scan of the Forge install roots anyway, so a package appearing on the
    channel is picked up with no further work.

    The bundled groups (`share/octave/<ver>/m/<group>/` — elfun, statistics,
    strings, …) fill the same role Lua's compiled-in stdlib list does: they are
    not loadable names, but they are derived from the vendored bytes, so an
    index that lists none of them means the scan never ran — which is exactly
    the state check-xeus-vendored.sh exists to catch.
    """
    packages = env_dir / "kernel_packages"
    if not packages.is_dir():
        sys.exit(f"derive-kernel-modules: no kernel_packages under {env_dir}")
    by_file = owner_of(meta)
    found: set[str] = set()
    bundled: set[str] = set()
    owners: dict[str, str] = {}
    for archive in sorted(packages.glob("*.tar.gz")):
        owner = by_file.get(archive.name)
        with tarfile.open(archive, "r:gz") as tar:
            for name in tar.getnames():
                if match := OCTAVE_PACKAGE.match(name):
                    entry = match.group("entry")
                    if entry and not entry.startswith("."):
                        found.add(entry)
                        if owner:
                            owners.setdefault(entry, owner)
                elif match := OCTAVE_BUNDLED_GROUP.match(name):
                    entry = match.group("entry")
                    if entry and not entry.startswith("."):
                        bundled.add(entry)
    return found, bundled, owners


def scan(env_dir: pathlib.Path, meta: dict) -> tuple[set[str], set[str], dict[str, str]]:
    """(package modules, stdlib modules, module → owning conda package)."""
    packages = env_dir / "kernel_packages"
    if not packages.is_dir():
        sys.exit(f"derive-kernel-modules: no kernel_packages under {env_dir}")

    by_file = owner_of(meta)
    package_modules: set[str] = set()
    stdlib_modules: set[str] = set()
    owners: dict[str, str] = {}

    for archive in sorted(packages.glob("*.tar.gz")):
        is_python_itself = archive.name.startswith("python-3.")
        owner = by_file.get(archive.name)
        with tarfile.open(archive, "r:gz") as tar:
            for name in tar.getnames():
                if match := SITE_PACKAGES.match(name):
                    if resolved := module_name(match.group("entry")):
                        package_modules.add(resolved)
                        if owner:
                            owners.setdefault(resolved, owner)
                elif is_python_itself:
                    match = STDLIB.match(name) or STDLIB_DIR.match(name)
                    if not match:
                        continue
                    entry = match.group("entry")
                    if entry in {"site-packages", "lib-dynload", "config"}:
                        continue
                    if resolved := module_name(entry):
                        stdlib_modules.add(resolved)

    return package_modules, stdlib_modules, owners


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(f"usage: {sys.argv[0]} <path to a vendored xeus env directory>")
    env_dir = pathlib.Path(sys.argv[1])
    meta_path = env_dir / "empack_env_meta.json"
    if not meta_path.is_file():
        sys.exit(f"derive-kernel-modules: not a vendored env (no {meta_path})")

    meta = json.loads(meta_path.read_text())

    # Which language this env is, from the env's OWN package list rather than
    # its directory name, so a renamed env still works. `xeus-lua` rather than
    # `lua`: the kernel statically links the interpreter, so there is no
    # separate `lua` package to key on.
    if any(p["name"] == "xeus-lua" for p in meta.get("packages", [])):
        lua_modules, lua_owners = scan_lua(env_dir, meta)
        write_index(
            env_dir,
            meta,
            modules=sorted(lua_modules),
            # Lua's standard libraries are compiled into the interpreter and
            # pre-populated in `package.loaded`, so they appear in no tarball —
            # the same reason Python's C extension modules need
            # `sys.stdlib_module_names`. There is no host Lua to ask, and the
            # list is fixed by the language version, so it is written out.
            stdlib=LUA_STDLIB,
            host_python=None,
            module_owners=lua_owners,
        )
        return

    # Octave: keyed on the kernel package for the same reason as Lua — the
    # interpreter arrives as the `octave` package, but the kernel is what makes
    # this an Octave env rather than an env that happens to contain Octave.
    if any(p["name"] == "xeus-octave" for p in meta.get("packages", [])):
        octave_modules, octave_bundled, octave_owners = scan_octave(env_dir, meta)
        write_index(
            env_dir,
            meta,
            modules=sorted(octave_modules),
            stdlib=sorted(octave_bundled),
            host_python=None,
            module_owners=octave_owners,
        )
        return

    # R is the simpler half and shares only the file's shape.
    if any(p["name"] == "r-base" for p in meta.get("packages", [])):
        r_modules, r_owners = scan_r(env_dir, meta)
        write_index(
            env_dir,
            meta,
            modules=sorted(r_modules),
            stdlib=[],
            host_python=None,
            module_owners=r_owners,
        )
        return

    package_modules, stdlib_from_tarball, owners = scan(env_dir, meta)
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
        module_owners=owners,
    )


def write_index(
    env_dir: pathlib.Path,
    meta: dict,
    modules: list[str],
    stdlib: list[str],
    host_python: str | None,
    kernel_python: str | None = None,
    module_owners: dict[str, str] | None = None,
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
        # Which conda package ships each importable name. The browser grader
        # boots a SUBSET of the environment and installs the rest on demand, so
        # when the kernel reports `ModuleNotFoundError: No module named 'X'` it
        # needs to turn X back into a package before it can fetch anything. The
        # mapping is a by-product of the scan above — the tarball being read IS
        # the answer — so it costs nothing and cannot drift from the bytes.
        #
        # Names are import names, not distribution names: `PIL` maps to
        # `pillow` and `matplotlib` to `matplotlib-base`, which is correct —
        # `matplotlib-base` is the package that actually ships the module, and
        # its closure is what has to be installed.
        "moduleOwners": dict(sorted((module_owners or {}).items())),
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
