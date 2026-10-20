// Public/global-inputs-editor.js
//
// Slice 1 + Slice 2 of issue #461 — wires the "Global Inputs" panel at the
// top of the assignment edit page.  All row/value/validation/auto-save
// mechanics, and the panel wiring, live in the shared core
// (Public/inputs-editor-core.js, #1126, #2721); what remains here is this
// panel's class names, its endpoint
// (PUT /instructor/:id/global-variables), and its status-line reporting
// (including server warnings).
//
// Value-cell semantics (literal vs `=` expression) are documented in the
// core.  Old clients sending only `variables` keep working server-side.

(function () {
    'use strict';

    var core = ChickadeeInputsCore;
    var classes = {
        row: 'js-global-input-row',
        name: 'js-global-input-name',
        value: 'js-global-input-value',
        valid: 'js-global-input-row-valid',
        remove: 'js-global-input-remove'
    };
    var editor = core.createEditor(classes, {});

    // init() can run again (#1957): the workbench calls it after it swaps the
    // edit half. The new half has a new panel to wire, and a panel wired
    // before is not wired twice (`ChickadeeUI.wireOnce`).
    function init() {
        var block = document.getElementById('global-inputs-block');
        if (!block) return;
        var tbody = block.querySelector('tbody.js-global-inputs-body');
        var addBtn = document.getElementById('global-input-add');
        var status = document.getElementById('global-inputs-status');
        var assignmentID = block.getAttribute('data-assignment-id') || '';
        if (!tbody || !assignmentID) return;
        if (!ChickadeeUI.wireOnce(block, 'global-inputs')) return;

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
            return ChickadeeUI.fetchJSON(url, { method: 'PUT', body: payload }).then(function (body) {
                // Global inputs feed personalization, so a notebook open in
                // the workbench's other pane is now a rendering of stale
                // values.  The shell raises an advisory chip rather than
                // reloading that pane, which would restart the kernel.
                ChickadeeUI.notifyWorkbench('inputs-changed');
                var warns = body && body.warnings;
                if (warns && warns.length) {
                    setStatus('Saved. Warnings: ' + warns.join('; '), 'error');
                } else {
                    setStatus('Saved.', 'ok');
                }
            }).catch(function (err) {
                var msg = String(err && err.message ? err.message : err);
                setStatus('Save failed: ' + msg.slice(0, 240), 'error');
            });
        }

        var saver = core.makeDebouncedSaver(doSave, 500);
        core.wirePanel(block, tbody, classes, editor, saver);

        if (addBtn) {
            addBtn.addEventListener('click', function () {
                editor.addEmptyRow(tbody);
                core.syncCueNote(block, tbody);
            });
        }

        // Expose a global flush hook so the main "Save & Validate"
        // submit can await any pending PUTs before reloading the page.
        window.chickadeeFlushGlobalInputs = saver.flush;
        // Only a save that is waiting: the workbench swap awaits this before
        // it discards the panel (surface-swap.js), and must not write for
        // nothing.
        window.chickadeeFlushPendingGlobalInputs = saver.flushPending;
    }

    // Called again by ChickadeeEditPage.init() after a workbench swap.
    window.initGlobalInputsEditor = init;

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
