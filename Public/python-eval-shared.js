// Public/python-eval-shared.js
//
// The cells the pattern-family editor's auto-compute runs on the xeus-python
// kernel, and the parsing of what comes back. The counterpart to
// python-grading-shared.js, for a different job: grading answers "what exit code
// did this script produce", this answers "what value did this expression
// evaluate to".
//
// Why this needs its own module at all — the one genuinely new problem in
// moving auto-compute off Pyodide (#1271, plan §A2). `py.runPythonAsync(src)`
// RETURNS the last expression's value, and the editor read that return value
// directly. A Jupyter `execute_request` returns nothing; it publishes messages.
// So the value has to come back out some other way.
//
// It is printed behind a per-run nonce and parsed back, exactly as the grading
// path does. The alternative — reading `execute_result` off the iopub stream —
// looks simpler but couples the contract to display formatting (`repr`
// truncation, `ast_node_interactivity`), which is a worse thing to depend on
// than a delimiter we control. The nonce is what stops the instructor's own
// solution output from forging the boundary by printing something that looks
// like a payload.
//
// Loading: classic script (importScripts). Requires /python-grading-shared.js
// first, whose `makeNonce` and kernel spec are reused rather than duplicated —
// one definition of which kernel "the Python kernel" means.
// Exposes exactly one global: ChickadeePythonEvalShared.

(function (root) {
    'use strict';

    var grading = root.ChickadeePythonGradingShared;

    // Run one solution-notebook cell, reporting whether it raised.
    //
    // Errors are caught rather than propagated because a notebook's cells are
    // loaded in order and an early failure must not stop later cells from
    // defining their functions — the editor explains a downstream "function not
    // defined" in terms of the earlier cell that crashed, which it can only do
    // if it got that far. This mirrors what the Pyodide path did by catching
    // around each `runPythonAsync`.
    //
    // The reported message is the LAST non-empty line of the traceback, which is
    // the exception line — same slice the Pyodide path took off `err.message`.
    function loadCellPython(source, nonce) {
        var marker = JSON.stringify('\n' + nonce + ':');
        return [
            'import json as _ck_json, traceback as _ck_tb',
            '_ck_err = None',
            'try:',
            indent(source),
            'except BaseException:',
            '    _ck_lines = [l for l in _ck_tb.format_exc().split("\\n") if l.strip()]',
            '    _ck_err = _ck_lines[-1] if _ck_lines else "error"',
            'print(' + marker + ' + _ck_json.dumps({"error": _ck_err}))',
        ].join('\n');
    }

    // Evaluate `source` and report its last expression's value as a string.
    //
    // `str()` rather than `repr()`: the editor's snippets already produce a JSON
    // string, and the Pyodide path handed that value straight back. A value that
    // is None (the snippet ended in a statement, not an expression) comes back
    // as null so the caller can tell "evaluated to nothing" from "evaluated to
    // the string 'None'".
    function runExpressionPython(source, nonce) {
        var marker = JSON.stringify('\n' + nonce + ':');
        return [
            'import json as _ck_json, traceback as _ck_tb, ast as _ck_ast',
            '_ck_value = None',
            '_ck_err = None',
            'try:',
            '    _ck_src = ' + JSON.stringify(String(source)),
            '    _ck_tree = _ck_ast.parse(_ck_src)',
            // Split the trailing expression off so it can be `eval`d for its
            // value; everything before it is executed for its side effects.
            // This is what reproduces runPythonAsync's last-expression semantics.
            '    if _ck_tree.body and isinstance(_ck_tree.body[-1], _ck_ast.Expr):',
            '        _ck_last = _ck_tree.body.pop()',
            '        exec(compile(_ck_tree, "<auto-compute>", "exec"), globals())',
            '        _ck_value = eval(',
            '            compile(_ck_ast.Expression(_ck_last.value), "<auto-compute>", "eval"),',
            '            globals())',
            '    else:',
            '        exec(compile(_ck_tree, "<auto-compute>", "exec"), globals())',
            'except BaseException:',
            '    _ck_lines = [l for l in _ck_tb.format_exc().split("\\n") if l.strip()]',
            '    _ck_err = _ck_lines[-1] if _ck_lines else "error"',
            'print(' + marker + ' + _ck_json.dumps({',
            '    "value": None if _ck_value is None else str(_ck_value),',
            '    "error": _ck_err,',
            '}))',
        ].join('\n');
    }

    /// Indents every line by four spaces so arbitrary cell source can sit inside
    /// a `try:` block. A blank line stays blank — trailing whitespace in a cell
    /// is not worth preserving and some linters reject it.
    function indent(source) {
        return String(source == null ? '' : source)
            .split('\n')
            .map(function (line) { return line.trim() === '' ? '' : '    ' + line; })
            .join('\n');
    }

    /// The payload a cell printed behind `nonce`, or null when it never
    /// reported — a kernel that died mid-cell, or output the nonce never
    /// reached. Callers treat null as a substrate failure rather than a result.
    function parseEvalOutput(stdoutText, nonce) {
        var text = String(stdoutText == null ? '' : stdoutText);
        var marker = '\n' + nonce + ':';
        var at = text.lastIndexOf(marker);
        if (at < 0) return null;
        var from = at + marker.length;
        var end = text.indexOf('\n', from);
        var line = end < 0 ? text.slice(from) : text.slice(from, end);
        var payload;
        try { payload = JSON.parse(line); } catch (_) { return null; }
        if (!payload || typeof payload !== 'object') return null;
        return {
            value: typeof payload.value === 'string' ? payload.value : null,
            error: typeof payload.error === 'string' ? payload.error : null,
        };
    }

    root.ChickadeePythonEvalShared = {
        PYTHON_KERNEL: grading.PYTHON_KERNEL,
        makeNonce: grading.makeNonce,
        loadCellPython: loadCellPython,
        runExpressionPython: runExpressionPython,
        parseEvalOutput: parseEvalOutput,
    };
})(typeof self !== 'undefined' ? self : globalThis);
