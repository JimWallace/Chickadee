#!/usr/bin/env python3
"""Drop `jedi` from the pyodide-kernel boot-install list so the first cell
execute isn't blocked behind installing it.

WHY (docs/exec-hang-investigation.md, second issue). The vended pyodide-kernel
driver reports "idle" off the `kernel_info_request` reply, which is NOT gated on
`this.ready`; but `executeRequest` DOES `await this.ready`. `ready` resolves only
after `initialize()` finishes, and `initKernel` installs, sequentially,
`["ipykernel","comm","pyodide-kernel","jedi","ipython"]` via
`piplite.install(..., keep_going=True)`. So a cell run in the window between the
premature "idle" and boot completion blocks on `await this.ready` for the rest of
boot — ~16-18s on WebKit (~30% of fresh kernels), the slow-first-execute whose
tail is the residual production `exec_hang`.

`jedi` (+ its `parso` dep) is the heaviest item in that list — a large
pure-Python tree unpacked into the Emscripten FS — and it is needed ONLY for
tab-completion, never to RUN a cell. Removing it from the boot-install list
shrinks the gated boot tail. jedi is not imported at boot (only lazily by the
completer), and IPython's completer guards `import jedi` (sets JEDI_INSTALLED via
try/except), so with jedi absent it degrades cleanly to the non-jedi completer
rather than erroring. Tradeoff: weaker editor tab-completion; cell execution
(the thing that hung) becomes reliably fast.

Run from build-jupyterlite.sh AFTER the bundle is generated (same stage as
patch-pyodide-waitasync-worker.py) — the install list lives in the built output
JS, not the wheel. Idempotent: re-running once patched is a no-op. Deterministic
string replace, so CI's rebuild+patch reproduces the committed bytes exactly
(`git diff Public/jupyterlite` stays clean). Fails loudly if the list is found in
neither its original nor its patched form (an upstream pyodide-kernel change to
re-examine).

The acceptance test is the exec probe: `editor-exec-probe.yml` on WebKit with
delay=0 — the slow-first-execute rate must drop toward zero.
"""
import pathlib
import sys

# The boot-install list as emitted by the pyodide-kernel `initKernel` step.
# Matching the full array (not a bare ,"jedi") keeps the replace unambiguous.
OLD = '["ipykernel","comm","pyodide-kernel","jedi","ipython"]'
NEW = '["ipykernel","comm","pyodide-kernel","ipython"]'

STATIC_GLOB = "extensions/@jupyterlite/pyodide-kernel-extension/static/*.js"


def main() -> int:
    root = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path("Public/jupyterlite")
    chunks = sorted(root.glob(STATIC_GLOB))
    if not chunks:
        print(
            f"patch-pyodide-defer-jedi: FAIL — no kernel chunks under {root}/{STATIC_GLOB}",
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
        print(f"patch-pyodide-defer-jedi: dropped jedi from {rewritten} boot-install list(s)")
        return 0
    if already:
        print(f"patch-pyodide-defer-jedi: already patched ({already} list(s)) — no-op")
        return 0

    print(
        "patch-pyodide-defer-jedi: FAIL — the pyodide-kernel boot-install list was found in "
        "neither its original nor its patched form. The vended pyodide-kernel likely changed; "
        "re-examine initKernel and update OLD/NEW.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
