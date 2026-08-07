// Public/octave-grading-shared.js
//
// Grading semantics for the Octave browser grader — the Octave sibling of
// Public/r-grading-shared.js and Public/lua-grading-shared.js.  Everything
// here defines WHAT Octave runs for one test script and HOW the kernel's reply
// is turned back into a raw ScriptOutput (exit code + stdout + stderr).
// RunnerCore (Swift/wasm) still owns the interpretation into a TestOutcome,
// exactly as for the other three, so the native and browser graders cannot
// drift.
//
// Loading: classic script, no dependencies.
//   - Public/octave-grading-worker.js: importScripts('/octave-grading-shared.js' + search)
//   - Node tests: read + eval, then read globalThis.ChickadeeOctaveGradingShared.
// Exposes exactly one global: ChickadeeOctaveGradingShared.
//
//
// Why a wrapper at all
// --------------------
// The native runner grades an Octave test by spawning `octave-cli
// publictest_foo.m`.  The script's contract is a PROCESS contract:
// `chickadee.passed()` / `failed()` / `errored()` in test_runtime.m call
// `exit(N)`, the label comes from `program_name()`, the seed from `getenv`,
// and stdout/stderr are two pipes.  A xeus-octave kernel has none of that —
// one long-lived interpreter, no process to exit, and output arriving as
// Jupyter `stream` messages.  So the wrapper re-creates the process contract
// inside that one session:
//
//   * `exit` and `quit` are masked with command-line functions that raise an
//     error whose IDENTIFIER is `chickadee:exit` and whose message carries the
//     status.  test_runtime.m resolves both by NAME at call time, so the masks
//     are what its helpers reach — no edit to test_runtime.m is needed and the
//     canonical copy stays byte-identical across both runners.  (Third kernel,
//     third exit mask: R's quit(), Lua's os.exit, now this.  If it regresses,
//     every test reads as a pass — the smoke test is the only thing that can
//     see it.)  Notably a BARE unmasked exit does not kill this kernel (it
//     raises "exit exception" internally, ~5 s later) — masking is still
//     required because that path yields no usable status.
//   * `program_name` is masked to report the script being graded, so
//     `chickadee.label()` answers what it would under octave-cli.
//   * the seed is delivered with a plain `setenv`, which works in this kernel
//     (unlike Lua, whose os.getenv needed an overlay).
//
// stdout is NOT captured and replayed the way the R wrapper does.  It does not
// need to be: the script's output goes to the kernel's stdout stream in order,
// and the wrapper writes one nonce-delimited status line AFTER the script
// finishes.  Everything before that line is the script's stdout, so a single
// split recovers both (the Lua scheme).  Student code cannot forge the
// boundary because it cannot see the nonce.
//
// stderr is read off the kernel's stderr stream: `fprintf(2, ...)` reaches it
// directly (measured — no R-style calling-handler trap), and the wrapper
// writes an uncaught error's message there itself in the same `error: ...`
// shape octave-cli produces, which is where `longResult` comes from.
//
//
// What did NOT carry over from R or Lua, measured
// -----------------------------------------------
// No per-statement cost: 20 top-level statements cost 1 ms in this kernel and
// wall time tracks the work (xeus-r's ~180 ms-per-expression yield is an
// xeus-r property).  And no cell-compilation quirk like xeus-lua's
// `return <cell>` fallback.  The wrapper still drives each script through ONE
// call expression (`__ck_run(...)`) — not to dodge either quirk, but because
// the harness function's own workspace is what isolates one script's
// variables from the next, standing in for the fresh process the native
// runner gives each test.

(function (root) {
    'use strict';

    // The vendored kernel the Octave grader boots.  These mirror the entries
    // JupyterLite reads out of Public/jupyterlite/xeus/kernels.json and
    // chickadee-octave/xoctave/kernel.json — the same env the notebook EDITOR
    // runs for Octave notebooks, so there is no editor/grader package skew.
    const OCTAVE_KERNEL = {
        envName: 'chickadee-octave',
        kernelName: 'xoctave',
        // No CPython runtime to bring up after the env unpacks.  The env DOES
        // contain a `python` payload — plotly, the kernel's notebook graphics
        // toolkit, is a Python package — but the kernel never executes it
        // (same situation as chickadee-lua's transitive `python`).
        needsPythonRuntime: false,
        // Shared libraries the kernel dlopen()s — the `metadata.shared` block
        // of xoctave/kernel.json, resolved by xeus-kernel-shared's locateFile
        // to the copies jupyterlite-xeus places beside the kernelspec.
        sharedLibs: {
            'libxeus.so': 'lib/libxeus.so',
            'liboctinterp.so': 'lib/octave/10.3.0/liboctinterp.so',
            'liboctave.so': 'lib/octave/10.3.0/liboctave.so',
            'libz.so': 'lib/libz.so',
        },
        // argv, as the kernel.json spells it — xeus 6 requires it be passed.
        argv: ['xeus/chickadee-octave/bin/xoctave.js', '-f', '{connection_file}'],
    };

    // NOTE ON `bootSeeds`, absent here as for Lua: every package in this env
    // is in xeus-octave's own transitive closure (plotly drags in the Python
    // payload), so a seed list would select all eleven and save nothing.

    // Escape a JS string for embedding in Octave source as a double-quoted
    // literal.  Only used for names Chickadee itself controls (script names,
    // the seed, the nonce), but escaping keeps a surprising filename from
    // breaking the wrapper's parse.
    function octaveStringLiteral(value) {
        return '"' + String(value)
            .replace(/\\/g, '\\\\')
            .replace(/"/g, '\\"')
            .replace(/\n/g, '\\n')
            .replace(/\r/g, '\\r')
            .replace(/\t/g, '\\t') + '"';
    }

    // The one-time cell that installs the harness into the kernel's session.
    // Run once at init, before any script; `runScriptOctave` below is then a
    // single call into what this leaves behind.
    //
    // The leading `1;` makes the cell a script so the `function` definitions
    // register as command-line functions — which is also what lets them shadow
    // the built-in `exit`, `quit` and `program_name` (verified in a real
    // kernel: a command-line function wins the lookup and `clear <name>`
    // would unmask it).
    //
    // The status rides on an error whose IDENTIFIER is `chickadee:exit`; the
    // message is just the number.  Identifiers survive try/catch verbatim and
    // cannot collide with a student's `error("some text")`, whose identifier
    // is empty.
    const SETUP_OCTAVE = [
        '1;',
        'global __ck_script_name;',
        '__ck_script_name = "";',
        'function exit(code)',
        '  if nargin < 1',
        '    code = 0;',
        '  end',
        '  error("chickadee:exit", "%d", code);',
        'end',
        'function quit(varargin)',
        '  if nargin < 1',
        '    exit(0);',
        '  else',
        '    exit(varargin{1});',
        '  end',
        'end',
        'function name = program_name()',
        '  global __ck_script_name;',
        '  name = __ck_script_name;',
        'end',
        'function __ck_run(script_name, nonce)',
        '  global __ck_script_name;',
        '  __ck_script_name = script_name;',
        // The fresh-process stand-in. This function's own workspace already
        // isolates one script's ordinary variables from the next (source()
        // writes them here, and they die with the call) — the piece that needs
        // help is `global`, which outlives the call. Clear every global except
        // the harness's own state, keyed on name rather than a boot snapshot
        // because the harness owns exactly one.
        '  __ck_globals = who("global");',
        '  for __ck_i = 1:numel(__ck_globals)',
        '    if !strcmp(__ck_globals{__ck_i}, "__ck_script_name")',
        '      clear("-global", __ck_globals{__ck_i});',
        '    end',
        '  end',
        '  status = 0;',
        '  try',
        '    source(script_name);',
        '  catch err',
        '    if strcmp(err.identifier, "chickadee:exit")',
        '      status = str2double(err.message);',
        '      if isnan(status)',
        '        status = 1;',
        '      end',
        '    else',
        // What octave-cli writes to stderr for an uncaught error, in the same
        // shape, so longResult reads identically under either runner.
        '      status = 1;',
        '      fprintf(2, "error: %s\\n", err.message);',
        '    end',
        '  end',
        // The status line, last and nonce-delimited. Everything the kernel
        // published on stdout before it is the script's own output.
        '  printf("\\n%s:status:%d\\n", nonce, status);',
        'end',
    ].join('\n');

    // Set CHICKADEE_ASSIGNMENT_SEED for the whole session, mirroring the
    // native runner exporting it into the test subprocess's environment.
    function assignmentSeedOctave(seed) {
        return 'setenv("CHICKADEE_ASSIGNMENT_SEED", ' + octaveStringLiteral(seed) + ');';
    }

    // A fresh, unguessable delimiter for one script run.  crypto.getRandomValues
    // is available in every browser worker; Math.random is a test-harness
    // fallback only.
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

    // The Octave source for grading ONE script: a single call into the harness
    // SETUP_OCTAVE installed.  See the header for why it is one call.
    function runScriptOctave(scriptName, nonce) {
        return '__ck_run(' + octaveStringLiteral(scriptName) + ', '
            + octaveStringLiteral(nonce) + ');';
    }

    // Pull the status and the script's stdout back out of the kernel's
    // concatenated stdout stream.
    //
    // Anchored on the LAST occurrence of the marker, so a submission that
    // echoes an earlier line cannot shadow the real one.  Returns null when
    // the run never reached the status line — the caller turns that into a
    // substrate error rather than guessing at an exit code.
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

    // The Octave sibling of personalizationInputsSource / ...SourceR /
    // ...SourceLua: byte-for-byte what `AssignmentLanguage.renderInputsFile`
    // writes for `.octave` on the server, so the browser and the native worker
    // deliver the same file. Pinned by BrowserRunnerSeedLanguageTests, which
    // renders the same inputs through the Swift path and compares.
    //
    // Two parallel cell arrays rather than a struct or Map literal: input
    // names are author-chosen strings and Octave struct fields must be
    // identifiers, so a struct could not hold every legal name.
    // `chickadee.inputs()` evaluates the file's TEXT and zips the two lists.
    function personalizationInputsSourceOctave(personalizedInputs) {
        const header = '% Auto-generated per-student grading inputs (issue #461). Do not edit.';
        const keys = Object.keys(personalizedInputs || {}).sort();
        if (keys.length === 0) {
            return header + '\nck_input_names = {};\nck_input_values = {};\n';
        }
        const names = keys.map(key => octaveStringLiteral(key)).join(', ');
        const values = keys.map(key => personalizedInputs[key]).join(', ');
        return header + '\nck_input_names = { ' + names + ' };\n'
            + 'ck_input_values = { ' + values + ' };\n';
    }

    root.ChickadeeOctaveGradingShared = {
        OCTAVE_KERNEL: OCTAVE_KERNEL,
        SETUP_OCTAVE: SETUP_OCTAVE,
        octaveStringLiteral: octaveStringLiteral,
        assignmentSeedOctave: assignmentSeedOctave,
        makeNonce: makeNonce,
        runScriptOctave: runScriptOctave,
        parseRunOutput: parseRunOutput,
        personalizationInputsSourceOctave: personalizationInputsSourceOctave,
    };
})(typeof self !== 'undefined' ? self : globalThis);
