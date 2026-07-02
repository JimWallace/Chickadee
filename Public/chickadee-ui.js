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

    // ── Status line ──
    //
    // The one status-line setter (#1126 — this existed as six drifted
    // copies).  Sets the element's text and palette colour by kind:
    // 'error' → red, 'ok'/'success' → green, anything else → gray.
    function setStatus(el, text, kind) {
        if (!el) return;
        el.textContent = text || '';
        el.style.color = kind === 'error'
            ? 'var(--red)'
            : (kind === 'ok' || kind === 'success') ? 'var(--green)' : 'var(--gray-500)';
    }

    // ── Fetch error handling ──
    //
    // One error-message extractor for failed fetch bodies (#1126 — two
    // divergent copies used to flow through the same renderer ctx slot:
    // one parsed JSON, the other scraped the Leaf error page).  Order:
    // JSON `{reason|error|message}` (the API endpoints), then the error
    // page's `<p class="error-message">`, else the (truncated) raw text.
    function extractErrorMessage(text) {
        if (!text) return '';
        try {
            var j = JSON.parse(text);
            return j.reason || j.error || j.message || text;
        } catch (e) { /* not JSON — fall through to the HTML scrape */ }
        var m = text.match(/class="error-message"[^>]*>([\s\S]*?)<\/p>/);
        if (m) {
            return m[1].replace(/<[^>]+>/g, '')
                .replace(/&#39;/g, "'").replace(/&quot;/g, '"')
                .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
                .trim();
        }
        return text.length > 200 ? text.substring(0, 200) + '…' : text;
    }

    // JSON fetch wrapper: sets the CSRF header, JSON-encodes `opts.body`
    // (when present), and on a non-ok response rejects with an Error carrying
    // the extracted server message — the `if (!r.ok) return r.text()...`
    // boilerplate that repeated across the editors (#1126).  Resolves with
    // the parsed JSON body (null for 204 / non-JSON responses).
    function fetchJSON(url, opts) {
        opts = opts || {};
        var headers = {};
        Object.keys(opts.headers || {}).forEach(function (k) { headers[k] = opts.headers[k]; });
        if (opts.body !== undefined) headers['Content-Type'] = 'application/json';
        var token = opts.csrfToken || getCsrfToken();
        if (token) headers['x-csrf-token'] = token;
        return fetch(url, {
            method: opts.method || 'GET',
            headers: headers,
            body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined
        }).then(function (r) {
            if (!r.ok && r.status !== 204) {
                return r.text().then(function (t) {
                    throw new Error(extractErrorMessage(t) || ('HTTP ' + r.status));
                });
            }
            if (r.status === 204) return null;
            return r.json().catch(function () { return null; });
        });
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

    // ── Shared accordion (inline detail-row editor) ──────────────────────────
    //
    // Both the suite editor (suite-table.js) and the achievements editor
    // (achievements-editor.js) expand an inline editor in a detail <tr> beneath
    // the row being edited.  This is the one implementation of that pattern so
    // the two editors animate and tear down identically.
    //
    //   build({colspan})  -> { tr, host, saveBtn, cancelBtn, status, anim }
    //                        the detail-row skeleton, NOT yet inserted.  The
    //                        caller inserts parts.tr wherever it belongs (the
    //                        two editors have different placement rules) and
    //                        mounts its editor into parts.host.
    //   open(parts, row)  -> animates the inserted row open (0fr -> 1fr) and
    //                        marks `row` (the parent) expanded; scrolls it into
    //                        view.  Pass row=null when appending a brand-new row.
    //   close(tr, opts)   -> animates the row closed and removes it; returns a
    //                        finishNow() that completes it synchronously (used
    //                        when a new editor must open before the old one's
    //                        animation finishes).  opts.immediate (or the user's
    //                        reduced-motion setting) tears down synchronously.
    //                        opts.onDone runs once, just before removal, while
    //                        content is still mounted — for editor-specific
    //                        cleanup (e.g. rescuing a singleton editor body).
    //
    // The height animation is the single-row grid `grid-template-rows: 0fr->1fr`
    // technique (see styles.css): it animates the editor's intrinsic height with
    // no magic max-height, which matters because the family editor's height
    // varies a lot.
    var CARET_HTML = '<span class="accordion-caret" aria-hidden="true">'
        + '<svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" '
        + 'viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" '
        + 'stroke-linecap="round" stroke-linejoin="round"><polyline points="9 18 15 12 9 6"/>'
        + '</svg></span>';

    function prefersReducedMotion() {
        return !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);
    }

    function buildAccordionRow(opts) {
        opts = opts || {};
        var tr = document.createElement('tr');
        tr.className = 'suite-detail-row';
        var td = document.createElement('td');
        td.setAttribute('colspan', String(opts.colspan || 4));
        var anim = document.createElement('div');
        anim.className = 'suite-detail-anim';
        var inner = document.createElement('div');
        inner.className = 'suite-detail-inner';
        var host = document.createElement('div');
        host.className = 'suite-detail-host';
        var actions = document.createElement('div');
        actions.className = 'suite-detail-actions';
        var saveBtn = document.createElement('button');
        saveBtn.type = 'button';
        saveBtn.className = 'btn btn-primary btn-compact';
        saveBtn.textContent = 'Save';
        var cancelBtn = document.createElement('button');
        cancelBtn.type = 'button';
        cancelBtn.className = 'btn btn-compact';
        cancelBtn.textContent = 'Cancel';
        var status = document.createElement('span');
        status.className = 'suite-detail-status card-meta';
        actions.appendChild(saveBtn);
        actions.appendChild(cancelBtn);
        actions.appendChild(status);
        inner.appendChild(host);
        inner.appendChild(actions);
        anim.appendChild(inner);
        td.appendChild(anim);
        tr.appendChild(td);
        return {
            tr: tr, host: host, saveBtn: saveBtn,
            cancelBtn: cancelBtn, status: status, anim: anim, inner: inner
        };
    }

    function openAccordionRow(parts, parentRow) {
        if (parentRow) parentRow.classList.add('suite-row-expanded');
        var anim = parts.anim;
        var inner = parts.inner;
        // The inner clips while the row is partly open (the CSS default).  Once
        // fully open, reveal overflow so editor popovers/tooltips aren't clipped.
        function reveal() { if (inner) inner.style.overflow = 'visible'; }
        if (prefersReducedMotion() || !anim) {
            if (anim) anim.classList.add('is-open');
            reveal();
        } else {
            // Double rAF: let the 0fr starting state paint before flipping to
            // 1fr, so the grid-template-rows transition actually runs (a single
            // frame is not reliable across engines).
            requestAnimationFrame(function () {
                requestAnimationFrame(function () { anim.classList.add('is-open'); });
            });
            var revealed = false;
            anim.addEventListener('transitionend', function (e) {
                if (e.propertyName === 'grid-template-rows' && !revealed) { revealed = true; reveal(); }
            });
            // Fallback if transitionend never fires (e.g. tab backgrounded).
            setTimeout(function () { if (!revealed) { revealed = true; reveal(); } }, 280);
        }
        if (parts.tr && parts.tr.scrollIntoView) parts.tr.scrollIntoView({ block: 'nearest' });
        return parts;
    }

    function closeAccordionRow(tr, opts) {
        opts = opts || {};
        var parentRow = opts.parentRow || null;
        var done = false;
        function finish() {
            if (done) return;
            done = true;
            if (opts.onDone) { try { opts.onDone(); } catch (e) { /* ignore */ } }
            if (tr && tr.parentNode) tr.parentNode.removeChild(tr);
            if (parentRow) parentRow.classList.remove('suite-row-expanded');
        }
        var anim = tr ? tr.querySelector('.suite-detail-anim') : null;
        if (opts.immediate || prefersReducedMotion() || !anim || !tr || !tr.parentNode) {
            finish();
            return finish;
        }
        // Re-clip before collapsing (open() set overflow:visible once expanded),
        // so content is clipped as the row shrinks rather than spilling out.
        var inner = tr.querySelector('.suite-detail-inner');
        if (inner) inner.style.overflow = 'hidden';
        anim.addEventListener('transitionend', function (e) {
            if (e.propertyName === 'grid-template-rows') finish();
        });
        // Fallback if transitionend never fires (e.g. a display:none ancestor).
        setTimeout(finish, 320);
        anim.classList.remove('is-open');
        return finish;
    }

    var root = typeof window !== 'undefined' ? window : globalThis;
    root.ChickadeeUI = {
        escapeHtml: escapeHtml,
        escapeAttr: escapeHtml,
        getCsrfToken: getCsrfToken,
        setStatus: setStatus,
        extractErrorMessage: extractErrorMessage,
        fetchJSON: fetchJSON,
        renderSparkline: renderSparkline,
        accordion: {
            CARET_HTML: CARET_HTML,
            build: buildAccordionRow,
            open: openAccordionRow,
            close: closeAccordionRow
        }
    };

    // Node export for the .mjs unit tests (Tests/BrowserRunnerJSTests);
    // browsers take the `root.ChickadeeUI` global above.
    if (typeof module === 'object' && module.exports) {
        module.exports = root.ChickadeeUI;
    }
}());
