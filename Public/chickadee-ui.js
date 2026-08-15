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
//
// What belongs here is the low-level shared utility: escaping, the CSRF token,
// a status line, a fetch wrapper, an error extractor, a confirmation dialog.
// This module once held eighteen functions behind that one name, which is how
// a chart renderer and an accordion came to be loaded by every page in the
// product. Those are their own concerns and have their own files and names:
//
//   ChickadeeSparkline    Public/sparkline.js      dashboard bar renderer
//   ChickadeeAccordion    Public/accordion-row.js  inline detail-row editor
//   ChickadeeSurfaceSwap  Public/surface-swap.js   in-place workbench refresh
//
// A new cross-file concern gets a file and a name of its own. Add to this one
// only what really is a shared low-level utility.
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
    // copies).  Sets the element's text and colour-class by kind:
    // 'error' → .text-error, 'ok'/'success' → .text-ok, else .text-quiet.
    function setStatus(el, text, kind) {
        if (!el) return;
        el.textContent = text || '';
        el.classList.remove('text-error', 'text-ok', 'text-quiet');
        el.classList.add(kind === 'error'
            ? 'text-error'
            : (kind === 'ok' || kind === 'success') ? 'text-ok' : 'text-quiet');
    }

    // ── Destructive-action confirmation ──
    //
    // The JS-side entry to the same seam `data-confirm` uses (app.js). A call
    // site that has no element to hang an attribute on — a delete triggered
    // from inside an editor's own click handler — asks here.
    //
    // This used to be `window.confirm`, with a comment saying it existed so
    // the native dialog could be replaced in one place. This is that
    // replacement, and it covers all 41 destructive confirmations (36
    // `data-confirm` attributes across 18 templates, 5 direct callers):
    // unenroll a student, delete a section, delete a test script, delete a
    // pattern family, remove a support file. The native dialog was the one
    // piece of UI outside the design system — unthemed, unstyleable, invisible
    // to the axe scan, and rendered by the browser chrome rather than the page
    // it belongs to. It is the sibling of the native alerting call the S9 slice
    // removed, and it outlived that slice only because nobody had written the
    // dialog. (Naming that call in prose here would trip the guard that keeps
    // it at zero — the scanner cannot tell markup from prose about markup, the
    // same lesson as the Leaf-comment finding in #1266.)
    //
    // It returns a PROMISE, which is the one thing callers must know: a real
    // dialog cannot block the event loop the way the native one did.
    // `data-confirm` callers are unaffected (app.js replays the action for
    // them); the five direct callers await it.
    function confirmAction(message, nearEl) {
        if (typeof document === 'undefined' || !document.createElement) {
            return Promise.resolve(true);
        }
        return new Promise(function (resolve) {
            var previouslyFocused = document.activeElement;
            var overlay = document.createElement('div');
            overlay.className = 'modal-overlay';

            var card = document.createElement('div');
            card.className = 'modal-card modal-card--confirm';
            // alertdialog, not dialog: this interrupts to ask about something
            // consequential, and screen readers announce the message on open.
            card.setAttribute('role', 'alertdialog');
            card.setAttribute('aria-modal', 'true');

            var body = document.createElement('div');
            body.className = 'modal-body confirm-message';
            body.textContent = message;
            var messageID = 'ck-confirm-message';
            body.id = messageID;
            card.setAttribute('aria-describedby', messageID);
            card.setAttribute('aria-label', 'Confirm');

            var foot = document.createElement('div');
            foot.className = 'modal-foot';
            var cancel = document.createElement('button');
            cancel.type = 'button';
            cancel.className = 'btn';
            cancel.textContent = 'Cancel';
            var confirm = document.createElement('button');
            confirm.type = 'button';
            confirm.className = 'btn btn-primary';
            confirm.textContent = 'Confirm';
            foot.appendChild(cancel);
            foot.appendChild(confirm);

            card.appendChild(body);
            card.appendChild(foot);
            overlay.appendChild(card);
            (nearEl && nearEl.ownerDocument ? nearEl.ownerDocument.body : document.body).appendChild(overlay);

            var settled = false;
            function close(result) {
                if (settled) return;
                settled = true;
                document.removeEventListener('keydown', onKeydown, true);
                if (overlay.parentNode) overlay.parentNode.removeChild(overlay);
                // Put focus back where the user left it, or the page silently
                // drops them at the top of the document.
                if (previouslyFocused && previouslyFocused.focus) previouslyFocused.focus();
                resolve(result);
            }

            function onKeydown(event) {
                if (event.key === 'Escape') {
                    event.preventDefault();
                    close(false);
                    return;
                }
                if (event.key !== 'Tab') return;
                // Two focusable elements, so the trap is a cycle between them.
                event.preventDefault();
                (document.activeElement === confirm ? cancel : confirm).focus();
            }

            cancel.addEventListener('click', function () { close(false); });
            confirm.addEventListener('click', function () { close(true); });
            // A click on the scrim is a cancel, as it is for every other modal
            // here; a click inside the card is not.
            overlay.addEventListener('click', function (event) {
                if (event.target === overlay) close(false);
            });
            document.addEventListener('keydown', onKeydown, true);

            // Cancel takes focus: the safe choice should be the one an
            // accidental Enter lands on.
            cancel.focus();
        });
    }

    // ── Action failures ──
    //
    // The one blocking-error channel (UI audit S9): an inline `.form-error`
    // banner with `role="alert"`, placed at the top of the surface the action
    // belongs to, matching what inplace-forms.js and the multipart-upload
    // handler already do.
    //
    // It replaces the native modal dialog the editors used, which stopped the
    // page to say something the page could show in place — and which, on the
    // support-file widget, meant one control reported its *upload* failures in
    // a status line and its *delete* failures in a modal.
    //
    // `nearEl` names the surface: the banner goes at the top of that element's
    // nearest section, so a failure appears next to the thing that failed
    // rather than at the top of a long editor.
    function showActionError(message, nearEl) {
        if (typeof document === 'undefined') return;
        var host = null;
        if (nearEl && nearEl.closest) {
            host = nearEl.closest('.page-section, .section-block, .editor-panel, form') || null;
        }
        host = host || document.querySelector('.main') || document.body;
        var banner = host.querySelector(':scope > .action-error-banner');
        if (!banner) {
            banner = document.createElement('div');
            banner.className = 'form-error action-error-banner';
            banner.setAttribute('role', 'alert');
            host.insertBefore(banner, host.firstChild);
        }
        banner.textContent = message;
        if (banner.scrollIntoView) banner.scrollIntoView({ block: 'nearest' });
        return banner;
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
        showActionError: showActionError,
        setStatus: setStatus,
        extractErrorMessage: extractErrorMessage,
        fetchJSON: fetchJSON,
        notifyWorkbench: notifyWorkbench,
        checkUWDates: checkUWDates
    };

    // Node export for the .mjs unit tests (Tests/BrowserRunnerJSTests);
    // browsers take the `root.ChickadeeUI` global above.
    if (typeof module === 'object' && module.exports) {
        module.exports = root.ChickadeeUI;
    }
}());
