// Public/octave-eval-shared.js
//
// The snippets the pattern-family editor's auto-compute runs on the xeus-octave
// kernel. The Octave sibling of r-eval-shared.js and lua-eval-shared.js; the
// nonce framing all of them share lives in eval-protocol-shared.js.
//
// Loading: classic script (importScripts). Requires /octave-grading-shared.js
// first (kernel spec, `makeNonce`, `octaveStringLiteral`, `octaveLiteral`) and
// /eval-protocol-shared.js. Exposes exactly one global:
// ChickadeeOctaveEvalShared.
//
// WHAT OCTAVE COSTS, AND WHAT IT DOES NOT.
//
// It does not cost either of the other kernels' shape constraints. R's snippets
// are one top-level expression because xeus-r yields ~180ms between them; Lua's
// are one call expression because xeus-lua mis-reads a cell opening with a
// `local`. Octave has neither problem, and its cells share one base workspace,
// so a plain statement list is fine and a variable set in one cell is visible in
// the next. Only the BOOT cell needs a shape: `1;` first, so the cell reads as a
// script and the `function` definitions in it register as command-line functions
// rather than making the cell a function file. That is the same guard
// `SETUP_OCTAVE` opens with in the grading module.
//
// What it does cost is the submission contract, which is Octave's alone: a
// solution cell is evaluated as `["1;" newline text]` so its definitions
// register under their OWN names whatever the cell looks like — the rule
// `test_runtime.m` already uses, quoted in its header as "THE SUBMISSION
// CONTRACT". Without the prefix, a cell holding one function would be read as a
// function file and bind under the file's name instead.
//
// VALUES COME BACK AS OCTAVE SOURCE (`chickadee_serialize`), which is what the
// SERVER driver returns for Octave — it writes that text into `_ck_inputs.m`.
// The client parses both with the same reader, so in-page and server
// auto-compute cannot disagree about what a value looks like.
//
// Every payload is written with `fputs`, never `printf`: an Octave error
// message can contain a literal `%` (`error("bad %s", "100%")` produces one),
// and a `printf` whose format string carried the payload would consume it.

(function (root) {
    'use strict';

    var grading = root.ChickadeeOctaveGradingShared;
    var protocol = root.ChickadeeEvalProtocol;

    /// Prefixes the `1;` script guard so the seeded runtime's `function`
    /// definitions register as command-line functions. The runtime itself is
    /// executed verbatim: its bytes come from
    /// `AssignmentLanguage.autoComputeRuntimeSource`, so the serializer that
    /// reports a value here is the one the personalization driver uses.
    function bootCell(runtimeSource) {
        return '1;\n' + runtimeSource;
    }

    /// Statements binding `<jsonName>` to a JSON string for `<varName>`, or the
    /// bare token `null` when the matching `<haveName>` flag is false.
    ///
    /// A separate flag rather than `isempty`, because the empty string is a
    /// legitimate value — a solution that returns "" would otherwise report as
    /// having returned nothing.
    ///
    /// `chickadee_escape_string` is the SEEDED escaper, not one written here.
    function jsonOrNull(varName, haveName, jsonName) {
        return [
            'if ' + haveName,
            '  ' + jsonName + ' = chickadee_escape_string(' + varName + ');',
            'else',
            '  ' + jsonName + ' = "null";',
            'end'
        ];
    }

    /// One `fputs` writing the marker, the JSON, and a newline.
    function payloadWrite(nonce, parts) {
        var pieces = [grading.octaveStringLiteral(protocol.payloadMarker(nonce))]
            .concat(parts)
            .concat([grading.octaveStringLiteral('\n')]);
        return 'fputs(stdout, [' + pieces.join(', ') + ']);';
    }

    /// Run one solution-notebook cell, reporting whether it raised.
    ///
    /// Evaluated at the top level of the cell, so its variables land in the base
    /// workspace and its functions register globally — both visible to later
    /// cells and to the call snippet, which is the entire point of loading it.
    ///
    /// Errors are caught rather than propagated: cells load in order, and an
    /// early failure must not stop later cells from defining their functions.
    /// The editor explains a downstream "not defined" in terms of the earlier
    /// cell that crashed, which it can only do if it got that far.
    function loadCellOctave(source, nonce) {
        return [
            'ck_err_ = "";',
            'ck_have_err_ = false;',
            'try',
            // See the header: the `1;` prefix is the submission contract, not
            // decoration.
            '  eval(["1;" sprintf("\\n") ' + grading.octaveStringLiteral(source) + ']);',
            'catch ck_e_',
            '  ck_err_ = ck_e_.message;',
            '  ck_have_err_ = true;',
            'end'
        ].concat(jsonOrNull('ck_err_', 'ck_have_err_', 'ck_err_json_')).concat([
            payloadWrite(nonce, [
                grading.octaveStringLiteral('{"error":'),
                'ck_err_json_',
                grading.octaveStringLiteral('}')
            ])
        ]).join('\n');
    }

    /// Evaluate `source` and report its value as Octave source.
    ///
    /// `eval` yields a value only for an expression, so a statement is run in a
    /// second attempt and reports no value — the same two-step the Lua module
    /// takes for the same reason. The editor's own path is `callFunction`; this
    /// exists because the worker protocol serves both.
    function runExpressionOctave(source, nonce) {
        var sourceLiteral = grading.octaveStringLiteral(source);
        return [
            'ck_err_ = "";',
            'ck_have_err_ = false;',
            'ck_val_ = "";',
            'ck_have_val_ = false;',
            'try',
            '  ck_res_ = eval(' + sourceLiteral + ');',
            '  ck_val_ = chickadee_serialize(ck_res_);',
            '  ck_have_val_ = true;',
            'catch',
            '  try',
            '    eval(' + sourceLiteral + ');',
            '  catch ck_e_',
            '    ck_err_ = ck_e_.message;',
            '    ck_have_err_ = true;',
            '  end',
            'end'
        ].concat(jsonOrNull('ck_val_', 'ck_have_val_', 'ck_val_json_'))
            .concat(jsonOrNull('ck_err_', 'ck_have_err_', 'ck_err_json_'))
            .concat([
                payloadWrite(nonce, [
                    grading.octaveStringLiteral('{"value":'),
                    'ck_val_json_',
                    grading.octaveStringLiteral(',"error":'),
                    'ck_err_json_',
                    grading.octaveStringLiteral('}')
                ])
            ]).join('\n');
    }

    /// Call `functionName` in the loaded solution with `args`, reporting the
    /// result as Octave source.
    ///
    /// THE ARGUMENTS ARE RENDERED HERE, in the browser, by the JS twin of
    /// `JSONValue.octaveLiteral` — because an instructor changing a case has not
    /// saved it, so there is no server round-trip in which the server could
    /// render them. Both renderers are pinned to
    /// Tests/Fixtures/octave-literal-contract.json.
    ///
    /// Each argument gets its own variable, which is how the generated test
    /// binds them too, and it keeps the brackets-vs-braces question inside the
    /// renderer rather than in an argument list this file would have to build.
    ///
    /// The lookup admits both shapes a solution can define: a command-line
    /// function (`exist` 103, or a file at 2) and a handle assigned to a
    /// variable (`exist` 1) — the same pair `test_runtime.m`'s `require_fn`
    /// accepts, so auto-compute does not refuse a solution the grader would run.
    ///
    /// A COMMAND-LINE FUNCTION IS CALLED BY NAME, never through `str2func`.
    /// Measured: after defining `area`, `exist("area")` answers 103 — the
    /// command-line function — while `str2func("area")` hands back Octave's
    /// BUILT-IN `area`, the plotting one. `feval` and `nargout` given the name
    /// resolve it correctly. A solution that defines a function sharing a
    /// builtin's name is ordinary (`area`, `count`, `mean`), so this is not an
    /// edge case; the failure it prevents is auto-compute silently reporting
    /// what a completely different function returned.
    function callFunctionOctave(functionName, args, options, nonce) {
        var captureStdout = !!(options && options.captureStdout);
        var nameLiteral = grading.octaveStringLiteral(functionName);
        var argValues = args || [];
        var bindings = argValues.map(function (value, index) {
            return '    ck_a' + (index + 1) + '_ = ' + grading.octaveLiteral(value) + ';';
        });
        var argList = argValues.map(function (_, index) { return 'ck_a' + (index + 1) + '_'; });
        var invocation = ['ck_callee_'].concat(argList).join(', ');

        var body;
        if (captureStdout) {
            // `evalc` captures what the call printed. The trailing semicolon
            // suppresses the `ans = …` echo a value-returning function would
            // otherwise add to the capture.
            body = [
                '    ck_out_ = evalc(' + grading.octaveStringLiteral(
                    'feval(' + invocation + ');') + ');',
                // One trailing newline is dropped, matching what the other
                // languages store.
                '    if numel(ck_out_) > 0 && ck_out_(end) == sprintf("\\n")',
                '      ck_out_ = ck_out_(1:end-1);',
                '    end',
                '    ck_val_ = chickadee_serialize(ck_out_);',
                '    ck_have_val_ = true;'
            ];
        } else {
            body = [
                // A function declaring no output cannot be assigned from —
                // `ck_res_ = feval(…)` would raise "value on right hand side of
                // assignment is undefined", which reads as a solution error
                // rather than as "it returned nothing".
                '    if nargout(ck_callee_) == 0',
                '      feval(' + invocation + ');',
                '    else',
                '      ck_res_ = feval(' + invocation + ');',
                '      ck_val_ = chickadee_serialize(ck_res_);',
                '      ck_have_val_ = true;',
                '    end'
            ];
        }

        return [
            'ck_err_ = "";',
            'ck_have_err_ = false;',
            'ck_val_ = "";',
            'ck_have_val_ = false;',
            'ck_callee_ = [];',
            'ck_kind_ = exist(' + nameLiteral + ');',
            'if ck_kind_ == 1',
            '  ck_tmp_ = eval(' + nameLiteral + ');',
            '  if is_function_handle(ck_tmp_)',
            '    ck_callee_ = ck_tmp_;',
            '  end',
            'elseif ck_kind_ != 0',
            // The name itself, not str2func — see the note above.
            '  ck_callee_ = ' + nameLiteral + ';',
            'end',
            'if isempty(ck_callee_)',
            // "not defined" is the phrase describeCallFailure looks for when it
            // decides whether to fold in the first failing solution cell.
            '  ck_err_ = [' + nameLiteral + ' " is not defined in the solution notebook"];',
            '  ck_have_err_ = true;',
            'else',
            '  try'
        ].concat(bindings).concat(body).concat([
            '  catch ck_e_',
            '    ck_err_ = ck_e_.message;',
            '    ck_have_err_ = true;',
            '  end',
            'end'
        ]).concat(jsonOrNull('ck_val_', 'ck_have_val_', 'ck_val_json_'))
            .concat(jsonOrNull('ck_err_', 'ck_have_err_', 'ck_err_json_'))
            .concat([
                payloadWrite(nonce, [
                    grading.octaveStringLiteral('{"value":'),
                    'ck_val_json_',
                    grading.octaveStringLiteral(',"error":'),
                    'ck_err_json_',
                    grading.octaveStringLiteral('}')
                ])
            ]).join('\n');
    }

    root.ChickadeeOctaveEvalShared = {
        OCTAVE_KERNEL: grading.OCTAVE_KERNEL,
        makeNonce: grading.makeNonce,
        bootCell: bootCell,
        loadCell: loadCellOctave,
        runExpression: runExpressionOctave,
        callFunction: callFunctionOctave,
        parseEvalOutput: protocol.parseEvalOutput,
    };
})(typeof self !== 'undefined' ? self : globalThis);
