// Public/sparkline.js
//
// The one sparkline renderer: a row of bars, one per series entry, for the
// dashboard diagnostic cards.
//
// Split out of chickadee-ui.js, which had accumulated eighteen unrelated
// functions behind one name — escaping, CSRF, fetch, a status line, a modal, a
// chart renderer, an accordion, two surface swappers. Rendering a chart is not
// a "shared utility" in the same sense as escaping a string, and keeping it in
// there meant the module every page loads carried markup-building code most
// pages never call.
//
//   ChickadeeSparkline.render(container, series, labels, formatPoint, opts)
//
// `series` is numbers and nulls, where null means "no data" and draws as an
// empty slot; `labels[i]` prefixes bar i's tooltip and `formatPoint(value)`
// formats the value in it. Two options exist because the admin Active Users
// card used to carry its own fork of this markup rather than these flags:
//
//   opts.floorPct     floor the height of any populated (> 0) bucket, so a
//                     lone entry shows a visible bar rather than a sliver
//                     indistinguishable from an empty slot
//   opts.zeroIsEmpty  draw a zero-valued bucket with the empty-slot styling,
//                     not only a null one
//
// The bar height rides the `--bar-h` custom property. That is the one inline
// custom property a template or a renderer may set (scripts/check-styles.sh
// 4c): it varies per DATUM — it comes from the row being drawn — rather than
// being a per-page dial for a design decision.
(function (global) {
    'use strict';

    // The escape lives HERE rather than being borrowed from ChickadeeUI, for
    // two reasons that turned out to be the same reason.
    //
    // This file builds a markup string and assigns it to `innerHTML`, so it is
    // an HTML sink and it must own its own sanitizer: reaching for the escape
    // through a global makes the safety of this file depend on another file
    // having loaded, and the first draft of this extraction proved the point by
    // falling back to a NON-escaping `String(...)` when that global was absent.
    // CodeQL caught exactly that, and it was right — a scanner cannot follow a
    // sanitizer through a global property either, so the barrier has to be in
    // the file with the sink for a reader and a scanner alike to see it.
    //
    // The cost is a second copy of a function the June 2026 audit deduplicated,
    // and the drift that copy invites is what `sparkline.test.mjs` pins: it
    // asserts this agrees with `ChickadeeUI.escapeHtml` character for character.
    function escape(text) {
        return String(text == null ? '' : text)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
            .replace(/'/g, '&#39;');
    }

    function render(container, series, labels, formatPoint, opts) {
        if (!container) return;
        series = Array.isArray(series) ? series : [];
        labels = Array.isArray(labels) ? labels : [];
        opts = opts || {};
        var format = typeof formatPoint === 'function' ? formatPoint : function (v) { return String(v); };
        var max = series.reduce(function (m, v) { return v == null ? m : Math.max(m, v); }, 0);
        container.innerHTML = series.map(function (value, i) {
            var pct = (value != null && max > 0) ? (value / max) * 100 : 0;
            if (opts.floorPct > 0 && value > 0 && pct > 0) pct = Math.max(pct, opts.floorPct);
            var empty = value == null || (opts.zeroIsEmpty && !value);
            var title = (labels[i] || '') + ': ' + (value == null ? 'no data' : format(value));
            return '<div class="spark-slot" title="' + escape(title) + '">'
                + '<span class="spark-fill' + (empty ? ' spark-fill-empty' : '')
                + '" style="--bar-h:' + pct.toFixed(1) + '%"></span>'
                + '</div>';
        }).join('');
    }

    global.ChickadeeSparkline = { render: render };

    // Node export for the .mjs unit tests (Tests/BrowserRunnerJSTests);
    // browsers take the global above.
    if (typeof module === 'object' && module.exports) {
        module.exports = global.ChickadeeSparkline;
    }
})(typeof self !== 'undefined' ? self : this);
