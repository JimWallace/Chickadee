#!/usr/bin/env python3
"""Patch the vended pyodide-kernel so its Atomics.waitAsync polyfill spawns its
helper worker from a blob: URL instead of a data: URL.

The pyodide-kernel polyfills Atomics.waitAsync — on engines that lack it natively
(older Safari / iPadOS) — with `new Worker("data:application/javascript,…")`. A
data: worker is blocked by our CSP (`worker-src 'self' blob:`) AND by COEP
require-corp on the cross-origin-isolated editor, so the kernel hangs ("Kernel
Unknown"-class). A blob: worker is same-origin, inherits the page's COEP, and is
already permitted by the CSP — so this lets those engines boot the kernel WITH
cross-origin isolation (SharedArrayBuffer) intact, no fallback needed.

Run from build-jupyterlite.sh after the bundle is generated. Idempotent:
re-running once patched is a no-op. Fails loudly if the polyfill string is found
in neither its original nor its patched form (an upstream pyodide-kernel change
to re-examine — which SMOKE_SIMULATE_NO_WAITASYNC would also catch at runtime).
"""
import pathlib
import sys

OLD = (
    'new Worker("data:application/javascript,'
    "onmessage%3D(%7Bdata%3Ab%7D)%3D%3E(Atomics.wait(b%2C0)%2CpostMessage(0))\")"
)
NEW = (
    "new Worker(URL.createObjectURL(new Blob("
    '["onmessage=({data:b})=>(Atomics.wait(b,0),postMessage(0))"],'
    '{type:"application/javascript"})))'
)

STATIC_GLOB = "extensions/@jupyterlite/pyodide-kernel-extension/static/*.js"


def main() -> int:
    root = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path("Public/jupyterlite")
    chunks = sorted(root.glob(STATIC_GLOB))
    if not chunks:
        print(
            f"patch-pyodide-waitasync-worker: FAIL — no kernel chunks under {root}/{STATIC_GLOB}",
            file=sys.stderr,
        )
        return 1

    rewritten = 0
    already = 0
    for chunk in chunks:
        text = chunk.read_text()
        if OLD in text:
            count = text.count(OLD)
            chunk.write_text(text.replace(OLD, NEW))
            rewritten += count
        elif NEW in text:
            already += text.count(NEW)

    if rewritten:
        print(f"patch-pyodide-waitasync-worker: rewrote {rewritten} data:→blob: worker(s)")
        return 0
    if already:
        print(f"patch-pyodide-waitasync-worker: already patched ({already} blob: worker(s)) — no-op")
        return 0

    print(
        "patch-pyodide-waitasync-worker: FAIL — the waitAsync data:-worker polyfill was found "
        "in neither its original nor its patched form. The vended pyodide-kernel likely changed; "
        "re-examine the polyfill and update OLD/NEW.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
