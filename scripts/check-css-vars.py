#!/usr/bin/env python3
"""
CSS custom-property guard.

Two failure classes, both regressions the v0.4.x UI-cleanup pass fixed and
that render perfectly fine in the browser (so no test catches them):

  1. UNDEFINED VAR: a `var(--x)` whose `--x` is never declared in a stylesheet
     AND has no inline fallback.  These silently resolve to the property's
     initial value — e.g. `--muted` / `--text-secondary` / `--meta` were
     undefined, so "muted" text rendered in full-strength body colour.

  2. DEAD HEX FALLBACK: `var(--x, #rrggbb)`.  A hardcoded colour fallback is
     either dead weight (the var IS defined) or an off-palette, dark-mode-
     unaware value that bypasses the design system (the var is NOT defined).
     Either way: define the var and drop the fallback.  Non-colour fallbacks
     (e.g. `var(--filter-width, 16rem)` for a var assigned inline in markup)
     are allowed.

Scans the checked-in Leaf templates, CSS, and JS — no build needed.
"""

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CSS_FILES = sorted((REPO / "Public").glob("*.css"))
USAGE_GLOBS = [
    *sorted((REPO / "Resources" / "Views").glob("*.leaf")),
    *CSS_FILES,
    *sorted((REPO / "Public").glob("*.js")),
]

# A declaration is `--name:` at a property position.  `var(--name, ...)` never
# contains a colon after the name, so this matches declarations only.
DECL_RE = re.compile(r"(--[A-Za-z0-9-]+)\s*:")
# A usage, capturing the var name and (optionally) an inline fallback.
USE_RE = re.compile(r"var\(\s*(--[A-Za-z0-9-]+)\s*(?:,\s*([^)]*))?\)")
HEX_RE = re.compile(r"#[0-9A-Fa-f]{3,8}\b")

declared: set[str] = set()
for css in CSS_FILES:
    declared.update(DECL_RE.findall(css.read_text()))

undefined: list[str] = []
dead_hex: list[str] = []

for path in USAGE_GLOBS:
    rel = path.relative_to(REPO)
    for lineno, line in enumerate(path.read_text().splitlines(), 1):
        for m in USE_RE.finditer(line):
            name, fallback = m.group(1), m.group(2)
            if fallback is not None and HEX_RE.search(fallback):
                dead_hex.append(f"  {rel}:{lineno}  {m.group(0)}")
            if name not in declared and fallback is None:
                undefined.append(f"  {rel}:{lineno}  {m.group(0)}")

status = 0
if undefined:
    status = 1
    print("ERROR: var() references an undefined custom property (no fallback).")
    print("       Declare it in Public/styles.css (with a dark-mode value if it's a colour).")
    print("\n".join(undefined))
    print()
if dead_hex:
    status = 1
    print("ERROR: var(--x, #hex) uses a hardcoded colour fallback.")
    print("       Define the variable in the palette and drop the fallback so it")
    print("       routes through the design system (and adapts to dark mode).")
    print("\n".join(dead_hex))
    print()

if status == 0:
    print(f"check-css-vars: OK ({len(declared)} vars declared, all references resolve)")

sys.exit(status)
