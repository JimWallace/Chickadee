// Public/r-eval-shared.js
//
// The snippets the pattern-family editor's auto-compute runs on the xeus-r
// kernel. The R counterpart to python-eval-shared.js; the nonce framing they
// share lives in eval-protocol-shared.js.
//
// Loading: classic script (importScripts). Requires /r-grading-shared.js first
// (kernel spec, `makeNonce`, `rStringLiteral`) and /eval-protocol-shared.js.
// Exposes exactly one global: ChickadeeREvalShared.
//
// TWO R CONSTRAINTS THAT SHAPE EVERY SNIPPET BELOW.
//
// 1. ONE TOP-LEVEL EXPRESSION. xeus-lite yields to the JS event loop between
//    top-level expressions and does not regain control for ~180ms, so a
//    statement list costs multiples of what a single wrapped expression costs
//    (measured in docs/r-support.md: ~3.5s vs ~0.8s for a test script). Every
//    snippet here is therefore ONE `local({...})` call. At auto-compute's
//    debounced, per-keystroke cadence that is the difference between a control
//    that feels live and one that does not.
//
//    It is also why the ESCAPER is not inlined into each snippet: it is defined
//    once at boot, in the global environment, from the source the server seeds
//    (`AssignmentLanguage.autoComputeRuntimeSource`).
//
// 2. VALUES COME BACK AS R's OWN REPR (`deparse`), not as JSON. Deliberate, and
//    it matches what the SERVER driver already returns for R: the client parses
//    it with the same language-aware reader hand-typed values go through, and
//    reports a composite that will not round-trip rather than silently storing
//    the text. Returning JSON here would make the in-page and server paths
//    disagree about what a value looks like.

(function (root) {
    'use strict';

    var grading = root.ChickadeeRGradingShared;
    var protocol = root.ChickadeeEvalProtocol;

    /// `if (is.null(x)) "null" else .ck_json_str(x)` — a JSON value that is
    /// either the escaped R string or a bare null.
    ///
    /// `.ck_json_str` is the SEEDED escaper (defined once at boot), not one
    /// written here. There are three R JSON encoders in this codebase and the
    /// seeded one is the robust char-by-char encoder; a copy in this file would
    /// have been a fourth, and almost certainly the fragile shape.
    function jsonOrNull(rVariable) {
        return 'if (is.null(' + rVariable + ')) "null" else .ck_json_str(' + rVariable + ')';
    }

    /// One `cat(...)` printing the marker, then alternating literal and
    /// computed chunks, then a newline.
    ///
    /// `sep = ""` throughout: `cat`'s default inserts a space between
    /// arguments, which would land inside the JSON and after the marker. The
    /// parser tolerates neither.
    function payloadCat(nonce, chunks) {
        var args = [grading.rStringLiteral(protocol.payloadMarker(nonce))]
            .concat(chunks)
            .concat([grading.rStringLiteral('\n')]);
        return '  cat(' + args.join(', ') + ', sep = "")';
    }

    /// Run one solution-notebook cell, reporting whether it raised.
    ///
    /// Evaluated in `globalenv()` so its definitions are visible to later cells
    /// and to the expression run afterwards — the entire point of loading it.
    ///
    /// Errors are caught rather than propagated for the same reason the Python
    /// path catches them: cells load in order, and an early failure must not
    /// stop later cells from defining their functions. The editor explains a
    /// downstream "function not found" in terms of the earlier cell that
    /// crashed, which it can only do if it got that far.
    function loadCellR(source, nonce) {
        return [
            'local({',
            '  .ck_err <- NULL',
            '  tryCatch(',
            '    eval(parse(text = ' + grading.rStringLiteral(source) + '), envir = globalenv()),',
            '    error = function(e) .ck_err <<- conditionMessage(e)',
            '  )',
            payloadCat(nonce, [
                grading.rStringLiteral('{"error":'),
                jsonOrNull('.ck_err'),
                grading.rStringLiteral('}')
            ]),
            '})'
        ].join('\n');
    }

    /// Evaluate `source` and report its value as R's own repr.
    ///
    /// R needs no equivalent of Python's AST split: `eval(parse(text = …))`
    /// already yields the value of the last expression, which is exactly the
    /// semantics auto-compute wants.
    ///
    /// A NULL result comes back as JSON null rather than the string "NULL", so
    /// the caller can tell "evaluated to nothing" from "evaluated to the value
    /// NULL" — the same distinction the Python path draws for None.
    ///
    /// `deparse` returns a character VECTOR for a long value, so it is
    /// collapsed: the payload is one line by construction.
    function runExpressionR(source, nonce) {
        return [
            'local({',
            '  .ck_err <- NULL',
            '  .ck_val <- NULL',
            '  tryCatch({',
            '    .ck_res <- eval(parse(text = ' + grading.rStringLiteral(source)
                + '), envir = globalenv())',
            '    if (!is.null(.ck_res)) .ck_val <- paste(deparse(.ck_res), collapse = "")',
            '  }, error = function(e) .ck_err <<- conditionMessage(e))',
            payloadCat(nonce, [
                grading.rStringLiteral('{"value":'),
                jsonOrNull('.ck_val'),
                grading.rStringLiteral(',"error":'),
                jsonOrNull('.ck_err'),
                grading.rStringLiteral('}')
            ]),
            '})'
        ].join('\n');
    }

    root.ChickadeeREvalShared = {
        R_KERNEL: grading.R_KERNEL,
        makeNonce: grading.makeNonce,
        loadCell: loadCellR,
        runExpression: runExpressionR,
        parseEvalOutput: protocol.parseEvalOutput,
    };
})(typeof self !== 'undefined' ? self : globalThis);
