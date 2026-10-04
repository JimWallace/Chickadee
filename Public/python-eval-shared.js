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
// The call snippets are here too, as they are for the other languages. The
// editor sends the structured `call` message, and the worker builds the cell
// (#1964). Before, the editor built the Python snippets itself and sent `run`.
//
// Loading: classic script (importScripts). Requires /python-grading-shared.js
// first, whose `makeNonce` and kernel spec are reused rather than duplicated —
// one definition of which kernel "the Python kernel" means; and
// /eval-protocol-shared.js, which owns the nonce framing now that more than one
// language reports through it.
// Exposes exactly one global: ChickadeePythonEvalShared.

(function (root) {
    'use strict';

    var grading = root.ChickadeePythonGradingShared;
    // The nonce framing is language-neutral and shared with the other
    // in-page evaluators; only the SNIPPETS below are Python.
    var protocol = root.ChickadeeEvalProtocol;

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
    // `str()` rather than `repr()`: the call snippets below already produce a
    // JSON string, and `readCallResultPython` parses it as it is. A value that
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

    /// The Python that one auto-compute call runs. It finds `functionName` in
    /// the loaded solution, calls it with `args`, and ends on an expression
    /// whose value is a JSON payload.
    ///
    /// The payload has a `__chickadee_kind__` key. It is not the bare return
    /// value, because `json.dumps(None)` is the string "null", and that string
    /// once went into the Expected cell as if the instructor had typed it. The
    /// same key flags the return types that do not round-trip through JSON
    /// (coroutines, generators, sets, tuples, bytes, complex). The instructor
    /// then sees the reason, and not a repr that `default=str` stored.
    /// `readCallResultPython` reads the key back.
    ///
    /// THE LAST TOP-LEVEL STATEMENT MUST BE AN EXPRESSION (`ast.Expr`).
    /// `runExpressionPython` reports only the value of a trailing expression.
    /// A snippet that ends in an `if`, a `with` or an assignment reports no
    /// value, and auto-compute stops with no error. Thus each snippet puts its
    /// payload in `_payload` and ends on a bare `_json.dumps(...)`.
    /// pattern-family-editor.test.mjs parses both snippets to check this. Do
    /// not move work below that last line.
    ///
    /// With `options.captureStdout`, the payload holds what the function
    /// PRINTED, not what it returned. A stdout-equality case needs this.
    function callSnippetPython(functionName, args, options) {
        var fnLit = JSON.stringify(functionName);
        // The arguments go in as one JSON string, and Python parses it. A JSON
        // string literal is also a valid Python string literal.
        var argsLit = JSON.stringify(JSON.stringify(args));
        if (options && options.captureStdout) {
            return [
                'import json as _json',
                'import io as _io',
                'import contextlib as _contextlib',
                'import inspect as _inspect',
                '_fn = globals().get(' + fnLit + ')',
                'if _fn is None:',
                '    raise NameError(' + fnLit + ' + " not defined in solution notebook")',
                '_args = _json.loads(' + argsLit + ')',
                '_buf = _io.StringIO()',
                'with _contextlib.redirect_stdout(_buf):',
                '    _ret = _fn(*_args)',
                // An async function used by mistake: `_fn(*_args)` returns a
                // coroutine and does not run the body. Thus `_buf` is empty,
                // and the instructor would see a blank Expected. Report it.
                'if _inspect.iscoroutine(_ret):',
                '    _payload = {"__chickadee_kind__": "unsupported", "reason": "coroutine"}',
                'elif _inspect.isasyncgen(_ret):',
                '    _payload = {"__chickadee_kind__": "unsupported", "reason": "async-generator"}',
                'else:',
                '    _captured = _buf.getvalue()',
                // The renderer removes one trailing newline too. Thus the
                // computed Expected is the text the generated test compares.
                '    if _captured.endswith("\\n"):',
                '        _captured = _captured[:-1]',
                '    _payload = {"__chickadee_kind__": "value", "value": _captured}',
                '_json.dumps(_payload)'
            ].join('\n');
        }
        return [
            'import json as _json',
            'import inspect as _inspect',
            '_fn = globals().get(' + fnLit + ')',
            'if _fn is None:',
            '    raise NameError(' + fnLit + ' + " not defined in solution notebook")',
            '_args = _json.loads(' + argsLit + ')',
            '_result = _fn(*_args)',
            // Each return type below would go through `default=str` as a repr
            // string. Report a specific reason for it instead.
            'if _inspect.iscoroutine(_result):',
            '    _payload = {"__chickadee_kind__": "unsupported", "reason": "coroutine"}',
            'elif _inspect.isasyncgen(_result):',
            '    _payload = {"__chickadee_kind__": "unsupported", "reason": "async-generator"}',
            'elif _inspect.isgenerator(_result):',
            '    _payload = {"__chickadee_kind__": "unsupported", "reason": "generator"}',
            'elif isinstance(_result, (set, frozenset)):',
            '    _payload = {"__chickadee_kind__": "unsupported", "reason": "set"}',
            // A tuple serializes to JSON, but it comes back as a list. The
            // generated test compares with `==`, and `(1, 2) == [1, 2]` is
            // False, so the test would fail with no clear cause.
            'elif isinstance(_result, tuple):',
            '    _payload = {"__chickadee_kind__": "unsupported", "reason": "tuple"}',
            'elif isinstance(_result, (bytes, bytearray)):',
            '    _payload = {"__chickadee_kind__": "unsupported", "reason": "bytes"}',
            'elif isinstance(_result, complex):',
            '    _payload = {"__chickadee_kind__": "unsupported", "reason": "complex"}',
            'elif _result is None:',
            '    _payload = {"__chickadee_kind__": "none"}',
            'else:',
            '    _payload = {"__chickadee_kind__": "value", "value": _result}',
            '_json.dumps(_payload, default=str)'
        ].join('\n');
    }

    /// The cell that the `call` message runs: the call snippet, evaluated by
    /// `runExpressionPython`. Its value is the snippet's JSON payload, and
    /// `readCallResultPython` reads it.
    function callFunctionPython(functionName, args, options, nonce) {
        return runExpressionPython(callSnippetPython(functionName, args, options), nonce);
    }

    /// The fields of a `call` reply, from the payload of a call snippet:
    ///   { result }                            the function returned a value
    ///   { result: null, returnedNone: true }  the function returned None
    ///   { unsupported: <reason> }             the value does not round-trip
    ///                                         through JSON
    /// The editor reads the same fields for every language.
    function readCallResultPython(text) {
        var payload = JSON.parse(text);
        if (payload && payload.__chickadee_kind__ === 'none') {
            return { result: null, returnedNone: true };
        }
        if (payload && payload.__chickadee_kind__ === 'unsupported') {
            return { unsupported: payload.reason || 'unknown' };
        }
        return { result: payload.value };
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

    root.ChickadeePythonEvalShared = {
        PYTHON_KERNEL: grading.PYTHON_KERNEL,
        makeNonce: grading.makeNonce,
        loadCellPython: loadCellPython,
        runExpressionPython: runExpressionPython,
        callSnippetPython: callSnippetPython,
        callFunctionPython: callFunctionPython,
        readCallResultPython: readCallResultPython,
        parseEvalOutput: protocol.parseEvalOutput,
    };
})(typeof self !== 'undefined' ? self : globalThis);
