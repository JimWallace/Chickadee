"""nb_to_r.py — Extract R code cells from a Jupyter notebook (.ipynb → .R).

Usage: python3 nb_to_r.py notebook.ipynb
Produces:
  notebook.R          — all code cells concatenated, preserving order
  cell_<name>.R       — one file per cell marked with # CELL: name=<name>

This mirrors nb_to_py.py for R notebooks. The runner-support Makefile generates
both .py and .R files from every .ipynb; test scripts source whichever is
appropriate for their language.
"""
import re
import sys
import json
import os

CELL_NAME_RE = re.compile(r'^#\s*CELL:\s*name=(\w+)')

p = sys.argv[1]
with open(p, "r", encoding="utf-8") as f:
    nb = json.load(f)

out_dir = os.path.dirname(p) or "."
stem    = os.path.splitext(os.path.basename(p))[0]

with open(os.path.join(out_dir, stem + ".R"), "w", encoding="utf-8") as w:
    w.write(f"# Generated from {p}\n\n")
    for cell in nb.get("cells", []):
        if cell.get("cell_type") == "code":
            src = cell.get("source", "")
            if isinstance(src, list):
                src = "".join(src)
            src = src.rstrip()
            if src:
                w.write(src + "\n\n")

                # Write per-cell file if a # CELL: name=<id> marker is present
                # on the first non-empty line of the cell.
                first_line = next((l for l in src.split("\n") if l.strip()), None)
                if first_line:
                    m = CELL_NAME_RE.match(first_line)
                    if m:
                        cell_name = m.group(1)
                        cell_path = os.path.join(out_dir, f"cell_{cell_name}.R")
                        with open(cell_path, "w", encoding="utf-8") as cw:
                            cw.write(src + "\n")
