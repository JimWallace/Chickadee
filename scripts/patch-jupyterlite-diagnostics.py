#!/usr/bin/env python3
"""Inject Chickadee's in-iframe scripts into the JupyterLite editor documents.

Two scripts ride the editor iframe, each served as a same-origin static asset
from Public/ and referenced by a cache-busted <script> tag in the generated
editor index.html:

* jl-kernel-diagnostics.js — the kernel-boot diagnostics collector. It observes
  the kernel boot from INSIDE the editor iframe — the one context where the
  boot is visible — and postMessages kernel_phase / kernel_error breadcrumbs
  out to the parent notebook page, which forwards them through the normal
  client-diagnostics pipeline. The parent cannot read the cross-process
  iframe's kernel state directly (the Safari/iPad blind spot that let a hung
  kernel report a green editor_ready), so the collector has to run in the
  iframe document. Injected into the kernel-bearing editors (notebooks, repl).

* jl-cell-perf-patch.js — the runtime coalescer for Notebook 7's per-output
  forced reflow (upstream CodeCell.updatePromptOverlayIcon reads clientHeight
  on every IOPub message; see the file's own header for the measurements).
  It patches the CodeCell prototype at runtime precisely so the vendored
  bundle's immutable content-hashed bytes never need to change. Injected into
  the notebooks editor only — the student surface where the freeze bites.

`jupyter lite build` regenerates those index.html files, so this patch
re-injects the tags on every build (run from build-jupyterlite.sh) and the
checked-in output carries them too.

Cache-busting: each tag carries a `?v=<hash>` derived from that script's own
bytes. The scripts are served as same-origin static assets and were previously
referenced bare, so a browser that had cached an older copy kept running it
after a deploy — the editor page cache-busts itself but these
separately-referenced scripts did not, so changes silently failed to reach
returning students until the cache TTL expired. The content hash makes each
URL change exactly when its script changes, so a deploy forces a fresh fetch;
an unchanged script keeps a stable URL (still cacheable).

Idempotent: a tag with the current hash is left as-is; a tag with a stale hash
(or the old bare form) is replaced in place — never duplicated. Fails loudly if
an expected editor index.html is missing (an upstream layout change to
re-examine).
"""
import hashlib
import pathlib
import re
import sys

# Anchor the injection right before </head> so the scripts are installed as
# early as possible in the document, before the kernel boots.
ANCHOR = "</head>"

# The injected scripts: same-origin absolute src (the editor iframe is served
# by Chickadee from /jupyterlite/..., so "/name.js" resolves to Public/ at the
# origin root, is allowed by the CSP script-src 'self', and — being same-origin
# — loads cleanly under the editor's COEP require-corp isolation), plus the
# editor documents each one belongs in.
INJECTED_SCRIPTS = [
    {
        "src": "/jl-kernel-diagnostics.js",
        # Only the kernel-bearing editor entry points; the notebook page mounts
        # /jupyterlite/notebooks/index.html and the editor-smoke harness drives repl.
        "indexes": ["notebooks/index.html", "repl/index.html"],
    },
    {
        "src": "/jl-cell-perf-patch.js",
        # The coalescer targets the notebook document's code cells; the REPL's
        # console has a different widget shape and no observed freezes.
        "indexes": ["notebooks/index.html"],
    },
]


def tag_re(src: str) -> re.Pattern:
    """Matches the script's tag with or without a ?v=<hash> cache-buster, so a
    stale-hash tag (or the old bare form) from a previous build is replaced,
    not duplicated."""
    return re.compile(r'<script src="' + re.escape(src) + r'(?:\?v=[0-9a-f]+)?"></script>')


def script_source(root: pathlib.Path, src: str) -> pathlib.Path:
    """Locate the Public/ file served at `src` from the origin root, i.e. the
    directory that contains the jupyterlite/ build (root.parent). Falls back to
    a repo-relative path so the script works regardless of the cwd the build
    invokes it from."""
    name = src.lstrip("/")
    candidate = root.parent / name
    if candidate.is_file():
        return candidate
    return pathlib.Path(__file__).resolve().parent.parent / "Public" / name


def cache_busted_tag(root: pathlib.Path, src: str) -> str:
    source = script_source(root, src)
    if not source.is_file():
        print(
            f"patch-jupyterlite-diagnostics: FAIL — injected-script source missing: {source}",
            file=sys.stderr,
        )
        sys.exit(1)
    digest = hashlib.sha256(source.read_bytes()).hexdigest()[:8]
    return f'<script src="{src}?v={digest}"></script>'


def inject(path: pathlib.Path, src: str, script_tag: str) -> str:
    """Ensure `script_tag` is present in `path`; returns one of
    'injected' | 'refreshed' | 'already'. Exits loudly on a missing anchor."""
    text = path.read_text()
    existing = tag_re(src).search(text)
    if existing:
        if existing.group(0) == script_tag:
            return "already"
        # Replace a stale-hash (or old bare) tag in place, preserving the
        # surrounding indentation/placement.
        path.write_text(text[: existing.start()] + script_tag + text[existing.end():])
        return "refreshed"
    if ANCHOR not in text:
        print(
            f"patch-jupyterlite-diagnostics: FAIL — no {ANCHOR!r} anchor in {path}; "
            "the JupyterLite index.html layout changed, re-examine.",
            file=sys.stderr,
        )
        sys.exit(1)
    # Insert before the first </head>, preserving indentation of the anchor.
    idx = text.index(ANCHOR)
    line_start = text.rfind("\n", 0, idx) + 1
    indent = text[line_start:idx]
    path.write_text(text[:line_start] + indent + script_tag + "\n" + text[line_start:])
    return "injected"


def main() -> int:
    root = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path("Public/jupyterlite")

    counts = {"injected": 0, "refreshed": 0, "already": 0}
    for entry in INJECTED_SCRIPTS:
        script_tag = cache_busted_tag(root, entry["src"])
        for rel in entry["indexes"]:
            path = root / rel
            if not path.is_file():
                print(
                    f"patch-jupyterlite-diagnostics: FAIL — expected editor document missing: {path}",
                    file=sys.stderr,
                )
                return 1
            counts[inject(path, entry["src"], script_tag)] += 1

    if counts["injected"]:
        print(f"patch-jupyterlite-diagnostics: injected {counts['injected']} tag(s)")
    if counts["refreshed"]:
        print(f"patch-jupyterlite-diagnostics: refreshed cache-buster on {counts['refreshed']} tag(s)")
    if counts["already"]:
        print(f"patch-jupyterlite-diagnostics: {counts['already']} tag(s) already current — no-op")
    return 0


if __name__ == "__main__":
    sys.exit(main())
