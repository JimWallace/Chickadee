"""nb_to_r.py — Extract R code cells from a Jupyter notebook (.ipynb → .R).

Usage: python3 nb_to_r.py notebook.ipynb
Produces: notebook.R  (all code cells concatenated, preserving order)

This mirrors nb_to_py.py for R notebooks. The runner-support Makefile generates
both .py and .R files from every .ipynb; test scripts source whichever is
appropriate for their language.
"""
import sys
import json

p = sys.argv[1]
with open(p, "r", encoding="utf-8") as f:
    nb = json.load(f)

out = p[:-6] + ".R"
with open(out, "w", encoding="utf-8") as w:
    w.write(f"# Generated from {p}\n\n")
    for cell in nb.get("cells", []):
        if cell.get("cell_type") == "code":
            src = cell.get("source", "")
            if isinstance(src, list):
                src = "".join(src)
            src = src.rstrip()
            if src:
                w.write(src + "\n\n")
