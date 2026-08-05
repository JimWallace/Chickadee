#!/usr/bin/env python3
"""Neutralize the Pyodide-only browser-fetch paths in the vendored xeus-python env.

TWO libraries need this, for the same reason and under the same conditions.
`pyodide-http` (below) was the first. The second is `urllib3`, which arrived as a
transitive dependency the moment scikit-learn was added to the environment
(scikit-learn -> requests -> urllib3) and which crashed the kernel in exactly the
same way: `urllib3.contrib.emscripten.fetch` constructs a `_StreamingFetcher` at
MODULE IMPORT when the page is cross-origin isolated, and that constructor calls
`to_js(..., dict_converter=...)`, which pyjs does not accept.

The failure is total, not partial — `pybind11::error_already_set` out of
`xkernel.start()`, so the kernel never boots at all. It was caught by
Tools/browser-grading-smoke on the very first re-vendor that included the new
packages, and by nothing else: the env solves cleanly, every vendoring guard
passes, and the broken import is only reachable in a real isolated browser.

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
import typing

class Target(typing.NamedTuple):
    """One library to patch inside the vendored env."""

    archive_glob: str
    member_suffix: str
    substitutions: list[tuple[str, str]]
    #: The edit that actually matters. Its presence means "already patched", and
    #: its absence after substitution is a hard failure —
    #: scripts/check-xeus-vendored.sh asserts the same condition on the shipped
    #: bytes.
    required_marker: str
    #: Printed when the archive is absent, which is legitimate for an R-only env.
    absent_note: str


PYODIDE_HTTP = Target(
    archive_glob="*/kernel_packages/pyodide-http-*.tar.gz",
    member_suffix="site-packages/pyodide_http/_streaming.py",
    # Two edits, both in _streaming.py. The first is the actual fix; the second
    # is belt-and-braces in case the streaming path is ever re-enabled.
    substitutions=[
        # 1. Force the XMLHttpRequest fallback on every engine.
        #
        #    Upstream selects the streaming implementation purely on
        #    `crossOriginIsolated`. That is exactly the engine split we observe:
        #    Chromium (isolated) takes the streaming path and the kernel dies;
        #    WebKit (non-isolated) takes the XHR fallback and boots fine. The
        #    fallback is upstream's own documented degradation, not something we
        #    invented — pyodide-http calls it out in the module docstring — so
        #    this puts every engine on the path one of them already proves works.
        (
            "if crossOriginIsolated:",
            "if False:  # chickadee: force the XHR fallback on every engine",
        ),
        # 2. pyjs's to_js takes no `dict_converter` (Pyodide's does). Only
        #    reachable if edit 1 is ever reverted, but cheap to keep correct.
        (
            "return to_js(dict_val, dict_converter=js.Object.fromEntries)",
            "return to_js(dict_val)  # chickadee: pyjs to_js takes no converter kwarg",
        ),
    ],
    required_marker="if False:  # chickadee: force the XHR fallback on every engine",
    absent_note="no pyodide-http payload found",
)

URLLIB3 = Target(
    archive_glob="*/kernel_packages/urllib3-*.tar.gz",
    member_suffix="site-packages/urllib3/contrib/emscripten/fetch.py",
    substitutions=[
        # 1. Never construct the streaming fetcher.
        #
        #    Upstream builds it at MODULE IMPORT under exactly the conditions a
        #    grading worker meets (worker + cross-origin isolated + not node),
        #    and its constructor is what raises. Suppressing the construction is
        #    a one-line, unambiguous edit; rewriting the multi-line condition
        #    above it would be a far more fragile match.
        #
        #    Nothing is lost. The streaming path builds a Blob-backed Worker and
        #    does cross-origin fetches — both impossible under Chickadee's
        #    `connect-src 'self'` CSP — so `_fetcher = None` is the only state
        #    that could ever have worked here. It is upstream's own non-streaming
        #    branch, not an invented one.
        (
            "    _fetcher = _StreamingFetcher()",
            "    _fetcher = None  # chickadee: the streaming fetcher is not pyjs-compatible",
        ),
        # 2. The Pyodide-only kwarg itself, for the same belt-and-braces reason
        #    as pyodide-http's edit 2.
        (
            "    return to_js(dict_val, dict_converter=js.Object.fromEntries)",
            "    return to_js(dict_val)  # chickadee: pyjs to_js takes no converter kwarg",
        ),
    ],
    required_marker="_fetcher = None  # chickadee: the streaming fetcher is not pyjs-compatible",
    absent_note="no urllib3 payload found",
)

TARGETS = [PYODIDE_HTTP, URLLIB3]


def fail(message: str) -> None:
    print(f"patch-xeus-python-http: {message}", file=sys.stderr)
    sys.exit(1)


def patch_archive(archive: pathlib.Path, target: Target) -> str:
    """Rewrite one library's tarball in place. Returns a status word."""
    with tarfile.open(archive, "r:gz") as tf:
        members = tf.getmembers()
        matches = [m for m in members if m.name.endswith(target.member_suffix)]
        if not matches:
            fail(f"{archive.name}: no {target.member_suffix} inside — upstream layout changed")
        if len(matches) > 1:
            fail(f"{archive.name}: multiple {target.member_suffix} members: {[m.name for m in matches]}")
        member = matches[0]
        extracted = tf.extractfile(member)
        if extracted is None:
            fail(f"{archive.name}: {member.name} is not a regular file")
        source = extracted.read().decode("utf-8")

        if target.required_marker in source:
            return "already-patched"

        patched_source = source
        applied = 0
        for original, replacement in target.substitutions:
            if original in patched_source:
                patched_source = patched_source.replace(original, replacement)
                applied += 1
            elif replacement in patched_source:
                applied += 1  # already carries this edit

        if target.required_marker not in patched_source:
            fail(
                f"{archive.name}: the load-bearing edit did not apply in {member.name}.\n"
                f"  looked for: {target.substitutions[0][0]!r}\n"
                "  The library changed upstream — re-check how it selects its\n"
                "  browser-fetch implementation before relaxing this guard.\n"
                "  Shipping un-patched means the kernel does not boot at all on\n"
                "  isolated engines."
            )
        if applied != len(target.substitutions):
            fail(
                f"{archive.name}: applied {applied}/{len(target.substitutions)} edits — "
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

    for target in TARGETS:
        archives = sorted(xeus.glob(target.archive_glob))
        if not archives:
            # Only a Python (xeus-python) env pulls these in, and urllib3 only
            # arrives with scikit-learn. An R-only vendor legitimately has none.
            print(f"patch-xeus-python-http: {target.absent_note} — nothing to patch.")
            continue
        for archive in archives:
            status = patch_archive(archive, target)
            print(f"patch-xeus-python-http: {status} ({archive.name})")


if __name__ == "__main__":
    main()
