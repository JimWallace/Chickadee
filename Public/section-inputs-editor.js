// Public/section-inputs-editor.js
//
// Slice 4 of issue #461 — per-section inputs panels on the assignment edit
// page.  All row/value/validation/auto-save mechanics live in the shared
// core (Public/inputs-editor-core.js, #1126); what remains here is this
// panel's class names, its endpoint
// (POST /instructor/:id/suite-sections/:sectionID/variables), and its
// per-form wiring (one form per section, silent console-logged failures).
//
// Value-cell semantics (literal vs `=` expression) are documented in the
// core.  Old editor builds sending only `variables` keep working
// server-side.

(function () {
    'use strict';

    var core = ChickadeeInputsCore;
    var editor = core.createEditor({
        row: 'section-var-row',
        name: 'section-var-name',
        value: 'section-var-value',
        valid: 'section-var-row-valid',
        remove: 'section-var-remove'
    }, { inputFontSize: '.78rem', removeCell: 'inline' });

    /// Per-form auto-save with debounce + in-flight coalescing.  Returns
    /// a public { flush } object that the main-form submit handler can
    /// await before letting the assignment save through.
    function wireAutoSave(form) {
        var tbody = form.querySelector('tbody.section-vars-body');
        if (!tbody) return { flush: function () { return Promise.resolve(); } };

        function doPost() {
            var payload = editor.buildPayload(tbody);
            if (!payload) return Promise.resolve();
            return fetch(form.action, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json', 'x-csrf-token': ChickadeeUI.getCsrfToken() },
                redirect: 'manual',
                body: JSON.stringify(payload)
            }).then(function (r) {
                if (!r.ok && r.type !== 'opaqueredirect') {
                    return r.text().catch(function () { return ''; }).then(function (t) {
                        throw new Error('section-vars save failed: HTTP ' + r.status + ' ' + t.slice(0, 200));
                    });
                }
                // Section variables feed personalization the same way global
                // inputs do, so a notebook open in the workbench's other pane is
                // now rendering stale values.  Advisory only — see the shell.
                ChickadeeUI.notifyWorkbench('inputs-changed');
            }).catch(function (err) {
                console.error('section-vars auto-save failed:', err);
            });
        }

        var saver = core.makeDebouncedSaver(doPost, 500);

        editor.refreshAllRows(tbody);

        form.addEventListener('input', function (e) {
            var tr = e.target.closest && e.target.closest('tr.section-var-row');
            if (tr) {
                editor.refreshAllRows(tbody);
                saver.schedule();
            }
        });
        form.addEventListener('click', function (e) {
            var btn = e.target.closest && e.target.closest('.section-var-remove');
            if (btn && form.contains(btn)) {
                var tr = btn.closest('tr.section-var-row');
                if (tr) { tr.remove(); editor.refreshAllRows(tbody); saver.schedule(); }
            }
        });
        form.addEventListener('submit', function (e) { e.preventDefault(); saver.flush(); });

        return { flush: saver.flush };
    }

    function init() {
        var forms = Array.from(document.querySelectorAll('form.section-vars-form'))
            .map(wireAutoSave);

        window.chickadeeFlushSectionVars = function () {
            return Promise.all(forms.map(function (f) { return f.flush(); }));
        };

        // "+ Add Input" buttons (one per section).  Buttons live in the
        // section header, not inside the form, so look up the form by
        // data-section-id.
        document.querySelectorAll('button.section-var-add').forEach(function (btn) {
            btn.addEventListener('click', function () {
                var sid = btn.getAttribute('data-section-id') || '';
                var form = document.querySelector('form.section-vars-form[data-section-id="' + sid + '"]');
                if (!form) return;
                var tbody = form.querySelector('tbody.section-vars-body');
                if (tbody) editor.addEmptyRow(tbody);
            });
        });
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
