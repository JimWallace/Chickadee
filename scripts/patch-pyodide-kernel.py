#!/usr/bin/env python3
"""Patch the bundled pyodide-kernel wheel to enable nb_mypy by default.

JupyterLite has no config hook for "run Python at kernel startup", so we append
a fail-safe activation block to `pyodide_kernel/__init__.py` inside the
pyodide_kernel wheel that the pyodide-kernel labextension ships (the one
`jupyter lite build` bundles into Public/jupyterlite/.../pypi/). At kernel boot
the editor then runs `%load_ext nb_mypy; %nb_mypy On` so mypy diagnostics show
on every cell — across every notebook, with no setup cell.

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

Idempotent (marker guard for the wheel; digest update always runs) and
deterministic (sorted entries + fixed timestamps + stable JSON) so the bundle
stays byte-stable → `git diff Public/jupyterlite` is clean.

FAIL-SAFE: the injected block swallows every exception, so a missing or
IPython-incompatible nb_mypy degrades to "no type warnings", never a dead
kernel. (A wheel that won't load at all is prevented by the sha cascade above.)
"""
from __future__ import annotations

import hashlib
import json
import pathlib
import sys
import zipfile

MARKER = "CHICKADEE_NB_MYPY_ACTIVATION"
TARGET_MEMBER = "pyodide_kernel/__init__.py"

ACTIVATION = '''

# --- {marker} -----------------------------------------------------------
# Enable nb_mypy type-checking by default for the in-browser editor. nb_mypy
# (+ mypy, astor) is preloaded via loadPyodideOptions in jupyter-lite.json.
# Fail-safe: NEVER let type-checking setup stop the kernel from starting.
try:  # pragma: no cover - exercised only in the in-browser kernel
    ipython_shell.run_line_magic("load_ext", "nb_mypy")
    ipython_shell.run_line_magic("nb_mypy", "On")
except Exception as _chickadee_nbmypy_err:  # noqa: BLE001
    import warnings as _chickadee_warnings

    _chickadee_warnings.warn(
        f"Chickadee: nb_mypy type-checking not enabled: {{_chickadee_nbmypy_err!r}}"
    )
# --- end {marker} -------------------------------------------------------
'''.format(marker=MARKER)

# Fixed timestamp for deterministic, byte-stable repacking across machines.
_FIXED_DATE = (1980, 1, 1, 0, 0, 0)


def fail(msg: str) -> None:
    print(f"patch-pyodide-kernel: FAIL — {msg}", file=sys.stderr)
    sys.exit(1)


def repack_wheel(wheel: pathlib.Path) -> None:
    """Append the activation block to __init__.py inside the wheel (idempotent)."""
    with zipfile.ZipFile(wheel) as zin:
        names = zin.namelist()
        if TARGET_MEMBER not in names:
            fail(f"{TARGET_MEMBER} not in {wheel.name}")
        members = {name: zin.read(name) for name in names}

    init_text = members[TARGET_MEMBER].decode("utf-8")
    if MARKER in init_text:
        print(f"patch-pyodide-kernel: wheel already patched ({wheel.name})")
        return
    members[TARGET_MEMBER] = (init_text + ACTIVATION).encode("utf-8")

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
    print(f"patch-pyodide-kernel: nb_mypy activation injected into {wheel.name}")


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
