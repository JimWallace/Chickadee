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

Cache-busting: the tag carries a `?v=<hash>` derived from the collector's own
bytes. The script is served as a same-origin static asset and was previously
referenced bare (`/jl-kernel-diagnostics.js`), so a browser that had cached an
older copy kept running it after a deploy — the editor page cache-busts itself
but this separately-referenced script did not, so collector changes (e.g. the
CASE 2 bootContext fields) silently failed to reach returning students until the
cache TTL expired. The content hash makes the URL change exactly when the script
changes, so a deploy forces a fresh fetch; an unchanged script keeps a stable
URL (still cacheable).

Idempotent: a tag with the current hash is left as-is; a tag with a stale hash
(or the old bare form) is replaced in place — never duplicated. Fails loudly if
an expected editor index.html is missing (an upstream layout change to
re-examine).
"""
import hashlib
import pathlib
import re
import sys

# Same-origin absolute path: the editor iframe is served by Chickadee from
# /jupyterlite/..., so "/jl-kernel-diagnostics.js" resolves to Public/ at the
# origin root, is allowed by the CSP (script-src 'self'), and — being same-origin
# — loads cleanly under the editor's COEP require-corp isolation.
SCRIPT_SRC = "/jl-kernel-diagnostics.js"

# Matches the diagnostics <script> tag with or without a ?v=<hash> cache-buster,
# so a stale-hash tag (or the old bare form) from a previous build is replaced,
# not duplicated.
TAG_RE = re.compile(
    r'<script src="' + re.escape(SCRIPT_SRC) + r'(?:\?v=[0-9a-f]+)?"></script>'
)

# Anchor the injection right before </head> so the collector's error listeners
# are installed as early as possible in the document, before the kernel boots.
ANCHOR = "</head>"

# Only the kernel-bearing editor entry points; the notebook page mounts
# /jupyterlite/notebooks/index.html and the editor-smoke harness drives repl.
EDITOR_INDEXES = [
    "notebooks/index.html",
    "repl/index.html",
]


def diagnostics_source(root: pathlib.Path) -> pathlib.Path:
    """Locate Public/jl-kernel-diagnostics.js — the file served at SCRIPT_SRC
    from the origin root, i.e. the directory that contains the jupyterlite/
    build (root.parent). Falls back to a repo-relative path so the script works
    regardless of the cwd the build invokes it from."""
    candidate = root.parent / "jl-kernel-diagnostics.js"
    if candidate.is_file():
        return candidate
    return pathlib.Path(__file__).resolve().parent.parent / "Public" / "jl-kernel-diagnostics.js"


def cache_busted_tag(root: pathlib.Path) -> str:
    source = diagnostics_source(root)
    if not source.is_file():
        print(
            f"patch-jupyterlite-diagnostics: FAIL — collector source missing: {source}",
            file=sys.stderr,
        )
        sys.exit(1)
    digest = hashlib.sha256(source.read_bytes()).hexdigest()[:8]
    return f'<script src="{SCRIPT_SRC}?v={digest}"></script>'


def main() -> int:
    root = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path("Public/jupyterlite")

    script_tag = cache_busted_tag(root)

    injected = 0
    refreshed = 0
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
        existing = TAG_RE.search(text)
        if existing:
            if existing.group(0) == script_tag:
                already += 1
                continue
            # Replace a stale-hash (or old bare) tag in place, preserving the
            # surrounding indentation/placement.
            path.write_text(text[: existing.start()] + script_tag + text[existing.end():])
            refreshed += 1
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
        patched = text[:line_start] + indent + script_tag + "\n" + text[line_start:]
        path.write_text(patched)
        injected += 1

    if injected:
        print(f"patch-jupyterlite-diagnostics: injected collector into {injected} editor document(s)")
    if refreshed:
        print(f"patch-jupyterlite-diagnostics: refreshed cache-buster in {refreshed} editor document(s)")
    if already:
        print(f"patch-jupyterlite-diagnostics: already current in {already} editor document(s) — no-op")
    return 0


if __name__ == "__main__":
    sys.exit(main())
