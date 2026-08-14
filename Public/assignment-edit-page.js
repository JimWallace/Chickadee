// Page wiring for the assignment edit surface (_assignment-edit-body.leaf),
// loaded on both of its hosts: the standalone edit page and the workbench's
// edit pane.  Extracted from the partial's inline script blocks so every URL
// builder and event hook is linted and testable; the template carries data
// only — the JSON seeds and the data-assignment-id attribute this file reads.
//
// Load order: after the module scripts it wires (suite-table.js,
// pattern-family-editor.js, test-editor-modal.js, support-files.js).  The two
// ES-module renderers evaluate later than any classic script, and they read
// window.ChickadeeScriptRendererConfig lazily, so setting it here is early
// enough.
(function () {
    'use strict';

    var carrier = document.querySelector('[data-assignment-id]');
    var assignmentID = carrier ? (carrier.getAttribute('data-assignment-id') || '') : '';
    var csrfToken = ChickadeeUI.getCsrfToken();

    // ── Header view/edit toggle ─────────────────────────────────────────────
    (function () {
        var headerView   = document.getElementById('assign-header-view');
        var headerEdit   = document.getElementById('assign-header-edit');
        var toggleBtn    = document.getElementById('assign-edit-toggle');
        var cancelBtn    = document.getElementById('assign-edit-cancel');
        var nameInput    = document.getElementById('assignmentNameInput');
        var dueInput     = document.getElementById('dueAt');
        var dueDisplay   = document.getElementById('assign-due-display');

        function formatDueDate(val) {
            if (!val) return 'No deadline';
            // datetime-local format: "2024-03-15T09:00"
            var d = new Date(val);
            if (isNaN(d.getTime())) return val.replace('T', '\u2002');
            return 'Due\u00a0' + d.toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' })
                + '\u00a0at\u00a0' + d.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
        }

        function refreshDueDisplay() {
            if (dueDisplay) dueDisplay.textContent = dueInput ? formatDueDate(dueInput.value) : '';
        }

        if (toggleBtn && headerView && headerEdit) {
            toggleBtn.addEventListener('click', function () {
                headerView.style.display = 'none';
                headerEdit.style.display = '';
                if (nameInput) { nameInput.focus(); nameInput.select(); }
            });
        }

        if (cancelBtn && headerView && headerEdit) {
            cancelBtn.addEventListener('click', function () {
                headerEdit.style.display = 'none';
                headerView.style.display = '';
                refreshDueDisplay();
            });
        }

        if (dueInput) {
            dueInput.addEventListener('change', function () {
                refreshDueDisplay();
                ChickadeeUI.checkUWDates(dueInput.value, document.getElementById('uw-date-warning'));
            });
        }

        // Initialise the due-date display on load
        refreshDueDisplay();
    })();

    // ── Unified suite table (Public/suite-table.js) ─────────────────────────
    var suiteTable = window.initSuiteTable({
        assignmentID: assignmentID,
        csrfToken: csrfToken,
        formSelector: 'form.form',
        urls: {
            putSuite: function () {
                return '/instructor/' + encodeURIComponent(assignmentID) + '/suite';
            },
            deleteScript: function (name) {
                return '/instructor/' + encodeURIComponent(assignmentID)
                     + '/scripts/' + encodeURIComponent(name);
            },
            uploadScript: function () {
                return '/instructor/' + encodeURIComponent(assignmentID) + '/scripts';
            },
            reorderSections: function () {
                return '/instructor/' + encodeURIComponent(assignmentID) + '/suite-sections/reorder';
            }
        }
    });
    // Window globals the Test Editor renderers (family / check / script) call
    // to persist through the single PUT /suite write path.
    window.chickadeeAddExistingSuiteScript = suiteTable.addExistingScript;
    window.chickadeeSaveFamiliesViaSuite   = suiteTable.saveFamiliesViaSuite;
    window.chickadeeSaveChecksViaSuite     = suiteTable.saveChecksViaSuite;
    window.chickadeeSaveScriptViaSuite     = suiteTable.saveScriptViaSuite;
    window.chickadeeGetSuiteItems          = suiteTable.getItems;

    // ── Pattern family editor (Public/pattern-family-editor.js) ─────────────
    (function () {
        var seed = document.getElementById('pattern-families-seed');
        var initialFamilies = [];
        if (seed) {
            try { initialFamilies = JSON.parse(seed.textContent || '[]') || []; }
            catch (e) { initialFamilies = []; }
        }
        window.chickadeePatternFamilyEditor = window.initPatternFamilyEditor({
            assignmentID: assignmentID,
            csrfToken: csrfToken,
            initialFamilies: initialFamilies,
            urls: {
                solutionNotebook: function () {
                    return '/instructor/' + encodeURIComponent(assignmentID) + '/files/solution';
                },
                scanNotebook: function () { return '/instructor/scan-notebook'; },
                computeExpected: function () {
                    return '/instructor/' + encodeURIComponent(assignmentID) + '/compute-expected';
                }
            }
        });
    })();

    // ── Test Editor modal (shell + script renderer config) ──────────────────
    // Edit page: published-assignment script endpoints (test-renderer-script.js
    // reads this lazily at open time).
    window.ChickadeeScriptRendererConfig = {
        csrfToken: csrfToken,
        scriptContentURL: function (name) {
            return '/instructor/' + encodeURIComponent(assignmentID) + '/scripts/' + encodeURIComponent(name);
        },
        uploadFilesInputID: 'suite-files-input'
    };

    var modal = window.initTestEditorModal({ csrfToken: csrfToken });

    // Editing an existing notebook-check row is delegated by the shell itself
    // (test-editor-modal.js).  Editing a SAVED script is an edit-page-only
    // entry point — the create page deliberately does not offer it — so it is
    // wired here rather than in the shell.
    function scriptHint(name) {
        if (typeof window.chickadeeGetSuiteItems !== 'function') return '';
        var m = window.chickadeeGetSuiteItems().find(function (i) {
            return i.kind === 'script' && i.script === name;
        });
        return (m && m.hint) || '';
    }

    document.body.addEventListener('click', function (ev) {
        var t = ev.target;
        var se = t.closest && t.closest('.suite-edit-btn');
        if (!se) return;
        var name = se.getAttribute('data-filename');
        if (name) modal.open({ editing: { mechanism: 'script', id: name, item: { script: name, hint: scriptHint(name) } } });
    });

    // ── Support files (Public/support-files.js) ─────────────────────────────
    window.initSupportFiles({
        csrfToken: csrfToken,
        uploadURL: function () {
            return '/instructor/' + encodeURIComponent(assignmentID) + '/scripts';
        },
        deleteURL: function (name) {
            return '/instructor/' + encodeURIComponent(assignmentID) + '/scripts/' + encodeURIComponent(name);
        },
        onChange: function () { ChickadeeUI.refreshEditSurface(); }
    });

    // ── BrightSpace grade-item picker ───────────────────────────────────────
    // Fetch grade objects from D2L, populate the page's <datalist> with names,
    // and resolve the stored raw ID to a display name (and back on change).
    (function () {
        var nameInput = document.getElementById('edit-bs-grade-name');
        var idInput = document.getElementById('edit-bs-grade-id');
        var datalist = document.getElementById('edit-bs-grade-objects');
        if (!nameInput || !idInput || !datalist) return;

        var rawId = nameInput.dataset.rawId || '';
        idInput.value = rawId;

        fetch('/instructor/brightspace/grade-objects', {
            headers: { 'Accept': 'application/json' }, cache: 'no-store'
        }).then(function (res) { return res.ok ? res.json() : []; })
        .then(function (items) {
            if (!Array.isArray(items)) return;
            var byId = {};
            var byName = {};
            items.forEach(function (it) {
                var label = it.name;
                if (it.gradeType && it.gradeType !== 'Numeric') label += ' — ' + it.gradeType + ' (not supported)';
                byId[String(it.id)] = label;
                byName[label] = String(it.id);
                var opt = document.createElement('option');
                opt.value = label;
                opt.dataset.id = String(it.id);
                datalist.appendChild(opt);
            });
            if (rawId && byId[rawId]) nameInput.value = byId[rawId];
            nameInput.addEventListener('change', function () {
                var val = nameInput.value.trim();
                idInput.value = byName[val] || val;
            });
            nameInput.addEventListener('input', function () {
                var val = nameInput.value.trim();
                if (byName[val]) idInput.value = byName[val];
            });
        }).catch(function () {
            nameInput.addEventListener('change', function () { idInput.value = nameInput.value.trim(); });
        });
    })();
})();
