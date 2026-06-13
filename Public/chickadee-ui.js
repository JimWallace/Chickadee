// Shared frontend utilities for Chickadee pages (June 2026 audit).
//
// This module replaces the drifted per-file copies of `escapeHtml` /
// `escHtml` / `esc` (which disagreed on character coverage — some skipped
// `"` and/or `'`) and the ~8 duplicated CSRF meta-tag readers.  Always use
// these instead of re-declaring a local implementation:
//
//   ChickadeeUI.escapeHtml(s)   — & < > " ' all escaped (strictest variant)
//   ChickadeeUI.escapeAttr(s)   — alias of escapeHtml (full escaping is
//                                 valid in attribute context too)
//   ChickadeeUI.getCsrfToken()  — reads <meta name="csrf-token">, falling
//                                 back to the hidden _csrf form field
//
// Loaded from the <head> of base.leaf, so it is available to inline page
// scripts and template-loaded modules, which execute during document parse
// — BEFORE the scripts included at the end of <body> (app.js et al).
(function () {
    'use strict';

    function escapeHtml(s) {
        return String(s == null ? '' : s)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
            .replace(/'/g, '&#39;');
    }

    // Returns the CSRF token from the <meta name="csrf-token"> tag in <head>.
    // Used by JS fetch calls to satisfy the CSRF middleware on POST endpoints.
    function getCsrfToken() {
        return document.querySelector('meta[name="csrf-token"]')?.content
            ?? document.querySelector('input[name="_csrf"]')?.value
            ?? '';
    }

    // Renders a sparkline (one bar per series entry) into `container`.
    // `series` is an array of numbers / nulls (null = "no data", drawn as an
    // empty slot). `labels` supplies the per-bar tooltip prefix and
    // `formatPoint(value)` formats the value in the tooltip. Shared by the
    // admin and instructor dashboard diagnostic cards.
    function renderSparkline(container, series, labels, formatPoint) {
        if (!container) return;
        series = Array.isArray(series) ? series : [];
        labels = Array.isArray(labels) ? labels : [];
        var format = typeof formatPoint === 'function' ? formatPoint : function (v) { return String(v); };
        var max = series.reduce(function (m, v) { return v == null ? m : Math.max(m, v); }, 0);
        container.innerHTML = series.map(function (value, i) {
            var pct = (value != null && max > 0) ? (value / max) * 100 : 0;
            var title = (labels[i] || '') + ': ' + (value == null ? 'no data' : format(value));
            return '<div class="spark-slot" title="' + escapeHtml(title) + '">'
                + '<span class="spark-fill' + (value == null ? ' spark-fill-empty' : '')
                + '" style="--bar-h:' + pct.toFixed(1) + '%"></span>'
                + '</div>';
        }).join('');
    }

    window.ChickadeeUI = {
        escapeHtml: escapeHtml,
        escapeAttr: escapeHtml,
        getCsrfToken: getCsrfToken,
        renderSparkline: renderSparkline
    };
}());
