#!/usr/bin/env python3
"""Gate the pyodide-kernel's `kernelInfoRequest` on `this.ready` so the editor
does not present a still-booting kernel as "idle" (docs/exec-hang-investigation.md,
second issue: the ~13-17s WebKit slow-first-execute).

WHY. In the vended pyodide-kernel driver, `executeRequest` does `await this.ready`
but `kernelInfoRequest` does NOT — it returns a static object immediately. The
execution indicator (and our kernel_idle telemetry breadcrumb) flips to "idle"
off that early kernel_info reply, while `initialize()` (WASM compile + install/
import ipython/ipykernel/...) is still running behind `ready`. A cell run in that
window blocks on `await this.ready` for the rest of boot — the slow-first-execute
whose tail is the residual production `exec_hang`. Dropping jedi from the boot
list was tried and did NOT help (jedi was ~2-4s of a ~13s tail; the bulk is the
WASM compile + IPython import, which can't be removed).

FIX (option 3 — honest readiness). Make `kernelInfoRequest` also `await this.ready`.
Then JupyterLab does not consider the kernel connected/ready — and the indicator
does not go idle — until the kernel can actually execute. The unavoidable boot
wait is shown as "Connecting"/busy instead of a deceptive idle-that-hangs, and a
run can't be dispatched into a not-ready kernel. It does NOT speed boot; it makes
readiness honest (and the boot-funnel telemetry accurate). The method is already
`async` and its caller already awaits it (`await this._kernelInfo(e)`), so adding
the await is behaviour-compatible.

Run from build-jupyterlite.sh after the bundle is generated (same stage as
patch-pyodide-waitasync-worker.py). Idempotent; deterministic string insert so
CI's rebuild+patch reproduces the committed bytes. Fails loudly if the method is
found in neither its original nor its patched form (an upstream change to
re-examine).

RISK / ACCEPTANCE TEST. Delaying the kernel_info reply ~13s could, in principle,
trip a JupyterLab kernel-connection timeout ("Kernel Unknown"-class). The
editor-smoke gate is the safety net (it asserts the kernel boots AND runs a cell);
editor-exec-probe on WebKit delay=0 is the win condition (first-execute slow rate
must drop toward zero because the probe now waits for the true-ready idle before
running). If editor-smoke goes red, this broke the handshake — revert.
"""
import pathlib
import sys

OLD = 'async kernelInfoRequest(){return{implementation:"pyodide"'
NEW = 'async kernelInfoRequest(){await this.ready;return{implementation:"pyodide"'

STATIC_GLOB = "extensions/@jupyterlite/pyodide-kernel-extension/static/*.js"


def main() -> int:
    root = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path("Public/jupyterlite")
    chunks = sorted(root.glob(STATIC_GLOB))
    if not chunks:
        print(
            f"patch-pyodide-kernel-info-ready: FAIL — no kernel chunks under {root}/{STATIC_GLOB}",
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
        print(f"patch-pyodide-kernel-info-ready: gated {rewritten} kernelInfoRequest(s) on this.ready")
        return 0
    if already:
        print(f"patch-pyodide-kernel-info-ready: already patched ({already} gated) — no-op")
        return 0

    print(
        "patch-pyodide-kernel-info-ready: FAIL — async kernelInfoRequest was found in neither its "
        "original nor its patched form. The vended pyodide-kernel likely changed; re-examine and "
        "update OLD/NEW.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
