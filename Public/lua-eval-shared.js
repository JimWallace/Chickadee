// Public/lua-eval-shared.js
//
// The snippets the pattern-family editor's auto-compute runs on the xeus-lua
// kernel. The Lua sibling of r-eval-shared.js and python-eval-shared.js; the
// nonce framing all three share lives in eval-protocol-shared.js.
//
// Loading: classic script (importScripts). Requires /lua-grading-shared.js
// first (kernel spec, `makeNonce`, `luaStringLiteral`, `luaLiteral`) and
// /eval-protocol-shared.js. Exposes exactly one global: ChickadeeLuaEvalShared.
//
// THREE LUA FACTS SHAPE EVERY SNIPPET BELOW, and only one of them is R's.
//
// 1. EVERY CELL IS ITS OWN CHUNK, so `local` does not persist. That is why the
//    seeded runtime ends by re-binding its two helpers as globals (in Swift, in
//    `LuaPersonalizationRuntime.chickadeeAutoComputeExportsLuaSource`) and why
//    the snippets here reach them by bare name.
//
// 2. ONE CALL EXPRESSION PER CELL — the same shape lua-grading-shared.js uses,
//    for the same reason and NOT for R's. xeus-lua first tries to compile a
//    cell as `return <cell>` so it can report a value and falls back to running
//    it as a block; a cell that opens with a `local` declaration and then uses
//    it satisfies neither reading, and the fallback reports the name as an
//    undefined global. Wrapping the body in a function the kernel never
//    re-parses sidesteps the question. R's ~180ms inter-expression yield, the
//    reason ITS snippets are one expression, does not exist here: measured, 20
//    top-level statements cost 5ms on this kernel.
//
// 3. VALUES COME BACK AS LUA SOURCE (`chickadee_serialize`), which is exactly
//    what the SERVER driver returns for Lua — it writes that text verbatim into
//    `_ck_inputs.lua`. The client parses both with the same language-aware
//    reader, so in-page and server auto-compute cannot disagree about what a
//    value looks like. Lua has no JSON and no `deparse`; this is its `repr`.

(function (root) {
    'use strict';

    var grading = root.ChickadeeLuaGradingShared;
    var protocol = root.ChickadeeEvalProtocol;

    /// Wraps the seeded runtime so the kernel accepts it — see fact 2.
    ///
    /// The runtime is otherwise executed verbatim: its bytes come from
    /// `AssignmentLanguage.autoComputeRuntimeSource`, so the serializer that
    /// reports a value here is the one the personalization driver uses on the
    /// server, not a copy written in this file.
    function bootCell(runtimeSource) {
        return '(function()\n' + runtimeSource + '\nend)()';
    }

    /// Statements binding `<jsonName>` to a JSON string for `<varName>`, or the
    /// bare token `null` when it holds nothing.
    ///
    /// `chickadee_json_str` is the SEEDED encoder. A copy written here would be
    /// a third Lua JSON encoder in this codebase, and the one that gets a
    /// solution's error message — the text most likely to contain a quote.
    function jsonOrNull(varName, jsonName) {
        return [
            '  local ' + jsonName + ' = "null"',
            '  if ' + varName + ' ~= nil then '
                + jsonName + ' = chickadee_json_str(' + varName + ') end'
        ];
    }

    /// One `io.write` printing the marker, the JSON, and a newline.
    ///
    /// `io.write` concatenates its arguments with no separator, so unlike R's
    /// `cat` there is nothing to switch off.
    function payloadWrite(nonce, chunks) {
        var args = [grading.luaStringLiteral(protocol.payloadMarker(nonce))]
            .concat(chunks)
            .concat([grading.luaStringLiteral('\n')]);
        return '  io.write(' + args.join(', ') + ')';
    }

    /// Run one solution-notebook cell, reporting whether it raised.
    ///
    /// `load` with no environment argument compiles against the globals, so a
    /// `function f() end` in the cell defines a global `f` that later cells and
    /// the call snippet can see — the entire point of loading it.
    ///
    /// A syntax error and a runtime error are both reported, and neither is
    /// propagated: cells load in order, and an early failure must not stop
    /// later cells from defining their functions. The editor explains a
    /// downstream "not defined" in terms of the earlier cell that crashed,
    /// which it can only do if it got that far.
    function loadCellLua(source, nonce) {
        return [
            '(function()',
            '  local ck_err = nil',
            '  local ck_chunk, ck_syntax = load('
                + grading.luaStringLiteral(source) + ', "solution", "t")',
            '  if ck_chunk == nil then',
            '    ck_err = tostring(ck_syntax)',
            '  else',
            '    local ck_ok, ck_raised = pcall(ck_chunk)',
            '    if not ck_ok then ck_err = tostring(ck_raised) end',
            '  end'
        ].concat(jsonOrNull('ck_err', 'ck_err_json')).concat([
            payloadWrite(nonce, [
                grading.luaStringLiteral('{"error":'),
                'ck_err_json',
                grading.luaStringLiteral('}')
            ]),
            'end)()'
        ]).join('\n');
    }

    /// Evaluate `source` and report its value as Lua source.
    ///
    /// Lua has no `eval`: a chunk is the only way to turn text into a value, so
    /// the source is compiled as `return (<source>)` first and as a plain block
    /// only if that will not compile. Same two-step the server's Lua expression
    /// driver takes, and it is what makes a statement (which yields nothing)
    /// report a null value rather than a syntax error.
    function runExpressionLua(source, nonce) {
        return [
            '(function()',
            '  local ck_err = nil',
            '  local ck_val = nil',
            '  local ck_chunk, ck_syntax = load('
                + grading.luaStringLiteral('return (' + source + ')')
                + ', "expression", "t")',
            '  if ck_chunk == nil then',
            '    ck_chunk, ck_syntax = load('
                + grading.luaStringLiteral(source) + ', "expression", "t")',
            '  end',
            '  if ck_chunk == nil then',
            '    ck_err = tostring(ck_syntax)',
            '  else',
            '    local ck_ok, ck_res = pcall(ck_chunk)',
            '    if ck_ok then',
            '      if ck_res ~= nil then ck_val = chickadee_serialize(ck_res) end',
            '    else',
            '      ck_err = tostring(ck_res)',
            '    end',
            '  end'
        ].concat(jsonOrNull('ck_val', 'ck_val_json'))
            .concat(jsonOrNull('ck_err', 'ck_err_json'))
            .concat([
                payloadWrite(nonce, [
                    grading.luaStringLiteral('{"value":'),
                    'ck_val_json',
                    grading.luaStringLiteral(',"error":'),
                    'ck_err_json',
                    grading.luaStringLiteral('}')
                ]),
                'end)()'
            ]).join('\n');
    }

    /// The `print` / `io` swap that makes `captureStdout` work, and its undo.
    ///
    /// Lua has no `capture.output`. This is the generated `.stdoutEquality`
    /// test's capture, moved from the student's environment table into `_G` —
    /// the eval worker loads solution cells straight into the globals, so there
    /// is no per-submission table to shadow. It covers `print`, `io.write`,
    /// `io.stdout:write` and chained `io.write(a):write(b)`: the proxy's
    /// `write` drops a leading self argument and returns the handle. The one
    /// path it cannot reach is a solution that bound `local print = print`
    /// before the call — an upvalue frozen at load time, uncapturable by any
    /// per-call swap, in the generated test too.
    var CAPTURE_INSTALL = [
        '    local ck_captured = {}',
        '    local ck_real_print, ck_real_io = print, io',
        '    local ck_stdout = {}',
        '    function ck_stdout.write(...)',
        '      local n = select("#", ...)',
        '      local first = (n >= 1 and select(1, ...) == ck_stdout) and 2 or 1',
        '      for i = first, n do',
        '        ck_captured[#ck_captured + 1] = tostring((select(i, ...)))',
        '      end',
        '      return ck_stdout',
        '    end',
        '    _G.print = function(...)',
        '      local parts = {}',
        '      for i = 1, select("#", ...) do',
        '        parts[#parts + 1] = tostring((select(i, ...)))',
        '      end',
        '      ck_captured[#ck_captured + 1] = table.concat(parts, "\\t") .. "\\n"',
        '    end',
        '    _G.io = setmetatable(',
        '      { write = ck_stdout.write, stdout = ck_stdout },',
        '      { __index = ck_real_io })'
    ];

    /// Call `functionName` in the loaded solution with `args`, reporting the
    /// result as Lua source.
    ///
    /// THE ARGUMENTS ARE RENDERED HERE, in the browser, by the JS twin of
    /// `JSONValue.luaLiteral` — because an instructor changing a case has not
    /// saved it, so there is no server round-trip in which the server could
    /// render them. Both renderers are pinned to
    /// Tests/Fixtures/lua-literal-contract.json.
    ///
    /// Each argument gets its own `local`, exactly as the generated test binds
    /// `arg_1`, `arg_2`, …, rather than going into a table: a JSON null is
    /// `nil` at top level, and a table constructor does not store `nil` at all.
    /// Building an argument table would silently drop the slot and call the
    /// solution with the wrong arity.
    function callFunctionLua(functionName, args, options, nonce) {
        var captureStdout = !!(options && options.captureStdout);
        var nameLiteral = grading.luaStringLiteral(functionName);
        var argValues = args || [];
        var bindings = argValues.map(function (value, index) {
            return '    local ck_a' + (index + 1) + ' = '
                + grading.luaLiteral(value, false);
        });
        var argNames = argValues.map(function (_, index) { return 'ck_a' + (index + 1); });
        var invocation = ['ck_fn'].concat(argNames).join(', ');

        var body;
        if (captureStdout) {
            body = CAPTURE_INSTALL.concat([
                '    local ck_ok, ck_res = pcall(' + invocation + ')',
                '    _G.print, _G.io = ck_real_print, ck_real_io',
                '    if ck_ok then',
                '      local ck_text = table.concat(ck_captured)',
                // One trailing newline is dropped, matching what the Python
                // path stores. No further normalisation: the generated test
                // normalises BOTH sides, so trailing whitespace cannot decide a
                // comparison and duplicating its normaliser here would buy
                // nothing but a second copy to keep in step.
                '      if ck_text:sub(-1) == "\\n" then ck_text = ck_text:sub(1, -2) end',
                '      ck_val = chickadee_serialize(ck_text)',
                '    else',
                '      ck_err = tostring(ck_res)',
                '    end'
            ]);
        } else {
            body = [
                '    local ck_ok, ck_res = pcall(' + invocation + ')',
                '    if ck_ok then',
                '      if ck_res ~= nil then ck_val = chickadee_serialize(ck_res) end',
                '    else',
                '      ck_err = tostring(ck_res)',
                '    end'
            ];
        }

        return [
            '(function()',
            '  local ck_err = nil',
            '  local ck_val = nil',
            '  local ck_fn = _G[' + nameLiteral + ']',
            '  if type(ck_fn) ~= "function" then',
            // "not defined" is the phrase describeCallFailure looks for when it
            // decides whether to fold in the first failing solution cell.
            '    ck_err = ' + nameLiteral + ' .. " is not defined in the solution notebook"',
            '  else'
        ].concat(bindings).concat(body).concat([
            '  end'
        ]).concat(jsonOrNull('ck_val', 'ck_val_json'))
            .concat(jsonOrNull('ck_err', 'ck_err_json'))
            .concat([
                payloadWrite(nonce, [
                    grading.luaStringLiteral('{"value":'),
                    'ck_val_json',
                    grading.luaStringLiteral(',"error":'),
                    'ck_err_json',
                    grading.luaStringLiteral('}')
                ]),
                'end)()'
            ]).join('\n');
    }

    root.ChickadeeLuaEvalShared = {
        LUA_KERNEL: grading.LUA_KERNEL,
        makeNonce: grading.makeNonce,
        bootCell: bootCell,
        loadCell: loadCellLua,
        runExpression: runExpressionLua,
        callFunction: callFunctionLua,
        parseEvalOutput: protocol.parseEvalOutput,
    };
})(typeof self !== 'undefined' ? self : globalThis);
