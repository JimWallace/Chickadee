// Page wiring for the instructor BrightSpace page (instructor-brightspace.leaf):
// the connection test button and the grade-item pickers.  Extracted from the
// template's inline script block so it is linted and testable; the reserved
// do-not-sync token rides on the datalist's data-do-not-sync-token attribute
// (kept in sync with BrightspaceSync.doNotSyncToken on the server).
(function () {
    'use strict';

    // ── Connection panel: "Test connection" ────────────────────────────────
    // POSTs to the whoami test endpoint and renders the JSON verdict inline,
    // so credential problems surface here instead of at grade-push time.
    var testBtn = document.getElementById('bs-test-connection');
    if (testBtn) {
        testBtn.addEventListener('click', function () {
            var out = document.getElementById('bs-test-result');
            if (!out) return;
            out.hidden = false;
            out.className = 'bs-test-result';
            out.textContent = 'Testing…';
            fetch('/instructor/brightspace/test', {
                method: 'POST',
                headers: { 'x-csrf-token': ChickadeeUI.getCsrfToken() }
            }).then(function (res) {
                return res.json();
            }).then(function (result) {
                out.textContent = result.message;
                out.className = 'bs-test-result ' + (result.ok ? 'chip-ok' : 'chip-err');
            }).catch(function () {
                out.textContent = 'The connection test could not be run.';
                out.className = 'bs-test-result chip-err';
            });
        });
    }

    // ── Grade-item dropdown ────────────────────────────────────────────────
    // Fetch grade objects from D2L, populate the shared <datalist> with names
    // (not IDs), and resolve existing raw IDs to display names.
    var datalist = document.getElementById('bs-grade-objects');
    if (!datalist) return;

    // "Do not sync" is an option in this same dropdown: picking it excludes the
    // assignment from LEARN. It resolves to a reserved token the save handler
    // maps to the do-not-sync flag — never a real grade item.
    var DO_NOT_SYNC_ID = datalist.getAttribute('data-do-not-sync-token') || '';
    var DO_NOT_SYNC_LABEL = 'Do not sync (exclude from LEARN)';

    function optionHTML(value, id) {
        var opt = document.createElement('option');
        opt.value = value;
        opt.dataset.id = id;
        return opt.outerHTML;
    }

    // Wire each row: resolve its stored value to a display name on load, and
    // resolve the chosen name back to an ID (or the do-not-sync token) on submit.
    function wireForms(byId, byName) {
        document.querySelectorAll('.bs-grade-form').forEach(function (form) {
            var visibleInput = form.querySelector('.bs-grade-input');
            var hiddenInput = form.querySelector('.js-bs-grade-id-hidden');
            if (!visibleInput || !hiddenInput) return;
            var rawId = visibleInput.dataset.rawId || '';
            if (rawId && byId[rawId]) {
                visibleInput.value = byId[rawId];
            }
            // Pre-fill hidden with the raw value so save works even without a match.
            hiddenInput.value = rawId;
            form.addEventListener('submit', function () {
                var val = visibleInput.value.trim();
                // Resolve a display name to its ID / the do-not-sync token; else
                // submit the typed value as-is.
                hiddenInput.value = byName[val] || val;
            });
        });
    }

    fetch('/instructor/brightspace/grade-objects', {
        headers: { 'Accept': 'application/json' }, cache: 'no-store'
    }).then(function (res) {
        return res.ok ? res.json() : [];
    }).then(function (items) {
        if (!Array.isArray(items)) items = [];

        // Build id→name and name→id maps, seeded with the do-not-sync option.
        var byId = {};
        var byName = {};
        byId[DO_NOT_SYNC_ID] = DO_NOT_SYNC_LABEL;
        byName[DO_NOT_SYNC_LABEL] = DO_NOT_SYNC_ID;
        items.forEach(function (it) {
            var label = it.name;
            if (it.gradeType && it.gradeType !== 'Numeric') {
                label += ' — ' + it.gradeType + ' (not supported)';
            }
            byId[String(it.id)] = label;
            byName[label] = String(it.id);
        });

        // Populate datalist: do-not-sync first, then the grade items by name.
        datalist.innerHTML = optionHTML(DO_NOT_SYNC_LABEL, DO_NOT_SYNC_ID)
            + items.map(function (it) {
                var label = it.name;
                if (it.gradeType && it.gradeType !== 'Numeric') {
                    label += ' — ' + it.gradeType + ' (not supported)';
                }
                return optionHTML(label, String(it.id));
            }).join('');

        wireForms(byId, byName);

    }).catch(function () {
        // D2L unreachable: only the do-not-sync option is offered; grade-item
        // names can't be resolved, so any typed ID passes through unchanged.
        var byId = {};
        var byName = {};
        byId[DO_NOT_SYNC_ID] = DO_NOT_SYNC_LABEL;
        byName[DO_NOT_SYNC_LABEL] = DO_NOT_SYNC_ID;
        datalist.innerHTML = optionHTML(DO_NOT_SYNC_LABEL, DO_NOT_SYNC_ID);
        wireForms(byId, byName);
    });
})();
