#!/usr/bin/env python3
"""FIPPA guard: the JupyterLite editor kernel must boot with ZERO external fetches.

Chickadee serves one canonical, locally-vended Pyodide and blocks all runtime
network egress (CSP `connect-src 'self'`, `disablePyPIFallback: true`).  That
means every module the editor kernel imports at startup MUST be satisfiable from
the local distribution.  If it is not, the kernel's import hook falls through to
`piplite.install(...)` -> the CDN/PyPI, which under FIPPA is blocked and the
kernel dies (the v0.4.292 `comm` outage: pyodide_kernel imports `comm`, which was
in neither the lock nor the piplite index, so the editor crashed with
"Can't find a pure Python 3 wheel for: 'comm'").

The kernel wheels (pyodide_kernel, ipykernel) declare NO Requires-Dist, so a
metadata-based check would miss this entire class.  Instead we scan the kernel
wheels' MODULE-LEVEL imports (the ones that run at kernel boot) and assert each
third-party module is provided by a locally-available package — the vended
pyodide-lock (its `imports` lists), the piplite index, the kernel's own
packages, or the Python stdlib.  Anything else would require a network fetch.

Reads only checked-in artifacts (no venv / browser / rebuild), so it is cheap
enough to run on every PR in the JupyterLite CI job.
"""
from __future__ import annotations

import json
import pathlib
import re
import sys
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
LOCK = ROOT / "Public" / "pyodide" / "pyodide-lock.json"
KERNEL_PYPI = (
    ROOT
    / "Public"
    / "jupyterlite"
    / "extensions"
    / "@jupyterlite"
    / "pyodide-kernel-extension"
    / "static"
    / "pypi"
)

# Wheels whose startup imports run when the editor kernel boots.
KERNEL_WHEEL_GLOBS = ("pyodide_kernel-*.whl", "ipykernel-*.whl")

# Modules the Pyodide runtime / JupyterLite kernel provide intrinsically — they
# never trigger an install (built into the runtime or the kernel labextension).
RUNTIME_PROVIDED = {
    "pyodide",
    "pyodide_js",
    "_pyodide",
    "js",
    "micropip",
    "piplite",
    "pyodide_kernel",
    "ipykernel",
    "widgetsnbextension",
}


def fail(msg: str) -> None:
    print(f"kernel-deps-vendored: FAIL — {msg}", file=sys.stderr)
    sys.exit(1)


def locally_available_modules() -> set[str]:
    """Every importable module name satisfiable without a network fetch."""
    available: set[str] = set(sys.stdlib_module_names) | RUNTIME_PROVIDED
    lock = json.loads(LOCK.read_text())["packages"]
    for entry in lock.values():
        # A package contributes the import names it declares it provides.
        available.update(entry.get("imports", []))
        # Fall back to the canonical key as a module name for the common case
        # where a package's import name equals its (normalized) project name.
        available.add(re.sub(r"[-_.]+", "_", entry["name"]))
    return available


def kernel_startup_imports() -> dict[str, str]:
    """Top-level (module-load-time) third-party imports in the kernel wheels.

    Only column-0 imports are collected: those execute at import time and so
    fail the kernel at boot.  Imports nested in functions / `try` blocks are
    lazy or guarded and intentionally ignored.
    """
    found: dict[str, str] = {}
    wheels = [w for g in KERNEL_WHEEL_GLOBS for w in KERNEL_PYPI.glob(g)]
    if not wheels:
        fail(f"no kernel wheels ({', '.join(KERNEL_WHEEL_GLOBS)}) under {KERNEL_PYPI}")
    for wheel in wheels:
        with zipfile.ZipFile(wheel) as zf:
            for name in zf.namelist():
                if not name.endswith(".py"):
                    continue
                text = zf.read(name).decode("utf-8", "ignore")
                for line in text.splitlines():
                    if not line or line[0].isspace():
                        continue  # indented => lazy/guarded, not a boot import
                    mod = None
                    if line.startswith("import "):
                        mod = line[len("import ") :].split()[0]
                    elif line.startswith("from ") and " import " in line:
                        mod = line[len("from ") :].split(" import")[0].strip()
                    if not mod:
                        continue
                    top = mod.split(".")[0].split(",")[0].strip()
                    if top and top.isidentifier():
                        found.setdefault(top, f"{wheel.name}:{name}")
    return found


def main() -> None:
    if not LOCK.exists():
        fail(f"vendored Pyodide lock not found at {LOCK} (run scripts/setup-vendor.sh)")
    available = locally_available_modules()
    required = kernel_startup_imports()
    missing = {mod: loc for mod, loc in required.items() if mod not in available}
    if missing:
        print("kernel-deps-vendored: FAIL — editor kernel imports not vendored locally:", file=sys.stderr)
        for mod, loc in sorted(missing.items()):
            print(f"    {mod!r}  (imported by {loc})", file=sys.stderr)
        print(
            "\n  These would trigger piplite.install(...) -> CDN/PyPI at kernel boot,\n"
            "  which FIPPA blocks (CSP connect-src 'self' / disablePyPIFallback) — the\n"
            "  editor kernel would die. Vendor each into the canonical Pyodide via\n"
            "  Tools/vendor/pyodide-extra-packages.json + scripts/add-pyodide-extras.py.",
            file=sys.stderr,
        )
        sys.exit(1)
    print(f"kernel-deps-vendored: OK — all {len(required)} kernel boot import(s) resolve locally")


if __name__ == "__main__":
    main()
