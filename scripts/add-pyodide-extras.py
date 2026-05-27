#!/usr/bin/env python3
"""Inject Chickadee's extra pure-Python wheels into the vendored Pyodide.

Reads Tools/vendor/pyodide-extra-packages.json, downloads each pinned wheel,
verifies its sha256, copies it into Public/pyodide, and adds a matching entry
to Public/pyodide/pyodide-lock.json so loadPyodide({packages:[...]}) can resolve
it from the one canonical, same-origin Pyodide.

Idempotent: re-running with the same manifest produces the same lock. Invoked by
scripts/setup-vendor.sh after the base Pyodide is vended, so a Pyodide version
bump never silently drops these packages.
"""
from __future__ import annotations

import hashlib
import json
import pathlib
import re
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "Tools" / "vendor" / "pyodide-extra-packages.json"
PYODIDE_DIR = ROOT / "Public" / "pyodide"
LOCK = PYODIDE_DIR / "pyodide-lock.json"


def fail(msg: str) -> None:
    print(f"add-pyodide-extras: FAIL — {msg}", file=sys.stderr)
    sys.exit(1)


def canonical_name(name: str) -> str:
    """PEP 503 normalized project name (e.g. ``nb_mypy`` -> ``nb-mypy``).

    Pyodide canonicalizes the requested name before looking it up, and every key
    in pyodide-lock.json is stored in this form.  The lock KEY must therefore be
    normalized even when the manifest / wheel use an underscored project name —
    otherwise ``loadPackage("nb_mypy")`` raises "No known package with name
    'nb_mypy'".  The editor loads nb_mypy lazily in a background task (see
    scripts/patch-pyodide-kernel.py), so a bad key now silently disables editor
    type-checking rather than bricking the kernel — but keeping the key
    canonical keeps type-checking working.
    """
    return re.sub(r"[-_.]+", "-", name).lower()


def main() -> None:
    if not LOCK.exists():
        fail(f"{LOCK} not found — run the Pyodide vendoring first")

    manifest = json.loads(MANIFEST.read_text())
    lock = json.loads(LOCK.read_text())
    packages = lock["packages"]

    for pkg in manifest["packages"]:
        name = pkg["name"]
        dest = PYODIDE_DIR / pkg["file_name"]

        # Download unless the exact (sha-verified) wheel is already present.
        need_download = True
        if dest.exists():
            if hashlib.sha256(dest.read_bytes()).hexdigest() == pkg["sha256"]:
                need_download = False
            else:
                dest.unlink()
        if need_download:
            print(f"  fetching {pkg['file_name']}")
            with urllib.request.urlopen(pkg["url"]) as resp:  # noqa: S310 (pinned host)
                data = resp.read()
            digest = hashlib.sha256(data).hexdigest()
            if digest != pkg["sha256"]:
                fail(f"{name}: sha256 mismatch (expected {pkg['sha256']}, got {digest})")
            dest.write_bytes(data)

        # The lock key and the entry's "name" must be PEP 503 canonical so the
        # Pyodide resolver finds them; "imports" stays the real module name.
        key = canonical_name(name)
        depends = [canonical_name(dep) for dep in pkg["depends"]]

        # Validate any declared deps resolve (mypy/astor must already be present).
        for dep in depends:
            if dep not in packages:
                fail(f"{name}: dependency '{dep}' is not in the Pyodide lock")

        packages[key] = {
            "name": key,
            "version": pkg["version"],
            "file_name": pkg["file_name"],
            "install_dir": "site",
            "sha256": pkg["sha256"],
            "package_type": "package",
            "imports": pkg["imports"],
            "depends": depends,
            "unvendored_tests": False,
        }
        print(f"  locked {key}=={pkg['version']}")

    # Match the upstream lock's compact, key-sorted formatting to keep the diff minimal.
    LOCK.write_text(json.dumps(lock, separators=(", ", ": "), sort_keys=True))
    print(f"add-pyodide-extras: OK — {len(manifest['packages'])} extra(s) in {LOCK.name}")


if __name__ == "__main__":
    main()
