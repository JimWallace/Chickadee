// APIServer/Utilities/NotebookCheckRenderer+Code.swift
//
// Code-AST check renderers (.functionExists, .variableExists, .astStructure).
// Split from NotebookCheckRenderer.swift for navigability.

import Core
import Foundation

// MARK: - .functionExists

func defaultFunctionExistsLabel(_ check: NotebookCheck) -> String {
    let name = check.variable ?? "function"
    if let arity = check.expectedArity {
        return "`\(name)` is defined and takes \(arity) arg\(arity == 1 ? "" : "s")"
    }
    return "`\(name)` is defined and callable"
}

func renderFunctionExists(_ check: NotebookCheck, specHash: String) -> String {
    let name = check.variable ?? "function"
    let label = check.name ?? defaultFunctionExistsLabel(check)
    let nameLiteral = "\"" + escapeForPythonStringLiteral(name) + "\""

    let arityCheck: String
    if let arity = check.expectedArity {
        arityCheck = """
            # Compare against required + optional positional params (with
            # leniency for *args).  Mirrors test_runtime.py's _require_num_args.
            try:
                sig = inspect.signature(fn)
            except (TypeError, ValueError):
                sig = None
            if sig is not None:
                positional_kinds = {
                    inspect.Parameter.POSITIONAL_ONLY,
                    inspect.Parameter.POSITIONAL_OR_KEYWORD,
                }
                params = [p for p in sig.parameters.values() if p.kind in positional_kinds]
                required = sum(1 for p in params if p.default is inspect.Parameter.empty)
                total = len(params)
                accepts_varargs = any(
                    p.kind == inspect.Parameter.VAR_POSITIONAL for p in sig.parameters.values()
                )
                expected_arity = \(arity)
                if accepts_varargs:
                    if expected_arity < required:
                        failed(
                            f"`{name}` requires at least {required} positional argument(s) "
                            f"but the test expected it to take {expected_arity}."
                        )
                elif not (required <= expected_arity <= total):
                    if required == total:
                        failed(
                            f"`{name}` should take {expected_arity} argument(s), "
                            f"but it takes {total}."
                        )
                    else:
                        failed(
                            f"`{name}` should take {expected_arity} argument(s), "
                            f"but it takes {required}-{total}."
                        )
            """
    } else {
        arityCheck = "# (no arity check; existence + callability only)"
    }

    return """
        # Test: \(label)
        # Generated from notebook check "\(escapeForPythonStringLiteral(check.id))" kind=function_exists spec_hash=\(specHash) — edit the check, not this file.

        import inspect

        name = \(nameLiteral)

        _MISSING = object()
        fn = getattr(student_module, name, _MISSING)
        if fn is _MISSING:
            failed(
                f"`{name}` is not defined in the student notebook.\\n"
                f"  expected: a callable named `{name}`\\n"
            )

        if not callable(fn):
            failed(
                f"`{name}` is defined but not callable.\\n"
                f"  got: {type(fn).__name__}\\n"
            )

        \(arityCheck)

        passed(f"`{name}` is defined and callable")
        """
}

// MARK: - .variableExists

func defaultVariableExistsLabel(_ check: NotebookCheck) -> String {
    let name = check.variable ?? "variable"
    if let typeName = check.expectedType, !typeName.isEmpty {
        return "`\(name)` is defined and is a \(typeName)"
    }
    return "`\(name)` is defined"
}

func renderVariableExists(_ check: NotebookCheck, specHash: String) -> String {
    let name = check.variable ?? "variable"
    let label = check.name ?? defaultVariableExistsLabel(check)
    let nameLiteral = "\"" + escapeForPythonStringLiteral(name) + "\""

    let typeCheck: String
    let passMessage: String
    if let typeName = check.expectedType, !typeName.isEmpty {
        let typeNameLiteral = "\"" + escapeForPythonStringLiteral(typeName) + "\""
        let typeCheckExpr = pythonTypeCheckExpression(typeName: typeName, valueExpr: "actual")
        typeCheck = """
            expected_type_name = \(typeNameLiteral)
            if not (\(typeCheckExpr)):
                failed(
                    f"Variable `{name}` has the wrong type.\\n"
                    f"  expected: {expected_type_name}\\n"
                    f"  got:      {type(actual).__name__}\\n"
                )
            """
        passMessage = #"f"`{name}` is defined and is a {expected_type_name}""#
    } else {
        typeCheck = "# (no type check; existence only)"
        passMessage = #"f"`{name}` is defined""#
    }

    return """
        # Test: \(label)
        # Generated from notebook check "\(escapeForPythonStringLiteral(check.id))" kind=variable_exists spec_hash=\(specHash) — edit the check, not this file.

        name = \(nameLiteral)

        _MISSING = object()
        actual = getattr(student_module, name, _MISSING)
        if actual is _MISSING:
            failed(
                f"Variable `{name}` is not defined in the student notebook.\\n"
                f"  expected: a module-level variable named `{name}`\\n"
            )

        \(typeCheck)

        passed(\(passMessage))
        """
}

// MARK: - .astStructure

func defaultASTStructureLabel(_ check: NotebookCheck) -> String {
    let constructs = check.requiredConstructs ?? []
    if constructs.isEmpty { return "Notebook AST structure" }
    let preview = constructs.prefix(3).joined(separator: ", ")
    let suffix = constructs.count > 3 ? ", …" : ""
    return "Notebook uses \(preview)\(suffix)"
}

func renderASTStructure(_ check: NotebookCheck, specHash: String) -> String {
    let constructs = check.requiredConstructs ?? []
    let label = check.name ?? defaultASTStructureLabel(check)

    let constructsLiteral =
        "["
        + constructs.map { c in
            "\"" + escapeForPythonStringLiteral(c) + "\""
        }.joined(separator: ", ") + "]"

    let header = """
        # Test: \(label)
        # Generated from notebook check "\(escapeForPythonStringLiteral(check.id))" kind=ast_structure spec_hash=\(specHash) — edit the check, not this file.

        import ast
        import json
        from pathlib import Path

        required = \(constructsLiteral)

        """

    return header + astStructureRuntimeBody
}

/// Static Python runtime that walks the student notebook's AST and
/// evaluates the `required` predicate list.  Spec hash + label live in
/// the per-check header; the body itself never changes.
private let astStructureRuntimeBody: String = """
    # SubmissionNormalizer (v0.4.114+) preserves the original notebook
    # alongside the flattened .py.  Walk every code cell's AST and
    # check for the listed constructs.
    notebook_path = Path("_submission.ipynb")
    if not notebook_path.exists():
        errored(
            "Student notebook source not preserved — cannot run AST structure check.\\n"
            "  expected: _submission.ipynb in workspace\\n"
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
        sources.append("\\n".join(kept))

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
            "structural requirements not met\\n"
            f"  failed: {'; '.join(failures)}\\n"
        )

    passed(f"All {len(required)} AST predicate(s) satisfied")
    """
