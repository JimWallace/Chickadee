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
//
// RE-WIRING AFTER A SWAP (#1957).  On the merged workbench, surface-swap.js
// replaces the edit half after each in-place save.  The new markup has no
// running code: a `<script>` that the parser makes does not run, and the CSP
// blocks inline scripts.  So surface-swap.js calls `ChickadeeEditPage.init()`
// after the swap, and `init()` wires the new render.
//
//   * `init()` is idempotent.  A second call on the same render does nothing.
//   * Everything in `init()` binds to elements of one render, which a swap
//     discards.  A listener on `document` or `<body>` survives a swap, so it is
//     bound once per document, outside `init()` — here, or behind a
//     once-per-document guard in the module that owns it.
(function (global) {
    'use strict';

    // The renders that init() has wired.  One render of the edit body carries
    // one `#suite-state-seed`, and a swap brings a new one, so the seed element
    // is the key.  (Not the `[data-assignment-id]` carrier: on the workbench
    // that is `#wb-shell`, which a swap keeps.)  A WeakSet lets a discarded
    // render go.
    var wiredRenders = new WeakSet();

    // The Test Editor modal.  Its shell is built once per document; init()
    // refreshes this reference.
    var modal = null;

    function init() {
        var renderKey = document.getElementById('suite-state-seed');
        if (!renderKey || wiredRenders.has(renderKey)) return;
        wiredRenders.add(renderKey);

        var carrier = document.querySelector('[data-assignment-id]');
        var assignmentID = carrier ? (carrier.getAttribute('data-assignment-id') || '') : '';
        var csrfToken = ChickadeeUI.getCsrfToken();

        wireHeader();
        wireSuiteTable(assignmentID, csrfToken);
        dropParkedFamilyEditorBodies();
        wirePatternFamilyEditor(assignmentID, csrfToken);
        wireTestEditor(assignmentID, csrfToken);
        wireSupportFiles(assignmentID, csrfToken);
        wireSelfStartingEditors();
        wireBrightspacePicker();
    }

    // ── Header view/edit toggle ─────────────────────────────────────────────
    function wireHeader() {
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
            if (isNaN(d.getTime())) return val.replace('T', ' ');
            return 'Due ' + d.toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' })
                + ' at ' + d.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
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

        // Paint the due-date display of this render.
        refreshDueDisplay();
    }

    // ── Unified suite table (Public/suite-table.js) ─────────────────────────
    function wireSuiteTable(assignmentID, csrfToken) {
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
    }

    /// Remove the family-editor bodies that an earlier render left on <body>.
    ///
    /// suite-table.js parks `#family-editor-body` on <body> when an inline
    /// editor closes.  A swap brings a new copy inside the new render, so the
    /// parked one is then a second element with the same id.  The family editor
    /// finds its fields by id, so the parked copies go before it wires.  On a
    /// page with one copy this does nothing.
    function dropParkedFamilyEditorBodies() {
        var bodies = document.querySelectorAll('[id="family-editor-body"]');
        if (bodies.length < 2) return;
        Array.prototype.forEach.call(bodies, function (el) {
            if (el.parentNode === document.body) el.remove();
        });
    }

    // ── Pattern family editor (Public/pattern-family-editor.js) ─────────────
    function wirePatternFamilyEditor(assignmentID, csrfToken) {
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
    }

    // ── Test Editor modal (shell + script renderer config) ──────────────────
    function wireTestEditor(assignmentID, csrfToken) {
        // Edit page: published-assignment script endpoints (test-renderer-script.js
        // reads this lazily at open time).
        window.ChickadeeScriptRendererConfig = {
            csrfToken: csrfToken,
            scriptContentURL: function (name) {
                return '/instructor/' + encodeURIComponent(assignmentID) + '/scripts/' + encodeURIComponent(name);
            },
            uploadFilesInputID: 'suite-files-input'
        };

        // The shell is built on the first call.  A later call keeps it and
        // upgrades the "+ Add Test" buttons of the current render.
        modal = window.initTestEditorModal({ csrfToken: csrfToken });
    }

    // ── Support files (Public/support-files.js) ─────────────────────────────
    function wireSupportFiles(assignmentID, csrfToken) {
        window.initSupportFiles({
            csrfToken: csrfToken,
            uploadURL: function () {
                return '/instructor/' + encodeURIComponent(assignmentID) + '/scripts';
            },
            deleteURL: function (name) {
                return '/instructor/' + encodeURIComponent(assignmentID) + '/scripts/' + encodeURIComponent(name);
            },
            datasetsURL: function () {
                return '/instructor/' + encodeURIComponent(assignmentID) + '/datasets';
            },
            onChange: function () { ChickadeeSurfaceSwap.refreshEditSurface(); }
        });
    }

    // ── The editors that start themselves ───────────────────────────────────
    // section-inputs-editor.js, global-inputs-editor.js and
    // achievements-editor.js wire themselves when the page loads, and the
    // create page relies on that.  After a swap they must wire the new render
    // too, so init() calls them.  Each is idempotent per element, so the call
    // here on the first load and their own start do not wire an element twice.
    function wireSelfStartingEditors() {
        if (typeof window.initSectionInputsEditor === 'function') window.initSectionInputsEditor();
        if (typeof window.initGlobalInputsEditor === 'function') window.initGlobalInputsEditor();
        if (typeof window.initAchievementsEditor === 'function') window.initAchievementsEditor();
    }

    // ── BrightSpace grade-item picker ───────────────────────────────────────
    // Fetch grade objects from D2L, populate the page's <datalist> with names,
    // and resolve the stored raw ID to a display name (and back on change).
    function wireBrightspacePicker() {
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
    }

    // ── Edit a SAVED script (once per document) ─────────────────────────────
    // Editing an existing notebook-check row is delegated by the shell itself
    // (test-editor-modal.js).  Editing a SAVED script is an edit-page-only
    // entry point — the create page deliberately does not offer it — so it is
    // wired here rather than in the shell.  It listens on <body>, which a swap
    // keeps, so it is bound once, after the first init() and not in it: a
    // second listener would open the editor twice for one click.
    function scriptHint(name) {
        if (typeof window.chickadeeGetSuiteItems !== 'function') return '';
        var m = window.chickadeeGetSuiteItems().find(function (i) {
            return i.kind === 'script' && i.script === name;
        });
        return (m && m.hint) || '';
    }

    global.ChickadeeEditPage = { init: init };
    init();

    document.body.addEventListener('click', function (ev) {
        var t = ev.target;
        var se = t.closest && t.closest('.js-suite-edit-btn');
        if (!se || !modal) return;
        var name = se.getAttribute('data-filename');
        if (name) modal.open({ editing: { mechanism: 'script', id: name, item: { script: name, hint: scriptHint(name) } } });
    });
})(window);
