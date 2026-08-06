// Public/r-grading-shared.js
//
// Grading semantics for the R browser grader — the R analogue of
// Public/grading-shared.js.  Everything here defines WHAT R runs for one test
// script and HOW the kernel's reply is turned back into a raw ScriptOutput
// (exit code + stdout + stderr).  RunnerCore (Swift/wasm) still does the
// interpretation into a TestOutcome, exactly as for Python, so the native and
// browser graders cannot drift.
//
// Loading: classic script, no dependencies.
//   - Public/r-grading-worker.js: importScripts('/r-grading-shared.js' + search)
//   - Node tests: read + eval, then read globalThis.ChickadeeRGradingShared.
// Exposes exactly one global: ChickadeeRGradingShared.
//
//
// Why a wrapper at all
// --------------------
// The native runner grades an R test by spawning `Rscript publictest_foo.R`.
// The script's contract is a process contract: `passed()` / `failed()` /
// `errored()` in test_runtime.R call `quit(status = N)`, the label comes from
// `commandArgs()`'s `--file=` entry, and stdout/stderr are whatever the process
// wrote.  A xeus-r kernel has none of that — there is no process to exit, no
// argv, and output arrives as Jupyter `stream` messages rather than two pipes.
// So the wrapper re-creates the process contract inside one R session:
//
//   * `quit`/`q` are masked in the global environment with a function that
//     signals a `chickadee_exit` condition carrying the status.  test_runtime.R
//     resolves `quit` through its enclosure (the global environment), so the
//     mask is what its helpers call — no edit to test_runtime.R is needed, and
//     the canonical copy stays byte-identical across both runners.
//   * `commandArgs` is masked to report the script being graded, so
//     `.chickadee_label()` and `.chickadee_running_script()` answer the same
//     thing they would under Rscript.
//   * stdout is sunk into a text connection for the duration of the script, then
//     replayed to the kernel around an unguessable nonce, so the script's own
//     output can be told apart from the wrapper's report.
//   * the global environment is wiped first, standing in for the fresh process
//     the native runner gets per test.
//
// stderr is deliberately NOT sunk.  `sink(type = "message")` cannot see it:
// xeus-r evaluates a cell through `evaluate::evaluate()`, which installs CALLING
// HANDLERS for message and warning conditions.  Those fire before the condition
// reaches the stderr connection, so a sink captures nothing and the text is
// published as an iopub `stream`/`stderr` message instead.  The kernel's stderr
// stream therefore already IS the script's stderr — for the whole cell, and
// including anything raised inside `source()` — so the worker reads it from
// there.  (An earlier revision sank it and silently dropped every error message,
// which would have left `longResult` empty on exactly the outcomes a student
// most needs it for.)
//
//
// Why it is ONE top-level expression
// ----------------------------------
// Measured on the vendored `chickadee-r` kernel (xeus-r 0.11.2 / R 4.5.3): a
// cell costs ~540ms plus ~180ms for every TOP-LEVEL expression in it.  20 bare
// statements cost 4065ms; the same 20 inside one `local({ ... })` cost 681ms,
// and inside a `source()`d file 717ms.
//
// That cost is a WAIT, not work, which is worth knowing before anyone tries to
// optimise around it:
//
//   * wall time is independent of the compute.  One expression summing 8
//     million elements costs 559ms; one summing a single element costs 686ms.
//     The bigger job is FASTER.
//   * R's own clock agrees from the inside.  Three expressions nested inside a
//     call report 0ms elapsed between the first and last.  One bare top-level
//     statement reports ~228ms.
//
// So the kernel yields to the JS event loop between top-level expressions and
// does not regain control for ~200ms; whatever R does inside a window is free.
// Nothing here can shorten a window — it is xeus-lite's scheduling, not R's
// speed and not the wasm's — but it can use FEWER of them.  Hence one
// expression.  Keep it that way.
//
// The practical consequence for authors: this is a property of the WRAPPER, not
// of test scripts.  A test script's own top-level statements are evaluated by
// `source()`, inside a single window, and are not charged.

(function (root) {
    'use strict';

    // The vendored kernel the R grader boots.  These mirror the entries
    // JupyterLite would read out of Public/jupyterlite/xeus/kernels.json and
    // chickadee-r/xr/kernel.json — the same env the notebook EDITOR runs for R
    // notebooks, which is the whole reason R has no editor/grader package skew
    // (unlike Python, where the editor is xeus-python and grading is Pyodide).
    const R_KERNEL = {
        envName: 'chickadee-r',
        kernelName: 'xr',
        // xeus-r has no CPython runtime to bring up after the env unpacks;
        // xeus-python does. See xeus-kernel-shared.js.
        needsPythonRuntime: false,
        // The subset booted before any script runs: base R and the kernel, and
        // none of the tidyverse. Add-on packages are installed when a script
        // attaches one.
        //
        // Smaller than Python's share of its env (22.2 MB of 62.1, so 36%) but
        // the same argument: an R lab that only uses base R should not unpack
        // stringi. Note r-stringi (14 MB) is NOT part of the bare kernel — it
        // arrives with stringr/tidyr — so a dplyr-only assignment installs
        // 2.4 MB rather than the whole 22.2 MB tidyverse set.
        bootSeeds: ['xeus-r'],
        // Shared libraries the kernel dlopen()s, mapped to where they sit under
        // the env root — the `metadata.shared` block of xr/kernel.json.
        sharedLibs: {
            'libR.so': 'lib/R/lib/libR.so',
            'libRblas.so': 'lib/R/lib/libRblas.so',
            'libRlapack.so': 'lib/R/lib/libRlapack.so',
            'libxeus.so': 'lib/libxeus.so',
        },
        // argv, as the kernel.json spells it — xeus 6 requires it be passed.
        argv: ['xeus/chickadee-r/bin/xr.js', '-f', '{connection_file}'],
    };

    // Escape a JS string for embedding in R source as a double-quoted literal.
    // Only used for names Chickadee itself controls (script names, the seed,
    // the nonce), but escaping keeps a surprising filename from breaking the
    // wrapper's parse.
    function rStringLiteral(value) {
        return '"' + String(value)
            .replace(/\\/g, '\\\\')
            .replace(/"/g, '\\"')
            .replace(/\n/g, '\\n')
            .replace(/\r/g, '\\r')
            .replace(/\t/g, '\\t') + '"';
    }

    // Set CHICKADEE_ASSIGNMENT_SEED for the whole session, mirroring the native
    // runner exporting it into the test subprocess's environment (and the
    // Python grader's assignmentSeedPython).  test_runtime.R's chickadee_seed()
    // reads it via Sys.getenv.
    function assignmentSeedR(seed) {
        return 'Sys.setenv(CHICKADEE_ASSIGNMENT_SEED = ' + rStringLiteral(seed) + ')';
    }

    // A fresh, unguessable delimiter for one script run.  The wrapper replays
    // the script's captured stdout/stderr to the kernel with this marker around
    // each section; student code cannot forge a section boundary because it
    // cannot see the nonce.  crypto.getRandomValues is available in every
    // browser worker; Math.random is a test-harness fallback only.
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

    // The R source for grading ONE script.  See the header for why this is a
    // single `local({ ... })` and how it re-creates the Rscript contract.
    function runScriptR(scriptName, nonce) {
        const name = rStringLiteral(scriptName);
        const mark = rStringLiteral('\n' + nonce + ':');
        return `local({
  .ck_g <- globalenv()
  rm(list = ls(.ck_g, all.names = TRUE), envir = .ck_g)
  assign("quit", function(save = "default", status = 0L, runLast = TRUE) {
    stop(structure(class = c("chickadee_exit", "error", "condition"),
                   list(message = "chickadee_exit", call = NULL,
                        status = as.integer(status))))
  }, envir = .ck_g)
  assign("q", get("quit", envir = .ck_g), envir = .ck_g)
  assign("commandArgs", function(trailingOnly = FALSE) {
    if (isTRUE(trailingOnly)) character(0) else c("Rscript", paste0("--file=", ${name}))
  }, envir = .ck_g)

  .ck_run <- function() {
    .ck_depth <- sink.number()
    .ck_out_con <- textConnection(".ck_out_txt", "w", local = FALSE)
    on.exit({
      while (sink.number() > .ck_depth) sink()
      try(close(.ck_out_con), silent = TRUE)
    }, add = TRUE)
    sink(.ck_out_con, type = "output")
    tryCatch({
        source(${name}, local = FALSE, echo = FALSE)
        0L
      },
      chickadee_exit = function(cond) cond$status,
      error = function(cond) { message("Error: ", conditionMessage(cond)); 1L })
  }

  .ck_status <- tryCatch(.ck_run(), error = function(cond) {
    message("Error: ", conditionMessage(cond))
    2L
  })
  .ck_out <- if (exists(".ck_out_txt", envir = .ck_g)) get(".ck_out_txt", envir = .ck_g) else character(0)
  cat(${mark}, "status:", .ck_status, "\\n", sep = "")
  cat(paste(.ck_out, collapse = "\\n"))
  cat(${mark}, "end\\n", sep = "")
  invisible(NULL)
})`;
    }

    // Pull the status and the replayed stdout back out of the kernel's
    // concatenated stdout stream.
    //
    // Returns null when the run never reached the replay — the caller turns that
    // into a substrate error rather than guessing at an exit code, since a
    // missing tail means the cell died before it could report anything.
    function parseRunOutput(stdoutText, nonce) {
        const text = String(stdoutText == null ? '' : stdoutText);
        const statusMark = '\n' + nonce + ':status:';
        const endMark = '\n' + nonce + ':end\n';

        const statusAt = text.lastIndexOf(statusMark);
        if (statusAt < 0) return null;
        const statusFrom = statusAt + statusMark.length;
        const statusEnd = text.indexOf('\n', statusFrom);
        if (statusEnd < 0) return null;
        const exitCode = parseInt(text.slice(statusFrom, statusEnd).trim(), 10);
        if (!Number.isFinite(exitCode)) return null;

        const endAt = text.indexOf(endMark, statusEnd);
        if (endAt < 0) return null;

        return { exitCode: exitCode, stdout: text.slice(statusEnd + 1, endAt) };
    }

    // Per-student grading inputs for an R assignment: the R mirror of
    // personalizationInputsSource in browser-runner.js.  Values arrive from the
    // server already rendered as R literals (the seed endpoint resolves them
    // per-language), so only the list wrapper is built here.  MUST stay
    // byte-identical to AssignmentLanguage.renderInputsFile(.r) in
    // Sources/Core/AssignmentLanguage.swift — pinned by
    // Tests/APITests/BrowserRunnerSeedLanguageTests.swift, which renders the
    // same inputs through the Swift path and compares.
    function personalizationInputsSourceR(personalizedInputs) {
        const header = '# Auto-generated per-student grading inputs (issue #461). Do not edit.';
        const keys = Object.keys(personalizedInputs || {}).sort();
        if (keys.length === 0) return header + '\n.ck_inputs <- list()\n';
        const assignments = keys.map(key => '    `' + key + '` = ' + personalizedInputs[key]);
        return header + '\n.ck_inputs <- list(\n' + assignments.join(',\n') + '\n)\n';
    }

    root.ChickadeeRGradingShared = {
        R_KERNEL: R_KERNEL,
        rStringLiteral: rStringLiteral,
        assignmentSeedR: assignmentSeedR,
        makeNonce: makeNonce,
        runScriptR: runScriptR,
        parseRunOutput: parseRunOutput,
        personalizationInputsSourceR: personalizationInputsSourceR,
    };
})(typeof self !== 'undefined' ? self : globalThis);
