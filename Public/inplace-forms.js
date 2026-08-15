// Public/inplace-forms.js
//
// Keeps the workbench's left pane on the left pane.
//
// The assignment editor persists most of what it owns through ordinary form
// POSTs — save, create-solution, secret-reveal, and section create/rename —
// and every one of those handlers answers with a redirect to
// `/instructor/:id/edit`, the fully-chromed standalone editor. That is correct
// for the standalone page and wrong inside the workbench, where the redirect
// lands *in the pane*: the author adds a suite section and the pane is
// suddenly a second copy of the editor, nav bar and all, sitting under the
// workbench's own Save button. Adding a section is not an edge case, so
// neither is the confusing state.
//
// This file intercepts those submits, POSTs them with fetch, and then puts the
// pane back on the panel URL it was already showing. Nothing about the request
// changes — same endpoint, same encoding, same fields — only where the browser
// goes afterwards.
//
// Loaded by base.leaf only for embedded panes, so the standalone `/edit` page
// never sees it and keeps its native submit-and-redirect behaviour exactly.
//
// A form opts in with `data-ck-inplace`. The attribute is unconditional in the
// template (harmless where this script is not loaded), so the two renderings of
// `assignment-edit.leaf` stay byte-identical apart from the parts that must
// differ.

(function () {
    'use strict';

    // The merged workbench is the only surface that wants this: its forms sit
    // in the same document as a live kernel, so a native submit-and-redirect
    // would tear the kernel down. The standalone `/edit` page has no
    // `#wb-shell` and keeps its native behaviour exactly.
    if (!document.getElementById('wb-shell')) return;

    // ── Error surface ────────────────────────────────────────────────────────
    // Same inline banner base.leaf uses for a failed multipart upload, for the
    // same reason: a native dialog inside a pane is a modal over one third of
    // the screen with no indication of which half raised it.
    function showError(form, msg) {
        var banner = form.querySelector('.js-inplace-error-banner');
        if (!banner) {
            banner = document.createElement('div');
            banner.className = 'form-error js-inplace-error-banner';
            banner.setAttribute('role', 'alert');
            form.insertBefore(banner, form.firstChild);
        }
        banner.textContent = msg;
        banner.scrollIntoView({ block: 'nearest' });
    }

    function clearError(form) {
        var banner = form.querySelector('.js-inplace-error-banner');
        if (banner) banner.remove();
    }

    // ── Request ──────────────────────────────────────────────────────────────

    // Preserve each form's own encoding rather than sending everything as
    // FormData. The section and secret-reveal endpoints decode
    // `application/x-www-form-urlencoded` today; switching them to multipart
    // would be a live change to how their handlers parse, made silently, for
    // no reason. CSRF rides the header either way — the multipart body is not
    // buffered before the middleware runs, which is why base.leaf's handler
    // sends the header too.
    function requestFor(form) {
        var fd = new FormData(form);
        if (form.enctype === 'multipart/form-data') {
            return { body: fd, headers: {} };
        }
        return {
            body: new URLSearchParams(fd),
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' }
        };
    }

    // Re-render the pane rather than patching its DOM. The panel is a whole
    // page of server-rendered state with a dozen editors bound to it, and
    // re-rendering it is exactly what the redirect was already doing — minus
    // the wrong destination.
    //
    // This is also the reason Slice 1 stops here rather than going straight to
    // one document: merged, a re-render would restart the Pyodide kernel, so
    // the refresh has to become a DOM swap with re-initialisation. That work
    // belongs with the merge, not ahead of it.

    /// POST a form and re-render the pane. Resolves true on success, false on
    /// failure (with the banner already shown) — never rejects, so callers
    /// waiting on a save always get an answer.
    function submitInPlace(form) {
        if (!form) return Promise.resolve(false);
        clearError(form);

        var submitter = form.querySelector('[type="submit"]');
        if (submitter) submitter.disabled = true;

        var req = requestFor(form);
        req.headers['x-csrf-token'] = ChickadeeUI.getCsrfToken();

        return fetch(form.action, {
            method: (form.method || 'POST').toUpperCase(),
            headers: req.headers,
            body: req.body,
            credentials: 'same-origin'
        }).then(function (res) {
            // `res.ok` covers the redirect the handlers answer with: fetch
            // follows it and reports the final 200. A non-OK status is the
            // handler's own error page, so its text is the useful message.
            if (res.ok) {
                // Scheduled, not called: `submitInPlace` resolves to callers
                // that need the outcome (the workbench's Save reports it back
                // to the shell), and a `.then` is a microtask. Reloading here
                // would start tearing this document down in the same turn the
                // caller is still queued behind.
                setTimeout(function () { ChickadeeSurfaceSwap.refreshEditSurface(); }, 0);
                return true;
            }
            return res.text().then(function (text) {
                showError(form, 'Save failed: ' + res.status + ' '
                    + (ChickadeeUI.extractErrorMessage(text) || res.statusText));
                if (submitter) submitter.disabled = false;
                return false;
            });
        }).catch(function (err) {
            showError(form, 'Save failed: ' + ((err && err.message) || 'network error'));
            if (submitter) submitter.disabled = false;
            return false;
        });
    }

    // ── Wiring ───────────────────────────────────────────────────────────────

    // Registered from base.leaf's embedded block, which runs before the inline
    // multipart handler further down that file. That handler already bails on
    // `e.defaultPrevented`, so preventing here is all it takes to keep the two
    // from both firing.
    document.addEventListener('submit', function (e) {
        var form = e.target;
        if (!form || typeof form.matches !== 'function') return;
        if (!form.matches('[data-ck-inplace]')) return;
        if (e.defaultPrevented) return;
        e.preventDefault();
        submitInPlace(form);
    });

    // Exposed for the one caller that reaches this write without a form
    // submit: the workbench's single Save button, in workbench.js.
    window.chickadeeSubmitInPlace = submitInPlace;
}());
