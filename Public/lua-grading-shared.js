// Public/lua-grading-shared.js
//
// Grading semantics for the Lua browser grader — the Lua sibling of
// Public/r-grading-shared.js and Public/python-grading-shared.js.  Everything
// here defines WHAT Lua runs for one test script and HOW the kernel's reply is
// turned back into a raw ScriptOutput (exit code + stdout + stderr).  RunnerCore
// (Swift/wasm) still owns the interpretation into a TestOutcome, exactly as for
// the other two, so the native and browser graders cannot drift.
//
// Loading: classic script, no dependencies.
//   - Public/lua-grading-worker.js: importScripts('/lua-grading-shared.js' + search)
//   - Node tests: read + eval, then read globalThis.ChickadeeLuaGradingShared.
// Exposes exactly one global: ChickadeeLuaGradingShared.
//
//
// Why a wrapper at all
// --------------------
// The native runner grades a Lua test by spawning `lua publictest_foo.lua`.
// The script's contract is a PROCESS contract: `passed()` / `failed()` /
// `errored()` in test_runtime.lua call `os.exit(N)`, the label comes from
// `arg[0]`, the seed from `os.getenv`, and stdout/stderr are two pipes.  A
// xeus-lua kernel has none of that — one long-lived Lua state, no argv, no
// environment to set, and output arriving as Jupyter `stream` messages.  So the
// wrapper re-creates the process contract inside that one state:
//
//   * `os.exit` is replaced with a function that raises a table carrying the
//     status.  test_runtime.lua resolves `os.exit` at call time through the
//     shared `os` table, so the replacement is what its helpers reach — no edit
//     to test_runtime.lua is needed and the canonical copy stays byte-identical
//     across both runners.
//   * `arg` is set to `{ [0] = <script> }` before each script, so `t.label()`
//     answers what it would under `lua`.
//   * `os.getenv` is wrapped with an overlay table, standing in for the
//     environment the native runner exports `CHICKADEE_ASSIGNMENT_SEED` into.
//   * every global the previous script defined is removed, and `package.loaded`
//     is rolled back to its boot state, standing in for the fresh process the
//     native runner gets per test.  (`_G` itself is NOT cleared — that would
//     take `print`, `io` and `os` with it.  Only names added since boot go.)
//
// stdout is NOT captured and replayed the way the R wrapper captures it.  It
// does not need to be: the script's output goes to the kernel's stdout stream
// in order, and the wrapper writes one nonce-delimited status line AFTER the
// script finishes.  Everything before that line is the script's stdout, so a
// single split recovers both.  Student code cannot forge the boundary because
// it cannot see the nonce.
//
// stderr is read off the kernel's stderr stream, as in R: the wrapper writes an
// uncaught error's message and traceback there itself, which is what `lua`
// does with the same error, and is where `longResult` comes from.
//
//
// What did NOT carry over from R, measured
// ----------------------------------------
// The R wrapper is squeezed into ONE top-level expression because xeus-r yields
// to the JS event loop between top-level expressions and does not come back for
// ~180ms.  That is an xeus-r property, not an xeus-lite one, and Lua does not
// share it: measured on this vendored kernel, a cell of 20 top-level `print`
// statements costs 5ms and a cell summing 20 million integers costs 184ms —
// i.e. wall time tracks the work, which is exactly what the R measurements
// showed was NOT happening there.
//
// The wrapper is nonetheless a single call expression, for an unrelated reason
// that IS an xeus-lua property: the kernel first tries to compile a cell as
// `return <cell>` so it can report a value, and only falls back to running it
// as a plain block.  A cell that begins with a `local` declaration and then
// uses it compiles under neither reading cleanly — the fallback reports the
// name as an undefined GLOBAL.  Sending one call expression sidesteps the
// question entirely; the wrapper's own statements live inside the function it
// installed at boot, which the kernel never re-parses.

(function (root) {
    'use strict';

    // The vendored kernel the Lua grader boots.  These mirror the entries
    // JupyterLite would read out of Public/jupyterlite/xeus/kernels.json and
    // chickadee-lua/xlua/kernel.json.
    const LUA_KERNEL = {
        envName: 'chickadee-lua',
        kernelName: 'xlua',
        // No CPython runtime to bring up after the env unpacks (that is
        // xeus-python's step alone).  Note the env DOES contain a `python`
        // package — it arrives transitively via jupyterlab_widgets — but the
        // Lua kernel never executes it.
        needsPythonRuntime: false,
        // xlua/kernel.json carries no `metadata.shared` block: the kernel links
        // only libxeus, which jupyterlite-xeus places at the env root, and
        // xeus-kernel-shared.js resolves that name there without a map entry.
        // Kept as an explicit empty object rather than omitted so the
        // `hasOwnProperty` lookup in locateFile has something to ask.
        sharedLibs: {},
        // argv, as the kernel.json spells it — xeus 6 requires it be passed.
        argv: ['xeus/chickadee-lua/bin/xlua.js', '-f', '{connection_file}'],
    };

    // NOTE ON `bootSeeds`, which the other two kernels have and this one does
    // not: booting a subset is worth doing when most of an env is optional
    // (Python boots 22 MB of 62; R boots base R and installs the tidyverse on
    // demand).  Every package in this env is in the transitive closure of
    // `xeus-lua` itself, so a seed list would select all ten and save nothing.
    // The whole env is ~19 MB on disk, against 74 MB for R and 85 MB for
    // Python.

    // Escape a JS string for embedding in Lua source as a double-quoted
    // literal.  Only used for names Chickadee itself controls (script names,
    // the seed, the nonce), but escaping keeps a surprising filename from
    // breaking the wrapper's parse.
    function luaStringLiteral(value) {
        return '"' + String(value)
            .replace(/\\/g, '\\\\')
            .replace(/"/g, '\\"')
            .replace(/\n/g, '\\n')
            .replace(/\r/g, '\\r')
            .replace(/\t/g, '\\t') + '"';
    }

    // The one-time cell that installs the harness into the kernel's Lua state.
    // Run once at init, before any script; `runScriptLua` below is then a single
    // call into what this leaves behind.
    //
    // Everything the wrapper needs later hangs off the global `_ck`, which is
    // added to the boot snapshot explicitly so the per-script wipe does not
    // delete the thing doing the wiping.
    const SETUP_LUA = `(function()
  local G = _G
  local base = {}
  for k in pairs(G) do base[k] = true end
  local loaded = {}
  for k in pairs(package.loaded) do loaded[k] = true end

  local real_getenv = os.getenv
  local overlay = {}
  local ck = { env = overlay }
  G._ck = ck
  base["_ck"] = true
  base["arg"] = true

  -- \`lua script.lua\` resolves require() against the working directory; the
  -- kernel's package.path points only at its own asset dir, so a test script's
  -- \`require("test_runtime")\` would fail here and nowhere else.
  package.path = "./?.lua;./?/init.lua;" .. package.path

  -- The process contract, re-created. os.exit raises instead of exiting,
  -- because there is no process to end and a real exit would take the kernel
  -- with it; the status rides on the raised table. Level 0 keeps Lua from
  -- prefixing a source position onto a value that is not a message.
  os.exit = function(code)
    error({ __chickadee_exit = true, status = code }, 0)
  end
  os.getenv = function(name)
    local value = overlay[name]
    if value ~= nil then return value end
    return real_getenv(name)
  end

  ck.setenv = function(name, value) overlay[name] = value end

  -- os.exit accepts a number, a boolean, or nothing; \`lua\` maps true and
  -- nothing to 0 and false to 1. Anything else is a script bug, and exit 1 is
  -- what the native runner would report for it.
  local function exit_status(code)
    if code == nil or code == true then return 0 end
    if code == false then return 1 end
    local n = math.tointeger(code)
    if n == nil then return 1 end
    return n
  end

  ck.run = function(name, nonce)
    for k in pairs(G) do
      if not base[k] then G[k] = nil end
    end
    for k in pairs(package.loaded) do
      if not loaded[k] then package.loaded[k] = nil end
    end
    G.arg = { [0] = name }

    local status = 0
    local ok, failure = xpcall(function() return dofile(name) end, function(e)
      if type(e) == "table" and e.__chickadee_exit then return e end
      return { message = tostring(e), traceback = debug.traceback("", 2) }
    end)
    if not ok then
      if failure.__chickadee_exit then
        status = exit_status(failure.status)
      else
        -- What \`lua\` writes to stderr for an uncaught error, in the same
        -- shape, so longResult reads identically under either runner.
        status = 1
        io.stderr:write("lua: " .. failure.message .. "\\n")
        io.stderr:write(failure.traceback .. "\\n")
      end
    end

    -- The status line, last and nonce-delimited. Everything the kernel
    -- published on stdout before it is the script's own output.
    io.write("\\n" .. nonce .. ":status:" .. status .. "\\n")
    return status
  end

  return true
end)()`;

    // Set CHICKADEE_ASSIGNMENT_SEED for the whole session, mirroring the native
    // runner exporting it into the test subprocess's environment (and R's
    // `Sys.setenv`).  Lua has no way to write its own environment, hence the
    // overlay `os.getenv` consults.
    function assignmentSeedLua(seed) {
        return '_ck.setenv("CHICKADEE_ASSIGNMENT_SEED", ' + luaStringLiteral(seed) + ')';
    }

    // A fresh, unguessable delimiter for one script run.  The wrapper writes it
    // around the status the grader reads back; student code cannot forge a
    // boundary because it cannot see the nonce.  crypto.getRandomValues is
    // available in every browser worker; Math.random is a test-harness fallback
    // only.
    function makeNonce() {
        try {
            const bytes = new Uint8Array(16);
            (root.crypto || globalThis.crypto).getRandomValues(bytes);
            return Array.from(bytes).map(b => b.toString(16).padStart(2, '0')).join('');
        } catch (_) {
            let out = '';
            for (let i = 0; i < 4; i++) out += Math.random().toString(16).slice(2, 10);
            return out;
        }
    }

    // The Lua source for grading ONE script: a single call into the harness
    // SETUP_LUA installed.  See the header for why it is one expression.
    function runScriptLua(scriptName, nonce) {
        return '_ck.run(' + luaStringLiteral(scriptName) + ', '
            + luaStringLiteral(nonce) + ')';
    }

    // Pull the status and the script's stdout back out of the kernel's
    // concatenated stdout stream.
    //
    // Anchored on the LAST occurrence of the marker, so a submission that echoes
    // an earlier line cannot shadow the real one.  Returns null when the run
    // never reached the status line — the caller turns that into a substrate
    // error rather than guessing at an exit code, since a missing status means
    // the cell died before it could report anything.
    function parseRunOutput(stdoutText, nonce) {
        const text = String(stdoutText == null ? '' : stdoutText);
        const statusMark = '\n' + nonce + ':status:';

        const statusAt = text.lastIndexOf(statusMark);
        if (statusAt < 0) return null;
        const statusFrom = statusAt + statusMark.length;
        const statusEnd = text.indexOf('\n', statusFrom);
        if (statusEnd < 0) return null;
        const exitCode = parseInt(text.slice(statusFrom, statusEnd).trim(), 10);
        if (!Number.isFinite(exitCode)) return null;

        // The marker's own leading newline is not the script's, so the slice
        // ends before it: a script whose last write had no trailing newline
        // must not gain one.
        return { exitCode: exitCode, stdout: text.slice(0, statusAt) };
    }

    root.ChickadeeLuaGradingShared = {
        LUA_KERNEL: LUA_KERNEL,
        SETUP_LUA: SETUP_LUA,
        luaStringLiteral: luaStringLiteral,
        assignmentSeedLua: assignmentSeedLua,
        makeNonce: makeNonce,
        runScriptLua: runScriptLua,
        parseRunOutput: parseRunOutput,
    };
})(typeof self !== 'undefined' ? self : globalThis);
