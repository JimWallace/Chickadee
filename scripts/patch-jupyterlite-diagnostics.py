#!/usr/bin/env python3
"""Inject the in-iframe kernel-boot diagnostics collector into the JupyterLite
editor documents.

jl-kernel-diagnostics.js observes the Pyodide kernel boot from INSIDE the editor
iframe — the one context where the boot is visible — and postMessages
kernel_phase / kernel_error breadcrumbs out to the parent notebook page, which
forwards them through the normal client-diagnostics pipeline. The parent cannot
read the cross-process iframe's kernel state directly (the Safari/iPad blind spot
that let a hung kernel report a green editor_ready), so the collector has to run
in the iframe document — which means a <script> tag in the generated index.html.

`jupyter lite build` regenerates those index.html files, so this patch re-injects
the tag on every build (run from build-jupyterlite.sh) and the checked-in output
carries it too. It is injected into the kernel-bearing editors only (notebooks,
repl) — not consoles/edit/lab/tree — so non-kernel pages don't emit boot-stall
noise.

Idempotent: the tag is only added when absent. Fails loudly if an expected
editor index.html is missing (an upstream layout change to re-examine).
"""
import pathlib
import sys

# Same-origin absolute path: the editor iframe is served by Chickadee from
# /jupyterlite/..., so "/jl-kernel-diagnostics.js" resolves to Public/ at the
# origin root, is allowed by the CSP (script-src 'self'), and — being same-origin
# — loads cleanly under the editor's COEP require-corp isolation.
SCRIPT_TAG = '<script src="/jl-kernel-diagnostics.js"></script>'

# Anchor the injection right before </head> so the collector's error listeners
# are installed as early as possible in the document, before the kernel boots.
ANCHOR = "</head>"

# Only the kernel-bearing editor entry points; the notebook page mounts
# /jupyterlite/notebooks/index.html and the editor-smoke harness drives repl.
EDITOR_INDEXES = [
    "notebooks/index.html",
    "repl/index.html",
]


def main() -> int:
    root = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path("Public/jupyterlite")

    injected = 0
    already = 0
    for rel in EDITOR_INDEXES:
        path = root / rel
        if not path.is_file():
            print(
                f"patch-jupyterlite-diagnostics: FAIL — expected editor document missing: {path}",
                file=sys.stderr,
            )
            return 1
        text = path.read_text()
        if SCRIPT_TAG in text:
            already += 1
            continue
        if ANCHOR not in text:
            print(
                f"patch-jupyterlite-diagnostics: FAIL — no {ANCHOR!r} anchor in {path}; "
                "the JupyterLite index.html layout changed, re-examine.",
                file=sys.stderr,
            )
            return 1
        # Insert before the first </head>, preserving indentation of the anchor.
        idx = text.index(ANCHOR)
        line_start = text.rfind("\n", 0, idx) + 1
        indent = text[line_start:idx]
        patched = text[:line_start] + indent + SCRIPT_TAG + "\n" + text[line_start:]
        path.write_text(patched)
        injected += 1

    if injected:
        print(f"patch-jupyterlite-diagnostics: injected collector into {injected} editor document(s)")
    if already:
        print(f"patch-jupyterlite-diagnostics: already present in {already} editor document(s) — no-op")
    return 0


if __name__ == "__main__":
    sys.exit(main())
