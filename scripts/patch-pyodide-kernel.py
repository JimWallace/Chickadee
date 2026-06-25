#!/usr/bin/env python3
"""Patch the bundled pyodide-kernel wheel's kernel-startup activation block.

The injected block does ONE thing now:

1. exec_hang FIX (synchronous): wrap `os.chdir` to create the target directory
   first. The notebook frontend chdir's the kernel into the notebook's Drive
   folder, which is absent from the kernel FS when the DriveFS service worker is
   disabled (our SAB-only isolation), so the bare chdir raises FileNotFoundError
   and wedges the cell execute forever (the production exec_hang). See the block
   comment for the full mechanism. (Applies identically on JupyterLite 0.7.6 and
   0.8 — the bug is the frontend chdir, not the kernel version.)

nb_mypy type-checking is DISABLED. It previously scheduled a background task that
ran nb_mypy's synchronous compiled-WASM `mypy.api.run(...)` before every cell, on
the kernel's single thread, which wedged the first cell execute in the real
editor (reproduced 5/5 on Chromium and WebKit, immediately AND after a 45s
settle — deferring the load did not help; the per-cell mypy run itself was the
cost). The activation is left empty rather than removed so re-enabling is a
one-line change and the sha-cascade machinery below is unchanged; revisit
type-checking only as a background/language-server feature that NEVER runs on
the cell-execute path. The nb_mypy / mypy / astor wheels stay vended in the
Pyodide lock (harmless, just unloaded).

JupyterLite has no config hook for "run Python at kernel startup", so we append
a fail-safe activation block to `pyodide_kernel/__init__.py` inside the
pyodide_kernel wheel that the pyodide-kernel labextension ships (the one
`jupyter lite build` bundles into Public/jupyterlite/.../pypi/).

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

FAIL-SAFE: the chdir wrapper swallows every exception, so even if makedirs/chdir
fails the kernel keeps running rather than dying at import.
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
# exec_hang FIX (synchronous — must run at kernel import, before the first cell
# execute). The JupyterLite notebook frontend sets the kernel's working directory
# to the notebook's Drive folder by running os.chdir("users/<uid>/<setup>/") on
# the first execute. That folder only exists in the kernel's Pyodide filesystem
# if the DriveFS is mounted, which needs the service worker we disable to run
# SAB-only under cross-origin isolation (SecurityHeadersMiddleware / #989/#1003).
# With no service worker the folder is absent, so chdir raises FileNotFoundError;
# that error is unhandled inside Pyodide's WebLoop, so the execute coroutine never
# completes and the cell wedges "[*]"-forever — the production exec_hang (~1 in 4
# students; 100% in the headless repro; students carrying a stale SW registration
# have a working DriveFS and never hit it, which is exactly the partial rate).
#
# Fix: make chdir create the target directory first. SAFE + TARGETED — when the
# DriveFS already provides the folder (the working majority) makedirs is a no-op
# and behaviour is unchanged; when it is missing the kernel runs in a (possibly
# empty) folder instead of hanging. (Support files the DriveFS would surface into
# that folder are a separate follow-up; a working kernel strictly beats a hung
# one.) Verified: 100% headless hang -> 0% with this patch.
try:  # pragma: no cover - exercised only in the in-browser kernel
    import os as _chickadee_os

    _chickadee_orig_chdir = _chickadee_os.chdir

    def _chickadee_chdir(path):
        try:
            _chickadee_os.makedirs(path, exist_ok=True)
        except Exception:  # noqa: BLE001
            pass
        return _chickadee_orig_chdir(path)

    _chickadee_os.chdir = _chickadee_chdir
except Exception:  # noqa: BLE001
    pass

# nb_mypy type-checking is DISABLED — intentionally NO code is injected here.
# It registered an IPython pre_run_cell hook that ran a synchronous compiled-WASM
# mypy on EVERY cell execute (on the kernel's single thread) and wedged the first
# cell; see the module docstring. The markers are kept so re-enabling is a
# one-line change and the sha cascade below is unchanged. The nb_mypy / mypy /
# astor wheels stay vended (harmless, just unloaded).
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
    print(f"patch-pyodide-kernel: chdir-fix activation injected (nb_mypy disabled) into {wheel.name}")


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
