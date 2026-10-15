#!/usr/bin/env python3
"""Remove build-only files from the vendored xeus kernel packages.

A kernel fetches every tarball in its `kernel_packages/` at boot and unpacks
all of it into the browser's memory. empack's default filter keeps files that
no kernel reads at run time:

- static archives (`*.a`): Octave's `liboctinterp.a` and `liboctave.a` alone
  are 62 MB unpacked, and OpenBLAS ships two 14 MB copies;
- top-level C headers (`include/`) and pkg-config and CMake files;
- manual pages and `share/doc`;
- CPython's own test suite (`lib/python3.X/test/`), which arrives in the Lua
  and Octave environments as a dependency and is never run;
- a second copy of each kernel shared library. A kernel's `kernel.json` lists
  these under `metadata.shared`, and the xeus loader fetches them from the
  kernel directory (`xoctave/liboctave.so`), not from the unpacked package.
  The loader adds `lib/libxeus.so` to that list for every kernel. The copy in
  the package is never read. For Octave this is 52 MB.

Each archive that loses a file is rewritten, and then renamed to carry the hash
of its new bytes, through `content_address` in `patch-xeus-python-http.py`.
The server caches `kernel_packages/` as immutable, so a name must never get
new bytes (`check-xeus-vendored.sh` section 9). The rewrite is reproducible:
the same input gives the same bytes, so a re-vendor that does not change a
package does not rename it.

`check-xeus-vendored.sh` imports `prunable` from this file and fails if any
vendored archive still holds a file that it matches.

Idempotent. Usage: prune-kernel-packages.py <jupyterlite-build-dir>
"""

from __future__ import annotations

import gzip
import importlib.util
import json
import os
import pathlib
import re
import sys
import tarfile
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Paths are relative to the environment prefix, as the archive stores them.
BUILD_ONLY_PREFIXES = (
    "include/",
    "lib/pkgconfig/",
    "lib/cmake/",
    "share/pkgconfig/",
    "share/man/",
    "share/doc/",
)
CPYTHON_TEST_SUITE = re.compile(r"lib/python3\.\d+/test/")


# The xeus loader adds this one to every kernel's list (`initializeModule` in
# the xeus extension) and fetches it from the environment directory.
XEUS_SHARED_LIBRARY = "lib/libxeus.so"


def kernel_shared_libraries(env_dir: pathlib.Path) -> set[str] | None:
    """The prefix paths that the kernels in this environment load from outside
    the unpacked packages: `metadata.shared` in each `kernel.json`, plus
    libxeus. None when the environment has no kernel.json."""
    specs = sorted(env_dir.glob("*/kernel.json"))
    if not specs:
        return None
    shared = {XEUS_SHARED_LIBRARY}
    for spec_path in specs:
        spec = json.loads(spec_path.read_text())
        shared.update(spec.get("metadata", {}).get("shared", {}).values())
    return shared


def prunable(name: str, shared: set[str]) -> bool:
    """True for an archive member that no kernel reads at run time."""
    return (
        name.endswith(".a")
        or name.startswith(BUILD_ONLY_PREFIXES)
        or CPYTHON_TEST_SUITE.match(name) is not None
        or name in shared
    )


def load_content_address():
    # Import without writing a .pyc into scripts/__pycache__.
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location(
        "patch_xeus_python_http", ROOT / "scripts" / "patch-xeus-python-http.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.content_address


def prune_archive(archive: pathlib.Path, shared: set[str]) -> int:
    """Rewrite one archive without its prunable members. Returns the number of
    bytes removed, or 0 when the archive holds nothing to remove."""
    with tarfile.open(archive, "r:gz") as source:
        members = source.getmembers()
        removed = [m for m in members if m.isfile() and prunable(m.name, shared)]
        if not removed:
            return 0
        removed_names = {m.name for m in removed}
        # A link to a removed file would be written back dangling. No vendored
        # archive has a link today, so stop and make a person decide.
        for member in members:
            if (member.issym() or member.islnk()) and (
                prunable(member.name, shared) or member.linkname in removed_names
            ):
                sys.exit(f"prune-kernel-packages: {archive.name}: {member.name} is a link "
                         "to a file this step removes — decide how to handle it")
        # Keep the member order and metadata. A fixed gzip mtime makes the
        # output depend on the content only (see the module docstring).
        handle, temp_name = tempfile.mkstemp(dir=archive.parent, suffix=".tmp")
        try:
            with os.fdopen(handle, "wb") as raw, gzip.GzipFile(
                fileobj=raw, mode="wb", mtime=0
            ) as gz, tarfile.open(fileobj=gz, mode="w") as out:
                for member in members:
                    if member.name in removed_names:
                        continue
                    data = source.extractfile(member) if member.isfile() else None
                    out.addfile(member, data)
            os.replace(temp_name, archive)
        except BaseException:
            pathlib.Path(temp_name).unlink(missing_ok=True)
            raise
    return sum(m.size for m in removed)


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit("usage: prune-kernel-packages.py <jupyterlite-build-dir>")
    xeus = pathlib.Path(sys.argv[1]) / "xeus"
    if not xeus.is_dir():
        print("prune-kernel-packages: no xeus/ in build — nothing to prune.")
        return
    content_address = load_content_address()
    for env_dir in sorted(p for p in xeus.glob("chickadee-*") if p.is_dir()):
        shared = kernel_shared_libraries(env_dir)
        if shared is None:
            sys.exit(f"prune-kernel-packages: {env_dir.name} has no kernel.json "
                     "— the kernel layout changed")
        total = 0
        for archive in sorted((env_dir / "kernel_packages").glob("*.tar.gz")):
            removed = prune_archive(archive, shared)
            if removed:
                renamed = content_address(archive)
                print(f"prune-kernel-packages: {env_dir.name}/{renamed.name}: "
                      f"removed {removed / 2**20:.1f} MB")
                total += removed
        print(f"prune-kernel-packages: {env_dir.name}: removed {total / 2**20:.1f} MB "
              "unpacked in all")


if __name__ == "__main__":
    main()
