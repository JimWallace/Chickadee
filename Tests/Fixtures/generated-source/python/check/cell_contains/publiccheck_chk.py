# Test: Check
# Generated from notebook check "chk" kind=cell_contains spec_hash=3933c523f64e655d — edit the check, not this file.

import json
import re
from pathlib import Path

needle = ""
must_differ_from = None

# SubmissionNormalizer (v0.4.114+) writes a copy of the original
# student notebook to `_submission.ipynb` next to the flattened .py
# student module, so source-level checks like this one have
# cell-by-cell visibility that the flattened .py loses.
notebook_path = Path("_submission.ipynb")
if not notebook_path.exists():
    errored(
        "Student notebook source not preserved — cannot run cell-content check.\n"
        "  expected: _submission.ipynb in workspace\n"
    )

try:
    notebook = json.loads(notebook_path.read_text(encoding="utf-8"))
except Exception as ex:
    errored(f"Could not parse _submission.ipynb: {ex}")

code_cells = []
for cell in notebook.get("cells", []):
    if cell.get("cell_type") != "code":
        continue
    src = cell.get("source", "")
    if isinstance(src, list):
        src = "".join(src)
    code_cells.append(src)

matched_cells = []
for src in code_cells:
    if needle in src:
        matched_cells.append(src)

if not matched_cells:
    failed(
        f"No code cell in the notebook matches `{needle}`.\n"
        f"  expected: at least one cell containing the pattern\n"
        f"  searched: {len(code_cells)} code cell(s)\n"
    )

if must_differ_from is not None:
    # Whitespace-normalize both sides so trailing newlines / leading
    # indentation differences don't mask a near-identical match.
    def _normalize(s):
        return " ".join(s.split())
    ref = _normalize(must_differ_from)
    only_identical = all(_normalize(src) == ref for src in matched_cells)
    if only_identical:
        failed(
            f"Cell containing `{needle}` is identical to the example.\n"
            f"  expected: a cell that contains `{needle}` AND differs from the example\n"
            f"  hint:     write your own version, not a copy of the prompt's example\n"
        )

passed(f"Found {len(matched_cells)} cell(s) containing `{needle}`")