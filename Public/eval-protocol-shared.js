// Public/eval-protocol-shared.js
//
// How an auto-compute snippet reports its result back out of a xeus kernel,
// independent of which language the snippet is written in.
//
// WHY THIS IS ITS OWN MODULE. A Jupyter `execute_request` returns nothing — it
// publishes messages — so a snippet's value cannot be read off a return value
// the way `runPythonAsync` allowed. It is printed behind a per-run nonce and
// parsed back out of stdout. The nonce is what stops an instructor's own
// solution output from forging the boundary by printing something payload-
// shaped.
//
// The FRAMING is language-neutral, so it lives here rather than in any one
// language's module. It started inside `python-eval-shared.js`, which was right
// while Python was the only in-page evaluator and became an odd dependency the
// moment an R worker needed the same parser.
//
// Reading `execute_result` off the iopub stream would look simpler and is
// worse: it couples the contract to display formatting (`repr` truncation,
// `ast_node_interactivity`), which is a worse thing to depend on than a
// delimiter we control.
//
// Loading: classic script (importScripts).
// Exposes exactly one global: ChickadeeEvalProtocol.

(function (root) {
    'use strict';

    /// The payload a snippet printed behind `nonce`, or null when it never
    /// reported — a kernel that died mid-run, or output the nonce never
    /// reached. Callers treat null as a substrate failure rather than a result.
    ///
    /// `lastIndexOf` because the instructor's own solution may legitimately
    /// print before the payload; the last marker is ours.
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

    /// The marker a snippet must print immediately before its JSON payload.
    /// Exposed so a language's snippet builder cannot spell it differently from
    /// the parser that reads it.
    function payloadMarker(nonce) {
        return '\n' + nonce + ':';
    }

    root.ChickadeeEvalProtocol = {
        parseEvalOutput: parseEvalOutput,
        payloadMarker: payloadMarker,
    };
})(typeof self !== 'undefined' ? self : globalThis);
