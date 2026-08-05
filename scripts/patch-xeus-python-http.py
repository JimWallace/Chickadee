#!/usr/bin/env python3
"""Neutralize pyodide-http's Pyodide-only `to_js` call in the vendored xeus-python env.

Why this exists
---------------
`xeus-python` hard-depends on `xeus-python-shell-lite`, which hard-depends on
`pyodide-http` — every published version, so it cannot be solved away. The shell
calls `pyodide_http.patch_all()` at kernel startup, which monkey-patches
`urllib`/`requests`.

`pyodide-http` selects a streaming implementation whenever `crossOriginIsolated`
is true, and that implementation is Pyodide-specific: it calls `to_js` with a
`dict_converter` keyword that pyjs does not accept, and fails again further in
even once that is fixed. It is simply not pyjs-compatible.

That switch produces an engine split we measured directly on CI:

    Chromium (isolated, SAB present) -> streaming path  -> kernel never boots
    WebKit (non-isolated, no SAB)    -> XHR fallback     -> kernel boots fine

On Chickadee's notebook page that call is on the critical path: the kernel
mounts the JupyterLite Drive over HTTP, the patched `urllib` routes it through
`pyodide_http._streaming`, and the TypeError kills kernel init — the kernel
never leaves `kernel_starting` and the editor sits on "Kernel Connecting"
forever. (The JupyterLite REPL has no Drive-backed file, never makes the call,
and boots fine — which is why this reproduces only in the real editor.)

Why dropping the kwarg is safe *here*
-------------------------------------
`pyodide-http` exists to let `requests`/`urllib` reach the network from the
browser. Chickadee's editor CSP is `connect-src 'self'`, so cross-origin HTTP
from the kernel cannot work in this deployment regardless. We are not giving up
a capability we have; we are stopping a library from crashing the kernel on a
capability it cannot deliver here.

The XHR fallback is upstream's own documented degradation for non-isolated
contexts, not something invented here — `_streaming.py`'s module docstring
describes it — so forcing it everywhere puts each engine on a path that one of
them already demonstrates works.

Idempotent. Fails loudly if the upstream source shape drifts, so a re-vendor
that changes `pyodide-http` cannot silently skip the patch.

Usage: patch-xeus-python-http.py <jupyterlite-build-dir>
"""

from __future__ import annotations

import io
import pathlib
import sys
import tarfile

TARGET_MEMBER_SUFFIX = "site-packages/pyodide_http/_streaming.py"

# Two edits, both in _streaming.py. The first is the actual fix; the second is
# belt-and-braces in case the streaming path is ever re-enabled.
SUBSTITUTIONS = [
    # 1. Force the XMLHttpRequest fallback on every engine.
    #
    #    Upstream selects the streaming implementation purely on
    #    `crossOriginIsolated`. That is exactly the engine split we observe:
    #    Chromium (isolated) takes the streaming path and the kernel dies;
    #    WebKit (non-isolated) takes the XHR fallback and boots fine. The
    #    fallback is upstream's own documented degradation, not something we
    #    invented — pyodide-http calls it out in the module docstring — so this
    #    puts every engine on the path one of them already proves works.
    (
        "if crossOriginIsolated:",
        "if False:  # chickadee: force the XHR fallback on every engine",
    ),
    # 2. pyjs's to_js takes no `dict_converter` (Pyodide's does). Only reachable
    #    if edit 1 is ever reverted, but cheap to keep correct.
    (
        "return to_js(dict_val, dict_converter=js.Object.fromEntries)",
        "return to_js(dict_val)  # chickadee: pyjs to_js takes no converter kwarg",
    ),
]

# The edit that actually matters; its marker is what the vendored-bytes guard
# (scripts/check-xeus-vendored.sh) asserts.
REQUIRED_MARKER = "if False:  # chickadee: force the XHR fallback on every engine"


def fail(message: str) -> None:
    print(f"patch-xeus-python-http: {message}", file=sys.stderr)
    sys.exit(1)


def patch_archive(archive: pathlib.Path) -> str:
    """Rewrite the pyodide-http tarball in place. Returns a status word."""
    with tarfile.open(archive, "r:gz") as tf:
        members = tf.getmembers()
        target = [m for m in members if m.name.endswith(TARGET_MEMBER_SUFFIX)]
        if not target:
            fail(f"{archive.name}: no {TARGET_MEMBER_SUFFIX} inside — upstream layout changed")
        if len(target) > 1:
            fail(f"{archive.name}: multiple {TARGET_MEMBER_SUFFIX} members: {[m.name for m in target]}")
        member = target[0]
        extracted = tf.extractfile(member)
        if extracted is None:
            fail(f"{archive.name}: {member.name} is not a regular file")
        source = extracted.read().decode("utf-8")

        if REQUIRED_MARKER in source:
            return "already-patched"

        patched_source = source
        applied = 0
        for original, replacement in SUBSTITUTIONS:
            if original in patched_source:
                patched_source = patched_source.replace(original, replacement)
                applied += 1
            elif replacement in patched_source:
                applied += 1  # already carries this edit

        if REQUIRED_MARKER not in patched_source:
            fail(
                f"{archive.name}: the streaming-path switch was not found in {member.name}.\n"
                f"  looked for: {SUBSTITUTIONS[0][0]!r}\n"
                "  pyodide-http changed upstream — re-check how it selects the\n"
                "  streaming implementation before relaxing this guard. Shipping\n"
                "  un-patched means the editor kernel hangs on isolated engines."
            )
        if applied != len(SUBSTITUTIONS):
            fail(
                f"{archive.name}: applied {applied}/{len(SUBSTITUTIONS)} edits — "
                "upstream source drifted; re-check the substitution list."
            )
        new_source = patched_source.encode("utf-8")

        # Rebuild the archive, substituting the one member. Streaming into
        # memory keeps the original member order and metadata intact.
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w:gz") as out:
            for m in members:
                if m.name == member.name:
                    info = tarfile.TarInfo(m.name)
                    info.size = len(new_source)
                    info.mode = m.mode
                    info.mtime = m.mtime
                    info.uid, info.gid = m.uid, m.gid
                    info.uname, info.gname = m.uname, m.gname
                    info.type = m.type
                    out.addfile(info, io.BytesIO(new_source))
                elif m.isfile():
                    data = tf.extractfile(m)
                    if data is None:
                        continue
                    out.addfile(m, io.BytesIO(data.read()))
                else:
                    out.addfile(m)

    archive.write_bytes(buf.getvalue())
    return "patched"


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: patch-xeus-python-http.py <jupyterlite-build-dir>")
    build = pathlib.Path(sys.argv[1])
    xeus = build / "xeus"
    if not xeus.is_dir():
        print("patch-xeus-python-http: no xeus/ in build — nothing to patch.")
        return

    archives = sorted(xeus.glob("*/kernel_packages/pyodide-http-*.tar.gz"))
    if not archives:
        # Only a Python (xeus-python) env pulls pyodide-http in. An R-only
        # vendor legitimately has none.
        print("patch-xeus-python-http: no pyodide-http payload found — nothing to patch.")
        return

    results = {archive.name: patch_archive(archive) for archive in archives}
    for name, status in results.items():
        print(f"patch-xeus-python-http: {status} ({name})")


if __name__ == "__main__":
    main()
