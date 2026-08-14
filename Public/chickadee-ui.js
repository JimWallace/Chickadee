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

    // ── Destructive-action confirmation ──
    //
    // The JS-side entry to the same seam `data-confirm` uses (app.js). A call
    // site that has no element to hang an attribute on — a delete triggered
    // from inside an editor's own click handler — asks here, so replacing the
    // native dialog later is still a one-place change.
    function confirmAction(message) {
        return window.confirm(message);
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
            // Strip tags to a fixpoint so nested fragments ("<scr<script>ipt")
            // can't survive one pass, then decode entities with `&amp;` LAST
            // so "&amp;lt;" decodes to "&lt;" (one level), never to "<".
            // The result is plain text for textContent/alert sinks only.
            var stripped = m[1];
            var prev;
            do {
                prev = stripped;
                stripped = stripped.replace(/<[^>]*>/g, '');
            } while (stripped !== prev);
            return stripped
                .replace(/&#39;/g, "'").replace(/&quot;/g, '"')
                .replace(/&lt;/g, '<').replace(/&gt;/g, '>')
                .replace(/&amp;/g, '&')
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
        + '<svg class="icon" aria-hidden="true"><use href="#i-chevron-right"/></svg></span>';

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

    // Tell the assignment-workbench shell that something on this page changed
    // in a way the *other* pane cares about.
    //
    // The workbench composes the edit page and the notebook editor as two
    // same-origin iframes; neither pane can see the other, so a save in one has
    // to be announced. Lives here rather than in each pane's own script because
    // three pages need the identical guard, and getting the guard wrong is what
    // would leak these notes to a hostile framer.
    //
    // A no-op on a standalone page — every one of these pages is reachable
    // directly, and there `window.parent === window`.
    //
    // Recognised types:
    //   'notebook-saved'  — a notebook was written back to the assignment, so
    //                       the edit pane's files list / validation state is stale.
    //   'inputs-changed'  — global or section inputs changed, so what the
    //                       notebook pane is rendering is a substitution of
    //                       stale values.
    function notifyWorkbench(type) {
        if (typeof window === 'undefined') return;
        try {
            // A same-document event, not a postMessage.  #1266 merged the
            // workbench into one document, so the listener is a sibling rather
            // than a parent frame — there is no window to post to, and the
            // origin checks that used to guard the channel are moot because
            // nothing crosses a boundary any more.
            //
            // Fired unconditionally: on a page with no workbench listening,
            // dispatching an event nobody handles costs nothing, and that is
            // simpler than each caller knowing which surface it is on.
            window.dispatchEvent(
                new CustomEvent('chickadee:workbench', { detail: { type: type } })
            );
        } catch (_) {
            // CustomEvent unavailable (very old browser). The surface stays
            // correct on its own; only the cross-half hint is lost.
        }
    }

    // ── Re-rendering the surface you are on ──────────────────────────────────
    //
    // `location.reload()` is the obvious way to pick up a server-side change,
    // and on the merged workbench (#1266) it is destructive: the edit form and
    // a live Pyodide kernel share one document, so reloading to show a renamed
    // suite section costs a 10-30s kernel boot and any unsaved cells. That is
    // the exact failure the merge exists to prevent, so the refresh re-renders
    // the *edit half only*, by fetching this same URL and swapping that half's
    // subtree.
    //
    // On the standalone `/edit` page there is no kernel and no `#wb-shell`, so
    // it stays a plain reload — same behaviour as before.
    //
    // Scroll position is preserved across the swap, because every caller is
    // re-rendering after a small edit — uploading one support file, renaming
    // one section — and landing back at the top of a long assignment each time
    // is its own kind of lost work.

    var EDIT_HALF_SELECTOR = '.wb-pane-edit';

    /// Re-execute the inline `<script>` blocks in a freshly swapped subtree.
    ///
    /// `innerHTML` never executes scripts, so without this the new markup is
    /// inert — no suite table, no editors. Only inline blocks are re-run:
    /// `src=` modules are already loaded and merely *define* the globals the
    /// inline blocks call, so re-fetching them would re-run their IIFEs and
    /// double-bind. The inline blocks bind nothing to `document`/`window`
    /// themselves; the two module-level listeners that do (suite-table's
    /// dragover and pageshow) carry their own once-per-document guards.
    function runInlineScripts(root) {
        var scripts = root.querySelectorAll('script:not([src])');
        Array.prototype.forEach.call(scripts, function (old) {
            // JSON seed blocks are data, not code — re-running them is
            // meaningless and `type` must be preserved for the ones that are.
            if (old.type && old.type !== 'text/javascript') return;
            var s = document.createElement('script');
            s.textContent = old.textContent;
            old.parentNode.replaceChild(s, old);
        });
    }

    var NOTEBOOK_HALF_SELECTOR = '.wb-notebook-body';

    /// Fetch `url` and swap one half's subtree from the response.
    ///
    /// Shared by both halves so the failure handling, the "am I even on the
    /// merged workbench" test, and the inline-script re-execution cannot drift
    /// between them.
    ///
    /// `opts.keepElement` names an element (by id) to carry across the swap
    /// rather than let `innerHTML` destroy. The notebook half needs this for
    /// `#jl-frame`: 34 closures in notebook.js capture that element, and a
    /// fresh one would leave every one of them on a detached node. Moving it
    /// does reload it — which a notebook switch wants, since the kernel belongs
    /// to whichever notebook is open.
    function swapHalf(selector, url, opts) {
        opts = opts || {};
        if (typeof document === 'undefined') return Promise.resolve(false);
        var half = document.querySelector(selector);
        // Not the merged workbench — the standalone editor. Reload as before.
        if (!half || !document.getElementById('wb-shell')) {
            window.location.reload();
            return Promise.resolve(true);
        }
        var scrollTop = half.scrollTop;
        var kept = opts.keepElement ? document.getElementById(opts.keepElement) : null;
        return fetch(url, {
            credentials: 'same-origin',
            headers: { 'X-Requested-With': 'fetch' }
        }).then(function (res) {
            if (!res.ok) throw new Error('refresh failed: ' + res.status);
            return res.text();
        }).then(function (html) {
            var doc = new DOMParser().parseFromString(html, 'text/html');
            var fresh = doc.querySelector(selector);
            if (!fresh) throw new Error('refresh failed: ' + selector + ' not in response');

            // Build the replacement as real nodes, NOT via `innerHTML`.
            //
            // `half.innerHTML = fresh.innerHTML` serializes to markup and
            // re-parses it, which silently defeats `keepElement`: the element
            // we meant to carry across would be written out as text and a brand
            // new one built from it, leaving every closure that captured the
            // original pointing at a detached node. Importing nodes preserves
            // object identity for the one element that needs it.
            var frag = document.createDocumentFragment();
            Array.prototype.slice.call(fresh.childNodes).forEach(function (n) {
                frag.appendChild(document.importNode(n, true));
            });

            if (kept) {
                var incoming = frag.querySelector('#' + opts.keepElement);
                if (!incoming) throw new Error('refresh failed: ' + opts.keepElement + ' not in response');
                // The incoming element's attributes are the whole point — they
                // name which notebook to open. Copy them onto ours, then put
                // ours where the new one would have gone.
                Array.prototype.forEach.call(incoming.attributes, function (a) {
                    if (a.name !== 'id') kept.setAttribute(a.name, a.value);
                });
                incoming.parentNode.replaceChild(kept, incoming);
            }

            half.textContent = '';
            half.appendChild(frag);
            runInlineScripts(half);
            half.scrollTop = scrollTop;
            return true;
        }).catch(function () {
            // A failed refresh must not leave a half-swapped page. Whatever
            // prompted it already happened server-side, so a full reload is
            // correct — it costs the kernel, but showing stale state is worse.
            window.location.reload();
            return false;
        });
    }

    /// Re-render the edit half in place after a write.
    ///
    /// `window.location.href`, not a stored URL: the merged page's own URL
    /// already names exactly what to re-render, including which notebook is
    /// open, so there is no second URL to keep in sync (and no DOM-sourced
    /// navigation target to validate).
    function refreshEditSurface() {
        return swapHalf(EDIT_HALF_SELECTOR, window.location.href);
    }

    /// Open a different notebook (file and/or view) without leaving the page.
    ///
    /// The kernel restarts regardless — it is bound to the open notebook — so
    /// what this buys is the *edit half*: it is not rebuilt, so its open
    /// editors and any metadata typed but not yet saved survive, where a
    /// navigation took them with it.
    ///
    /// **Known limitation: the edit half's scroll position is not preserved.**
    /// Emptying the notebook half reflows the grid, and while it is empty the
    /// edit half stops overflowing, which clamps its `scrollTop` to 0. Writing
    /// the old value back — synchronously or on the next frame — does not
    /// survive; something resets it again before the layout settles, and I did
    /// not isolate what. Called out rather than papered over: an author who
    /// switches notebooks lands back at the top of the edit half. Their *work*
    /// is intact, which is the property that matters, and this is strictly
    /// better than the navigation it replaces, which lost the work too.
    function refreshNotebookSurface(url) {
        return swapHalf(NOTEBOOK_HALF_SELECTOR, url, { keepElement: 'jl-frame' })
            .then(function (ok) {
                if (!ok) return false;
                // Re-read the new data-* attributes and re-mount. Absent on a
                // page with no notebook half, which is not an error.
                if (typeof window.chickadeeRemountNotebook === 'function') {
                    window.chickadeeRemountNotebook();
                }
                return true;
            });
    }

    // The sessionStorage round-trip that used to restore scroll after the
    // pane's `location.replace` is gone with the navigation itself: the swap
    // never unloads the document, so `refreshEditSurface` just reads
    // `half.scrollTop` before and writes it back after.

    // Warns when a chosen date falls within three days of a UWaterloo
    // important date.  Hoisted here from three inline copies that had already
    // drifted: the two assignment editors guarded `warningEl` against null in
    // one copy but not the other, and the dashboard publish form used a
    // shorter label.  The guards are kept (strictest wins, as with escapeHtml
    // above) and the label is a parameter, so no page's visible text changes.
    //
    // Returns a promise so callers — and tests — can await the fetch.
    function checkUWDates(dateTimeValue, warningEl, options) {
        var label = (options && options.label) || 'Due date is near:';

        function hide() {
            if (warningEl) warningEl.style.display = 'none';
        }

        if (!dateTimeValue) { hide(); return Promise.resolve(); }
        var selected = new Date(dateTimeValue);
        if (isNaN(selected.getTime())) { hide(); return Promise.resolve(); }

        return fetch('/api/v1/uw-dates').then(function (resp) {
            if (!resp.ok) return;
            return resp.json();
        }).then(function (dates) {
            if (!dates || !warningEl) return;
            var threeDays = 3 * 86400000;
            var near = dates.filter(function (d) {
                var start = new Date(d.startDate);
                var end = new Date(d.endDate);
                return selected >= new Date(start.getTime() - threeDays)
                    && selected < new Date(end.getTime() + threeDays);
            });
            if (near.length > 0) {
                warningEl.textContent = '⚠ ' + label + ' '
                    + near.map(function (d) { return d.title; }).join(', ');
                warningEl.style.display = '';
            } else {
                warningEl.style.display = 'none';
            }
        }).catch(function () { /* offline or 404 — the warning is advisory */ });
    }

    var root = typeof window !== 'undefined' ? window : globalThis;
    root.ChickadeeUI = {
        escapeHtml: escapeHtml,
        escapeAttr: escapeHtml,
        getCsrfToken: getCsrfToken,
        confirmAction: confirmAction,
        setStatus: setStatus,
        extractErrorMessage: extractErrorMessage,
        fetchJSON: fetchJSON,
        notifyWorkbench: notifyWorkbench,
        checkUWDates: checkUWDates,
        refreshEditSurface: refreshEditSurface,
        refreshNotebookSurface: refreshNotebookSurface,
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
