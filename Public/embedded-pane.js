// Public/embedded-pane.js
//
// The pane half of the assignment workbench's cross-pane wiring. Loaded by
// base.leaf only when a page is rendered *into* a workbench pane.
//
// Two jobs, both of which exist because a pane cannot see its sibling:
//
//   1. **Opening a notebook.** The left pane's Files table is the only place
//      that lists an assignment's notebooks, so it is the only place that
//      chooses which one is open. Its Edit buttons are ordinary links — they
//      still navigate on the standalone page — and here they are intercepted
//      and turned into a request to the shell.
//
//   2. **Saving.** The workbench has one Save button. It asks each pane to save
//      itself and waits for both replies, so a pane must answer even when it
//      has nothing to save; staying silent would leave the button disabled
//      forever.
//
// Deliberately separate from `embedded-activity.js`: that file forwards
// keystrokes so the idle watchdog does not sign an author out, and it must keep
// working even if this wiring is ever removed.

(function () {
    'use strict';

    if (window.parent === window) return;

    function post(type, extra) {
        var payload = { source: 'chickadee', type: type };
        if (extra) {
            Object.keys(extra).forEach(function (k) { payload[k] = extra[k]; });
        }
        try {
            // Explicit origin, never '*': these messages describe what an
            // instructor is editing.
            window.parent.postMessage(payload, window.location.origin);
        } catch (_) { /* parent gone mid-navigation */ }
    }

    // --- 1. Files-table Edit buttons open into the notebook pane -------------

    document.addEventListener('click', function (e) {
        var el = e.target.closest && e.target.closest('[data-wb-file]');
        if (!el) return;
        // preventDefault, not a href removal: on the standalone page this
        // listener never runs (no parent), so the link keeps working there.
        e.preventDefault();
        post('open-notebook', { file: el.getAttribute('data-wb-file') });
    });

    // --- 2. Answer the shell's Save ------------------------------------------

    // The notebook page exposes `window.chickadeeSaveToAssignment` — the POST to
    // /notebook/save, resolving true/false. Deliberately NOT
    // `chickadeeSaveNotebook`, which despite the name only flushes cells to
    // JupyterLite's local storage and would report a save that never reached
    // the server. A pane with neither still replies `ok`, because "nothing to
    // save" is a success, and silence would leave the shell's button disabled.
    function performSave() {
        if (typeof window.chickadeeSaveToAssignment === 'function') {
            Promise.resolve()
                .then(function () { return window.chickadeeSaveToAssignment(); })
                .then(function (ok) { post('save-result', { ok: ok !== false }); })
                .catch(function () { post('save-result', { ok: false }); });
            return;
        }

        var form = document.querySelector('form[action$="/edit/save"]');
        if (form) {
            // `chickadeeSubmitInPlace` is what this pane's own submit handler
            // uses, so Save and a click on the form's submit button take the
            // identical path. It resolves with the real outcome and never
            // rejects, which is why the reply can wait for it — this used to
            // reply `ok` optimistically and then submit natively, because the
            // pane was about to navigate away and a later reply would never
            // arrive. It reported success on a 500.
            if (typeof window.chickadeeSubmitInPlace === 'function') {
                window.chickadeeSubmitInPlace(form).then(function (ok) {
                    post('save-result', { ok: ok !== false });
                });
                return;
            }
            post('save-result', { ok: true });
            form.requestSubmit ? form.requestSubmit() : form.submit();
            return;
        }

        post('save-result', { ok: true });
    }

    window.addEventListener('message', function (event) {
        if (event.origin !== window.location.origin) return;
        var data = event.data;
        if (!data || data.source !== 'chickadee' || data.type !== 'save') return;
        performSave();
    });
}());
