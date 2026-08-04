// Public/global-inputs-editor.js
//
// Slice 1 + Slice 2 of issue #461 — wires the "Global Inputs" panel at the
// top of the assignment edit page.  All row/value/validation/auto-save
// mechanics live in the shared core (Public/inputs-editor-core.js, #1126);
// what remains here is this panel's class names, its endpoint
// (PUT /instructor/:id/global-variables), and its status-line reporting
// (including server warnings).
//
// Value-cell semantics (literal vs `=` expression) are documented in the
// core.  Old clients sending only `variables` keep working server-side.

(function () {
    'use strict';

    var core = ChickadeeInputsCore;
    var editor = core.createEditor({
        row: 'global-input-row',
        name: 'global-input-name',
        value: 'global-input-value',
        valid: 'global-input-row-valid',
        remove: 'global-input-remove'
    }, {});

    function init() {
        var block = document.getElementById('global-inputs-block');
        if (!block) return;
        var tbody = block.querySelector('tbody.global-inputs-body');
        var addBtn = document.getElementById('global-input-add');
        var status = document.getElementById('global-inputs-status');
        var assignmentID = block.getAttribute('data-assignment-id') || '';
        if (!tbody || !assignmentID) return;

        var url = '/instructor/' + encodeURIComponent(assignmentID) + '/global-variables';

        function setStatus(text, kind) {
            ChickadeeUI.setStatus(status, text, kind);
        }

        function doSave() {
            var payload = editor.buildPayload(tbody);
            if (!payload) {
                setStatus('Fix highlighted rows to save.', 'error');
                return Promise.resolve();
            }
            setStatus('Saving…', null);
            return fetch(url, {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json', 'x-csrf-token': ChickadeeUI.getCsrfToken() },
                body: JSON.stringify(payload)
            }).then(function (r) {
                if (r.ok) {
                    // Global inputs feed personalization, so a notebook open in
                    // the workbench's other pane is now a rendering of stale
                    // values.  The shell raises an advisory chip rather than
                    // reloading that pane, which would restart the kernel.
                    ChickadeeUI.notifyWorkbench('inputs-changed');
                    return r.json().then(function (body) {
                        var warns = body && body.warnings;
                        if (warns && warns.length) {
                            setStatus('Saved. Warnings: ' + warns.join('; '), 'error');
                        } else {
                            setStatus('Saved.', 'ok');
                        }
                    }).catch(function () { setStatus('Saved.', 'ok'); });
                }
                return r.text().catch(function () { return ''; }).then(function (t) {
                    var msg = ChickadeeUI.extractErrorMessage(t) || ('HTTP ' + r.status);
                    setStatus('Save failed: ' + msg.slice(0, 240), 'error');
                });
            }).catch(function (err) {
                setStatus('Save failed: ' + (err && err.message ? err.message : err), 'error');
            });
        }

        var saver = core.makeDebouncedSaver(doSave, 500);

        editor.refreshAllRows(tbody);

        block.addEventListener('input', function (e) {
            var tr = e.target.closest && e.target.closest('tr.global-input-row');
            if (tr) {
                editor.refreshAllRows(tbody);
                saver.schedule();
            }
        });
        block.addEventListener('click', function (e) {
            var btn = e.target.closest && e.target.closest('.global-input-remove');
            if (btn && block.contains(btn)) {
                var tr = btn.closest('tr.global-input-row');
                if (tr) { tr.remove(); editor.refreshAllRows(tbody); saver.schedule(); }
            }
        });

        if (addBtn) {
            addBtn.addEventListener('click', function () { editor.addEmptyRow(tbody); });
        }

        // Expose a global flush hook so the main "Save & Validate"
        // submit can await any pending PUTs before reloading the page.
        window.chickadeeFlushGlobalInputs = saver.flush;
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
