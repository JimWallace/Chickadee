# Test: Check
# Generated from notebook check "chk" kind=ast_structure spec_hash=9b85bd7e77662d07 — edit the check, not this file.

import ast
import json
from pathlib import Path

required = []
# SubmissionNormalizer (v0.4.114+) preserves the original notebook
# alongside the flattened .py.  Walk every code cell's AST and
# check for the listed constructs.
notebook_path = Path("_submission.ipynb")
if not notebook_path.exists():
    errored(
        "Student notebook source not preserved — cannot run AST structure check.\n"
        "  expected: _submission.ipynb in workspace\n"
    )

try:
    notebook = json.loads(notebook_path.read_text(encoding="utf-8"))
except Exception as ex:
    errored(f"Could not parse _submission.ipynb: {ex}")

sources = []
for cell in notebook.get("cells", []):
    if cell.get("cell_type") != "code":
        continue
    src = cell.get("source", "")
    if isinstance(src, list):
        src = "".join(src)
    # Strip Jupyter magics so ast.parse doesn't choke on `%pip` etc.
    kept = []
    for line in src.splitlines():
        stripped = line.lstrip()
        if stripped.startswith("%") or stripped.startswith("!"):
            continue
        kept.append(line)
    sources.append("\n".join(kept))

# Parse every cell.  Cells that fail to parse are skipped silently —
# student syntax errors will already trip other tests.
trees = []
for src in sources:
    try:
        trees.append(ast.parse(src))
    except Exception:
        continue

def has_node_type(node_class):
    for tree in trees:
        for node in ast.walk(tree):
            if isinstance(node, node_class):
                return True
    return False

def has_import(module_name):
    for tree in trees:
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                for alias in node.names:
                    if alias.name == module_name or alias.name.startswith(module_name + "."):
                        return True
            elif isinstance(node, ast.ImportFrom):
                if (node.module or "") == module_name or (node.module or "").startswith(module_name + "."):
                    return True
    return False

def has_recursion():
    # Heuristic: a function that calls itself by name in its body.
    # Catches the common case (def foo: ... foo(...)) without
    # tripping on every passive `foo()` reference outside foo.
    for tree in trees:
        for node in ast.walk(tree):
            if not isinstance(node, ast.FunctionDef):
                continue
            fn_name = node.name
            for inner in ast.walk(node):
                if (isinstance(inner, ast.Call)
                    and isinstance(inner.func, ast.Name)
                    and inner.func.id == fn_name):
                    return True
    return False

def evaluate(predicate):
    # Returns True if the predicate holds across all parsed cells.
    if predicate.startswith("import:"):
        return has_import(predicate.split(":", 1)[1])
    if predicate == "for_loop":
        return has_node_type(ast.For)
    if predicate == "while_loop":
        return has_node_type(ast.While)
    if predicate == "list_comprehension":
        return has_node_type(ast.ListComp)
    if predicate == "lambda":
        return has_node_type(ast.Lambda)
    if predicate == "recursion":
        return has_recursion()
    # Unknown predicate — fail rather than silently passing, so the
    # instructor notices a typo at grading time.
    failed(f"Unknown AST predicate `{predicate}` — supported: for_loop, while_loop, list_comprehension, lambda, recursion, import:<module>")

failures = []
for raw in required:
    negate = raw.startswith("!")
    predicate = raw[1:] if negate else raw
    actual = evaluate(predicate)
    expected = not negate
    if actual != expected:
        verb = "must NOT use" if negate else "must use"
        failures.append(f"{verb} {predicate}")

if failures:
    failed(
        "structural requirements not met\n"
        f"  failed: {'; '.join(failures)}\n"
    )

passed(f"All {len(required)} AST predicate(s) satisfied")