#!/usr/bin/env python3
"""Patch the bundled pyodide-kernel wheel's `pyodide_kernel/__init__.py`.

nb_mypy type-checking is DISABLED: the injected activation block (below) now
contains NO code. It used to schedule a background task that ran nb_mypy's
synchronous compiled-WASM `mypy.api.run` before every cell, which wedged the
editor kernel on the first execute (the exec_hang) — see the block for details.
The block + its CHICKADEE_NB_MYPY_ACTIVATION markers are kept so re-enabling is a
one-line change and the sha-cascade machinery below is unchanged.

JupyterLite has no config hook for "run Python at kernel startup", so we append
the (now empty) activation block to `pyodide_kernel/__init__.py` inside the
pyodide_kernel wheel that the pyodide-kernel labextension ships (the one
`jupyter lite build` bundles into Public/jupyterlite/.../pypi/).

LAZY + NON-FATAL by design. nb_mypy is deliberately NOT listed in
`loadPyodideOptions.packages` (the kernel-boot critical path): a package named
there is loaded by `loadPyodide()` itself, so ANY failure (a bad PEP 503 lock
key, a future Pyodide bump dropping the wheel, an ABI mismatch) rejects the
boot and bricks the WHOLE editor — even though type-checking is only an
optional nicety. Instead the injected block schedules a background coroutine
that loads the wheel from the vended Pyodide lock (`pyodide.loadPackage`) AFTER
the kernel is up, then enables nb_mypy. The whole thing is wrapped so any
failure degrades to "no type warnings" while the kernel stays healthy.

Run from scripts/setup-jupyterlite.sh AFTER pip install and BEFORE the build, so
CI's rebuild applies the identical patch (reproducible).

CRITICAL — sha cascade: piplite verifies each wheel against the sha256 recorded
in the labextension's `all.json`, and the build derives the `pipliteUrls`
`?sha256=` from `all.json`. So after repacking the wheel we MUST rewrite its
`all.json` digest/size to match, or piplite rejects the wheel and the kernel
never loads. We update `all.json` here; the build then copies it verbatim and
recomputes the `pipliteUrls` sha. The result is fully consistent and
LOCALLY VERIFIABLE (wheel sha == all.json digest == pipliteUrls sha) without a
browser — see scripts/verify-jupyterlite.sh.

Re-patchable + deterministic: an existing activation block is stripped and
re-appended, so editing the block below and re-running yields identical bytes;
combined with sorted entries + fixed timestamps + stable JSON the bundle stays
byte-stable → `git diff Public/jupyterlite` is clean.

FAIL-SAFE: the injected block swallows every exception, so a missing or
IPython-incompatible nb_mypy degrades to "no type warnings", never a dead
kernel. Because the load is off the boot critical path, even a wheel that
cannot be fetched/loaded at all no longer takes the kernel down with it.
"""
from __future__ import annotations

import hashlib
import json
import pathlib
import sys
import zipfile

MARKER = "CHICKADEE_NB_MYPY_ACTIVATION"
TARGET_MEMBER = "pyodide_kernel/__init__.py"

# NOTE: a plain string literal (not str.format) so the f-strings and braces in
# the emitted Python below need no escaping; the marker comments embed MARKER
# verbatim and _strip_activation() locates them by that text.
ACTIVATION = '''

# --- CHICKADEE_NB_MYPY_ACTIVATION -----------------------------------------------------------
# nb_mypy type-checking is DISABLED — deliberately injects NO code.
#
# nb_mypy registered an IPython `pre_run_cell` hook that ran a full, synchronous,
# compiled-WASM `mypy.api.run(...)` before EVERY cell, on the kernel's single
# thread. In the real notebook editor the first cell execute wedged the kernel
# ("[*]" forever — the exec_hang ~1 in 4 students hit on lab day). It reproduced
# deterministically in CI (Tools/editor-smoke-test/editor-exec-check.mjs): on
# both Chromium and WebKit, the first editor-cell execute hung 5/5 whether run
# immediately at idle OR after a 45s settle — so deferring the background load
# does not help, the per-cell mypy run itself is the cost. In the race case the
# background load colliding with the execute could even fatally crash Pyodide
# ("JSON Parse error: Unterminated string").
#
# So the activation is removed. The nb_mypy / mypy / astor wheels stay vended in
# the Pyodide lock (harmless, just unloaded) so this is a one-line revert if a
# non-blocking design lands. Revisit type-checking as a background-worker /
# language-server feature that NEVER runs on the cell-execute path.
# --- end CHICKADEE_NB_MYPY_ACTIVATION -------------------------------------------------------
'''

# Fixed timestamp for deterministic, byte-stable repacking across machines.
_FIXED_DATE = (1980, 1, 1, 0, 0, 0)


def fail(msg: str) -> None:
    print(f"patch-pyodide-kernel: FAIL — {msg}", file=sys.stderr)
    sys.exit(1)


def _strip_activation(text: str) -> str:
    """Return the wheel's __init__.py with any prior activation block removed.

    The block is always appended at end-of-file between the marker delimiters,
    so we cut from the start delimiter onward and restore the single trailing
    newline the upstream file ends with. This makes the patch re-patchable:
    editing ACTIVATION and re-running reproduces a fresh-patch byte-for-byte.
    """
    start = text.find(f"# --- {MARKER} ")
    if start == -1:
        return text
    return text[:start].rstrip() + "\n"


def repack_wheel(wheel: pathlib.Path) -> None:
    """Inject (or refresh) the activation block in __init__.py inside the wheel."""
    with zipfile.ZipFile(wheel) as zin:
        names = zin.namelist()
        if TARGET_MEMBER not in names:
            fail(f"{TARGET_MEMBER} not in {wheel.name}")
        members = {name: zin.read(name) for name in names}

    init_text = members[TARGET_MEMBER].decode("utf-8")
    patched = _strip_activation(init_text) + ACTIVATION
    members[TARGET_MEMBER] = patched.encode("utf-8")

    # Repack with ZIP_STORED (no compression): unlike DEFLATE, stored bytes have
    # no zlib-version variability, so the wheel is byte-identical on macOS (dev)
    # and Linux (CI). Combined with fixed timestamps and sorted entries, the
    # repack is fully deterministic → CI's rebuild matches the committed bundle.
    with zipfile.ZipFile(wheel, "w", zipfile.ZIP_STORED) as zout:
        for name in sorted(members):
            info = zipfile.ZipInfo(filename=name, date_time=_FIXED_DATE)
            info.compress_type = zipfile.ZIP_STORED
            info.external_attr = 0o644 << 16
            zout.writestr(info, members[name])
    print(f"patch-pyodide-kernel: nb_mypy activation block (DISABLED) written into {wheel.name}")


def refresh_all_json(pypi_dir: pathlib.Path, wheel: pathlib.Path) -> None:
    """Rewrite the wheel's digest/size in all.json so piplite accepts it."""
    all_json = pypi_dir / "all.json"
    if not all_json.exists():
        fail(f"all.json not found next to the wheel ({all_json})")

    data = wheel.read_bytes()
    sha256 = hashlib.sha256(data).hexdigest()
    md5 = hashlib.md5(data).hexdigest()  # noqa: S324 (informational, not security)
    size = len(data)

    index = json.loads(all_json.read_text())
    updated = 0
    for pkg in index.values():
        for files in pkg.get("releases", {}).values():
            for entry in files:
                if entry.get("filename") == wheel.name:
                    entry["digests"] = {"md5": md5, "sha256": sha256}
                    entry["md5_digest"] = md5
                    entry["size"] = size
                    updated += 1
    if updated == 0:
        fail(f"no all.json entry references {wheel.name}")

    all_json.write_text(json.dumps(index, separators=(", ", ": ")))
    print(f"patch-pyodide-kernel: all.json digest refreshed (sha256={sha256[:12]}…, {updated} entry)")


def main() -> None:
    if len(sys.argv) != 2:
        print("usage: patch-pyodide-kernel.py <labextension-pypi-dir>", file=sys.stderr)
        sys.exit(2)
    pypi_dir = pathlib.Path(sys.argv[1])
    matches = sorted(pypi_dir.glob("pyodide_kernel-*.whl"))
    if not matches:
        fail(f"no pyodide_kernel-*.whl in {pypi_dir}")
    wheel = matches[0]

    repack_wheel(wheel)
    refresh_all_json(pypi_dir, wheel)
    print(f"patch-pyodide-kernel: OK ({wheel.name})")


if __name__ == "__main__":
    main()
