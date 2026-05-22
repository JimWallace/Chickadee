// Chickadee — Notebook Check Editor
//
// Browser-side module that drives the notebook-check modal on the
// instructor assignment editor.  Sibling to pattern-family-editor.js;
// each NotebookCheck expands at save time into a single generated test
// script (and optionally a sidecar `_expected_<id>.csv` for the
// DataFrame/Series equality kinds), so the modal needs no cases table
// — it's one form per check.
//
// The modal HTML lives in assignment-edit.leaf with stable DOM ids
// (`check-editor-overlay`, `check-id`, `check-name`, `check-kind`, etc.,
// plus per-kind field cards under `.check-fields[data-kind=...]`).
// This module owns every event listener, fetch, and piece of state
// hung off those ids.
//
// Host page wires the module via:
//
//   window.initNotebookCheckEditor({
//       assignmentID: 'TWTFKZ',
//       csrfToken: '<token>',
//       initialChecks: [...],         // parsed notebook-checks-seed JSON
//       urls: {
//           getChecks: function () {...},
//           putChecks: function () {...}
//       },
//       onChecksChange: function (applied) {} // suite-table sync hook
//   })
//
// Returns `{ open(idOrNull, sectionID), close(), getChecks() }`.

(function (global) {
    'use strict';

    function initNotebookCheckEditor(config) {
        config = config || {};
        var csrfToken = config.csrfToken || '';
        var urls = config.urls || {};
        var onChecksChange = typeof config.onChecksChange === 'function'
            ? config.onChecksChange
            : function () {};

        if (typeof urls.putChecks !== 'function') {
            throw new Error('initNotebookCheckEditor: urls.putChecks must be a function');
        }

        // ── State ──────────────────────────────────────────────────────────
        var checksState = Array.isArray(config.initialChecks)
            ? config.initialChecks.slice()
            : [];
        var editingID = null;       // nil for new check; check.id for edit
        var editingSectionID = null;

        // ── DOM lookups ────────────────────────────────────────────────────
        var $ = function (id) { return document.getElementById(id); };
        var overlay  = $('check-editor-overlay');
        var titleEl  = $('check-editor-title');
        var statusEl = $('check-editor-status');
        var idInput  = $('check-id');
        var sectionIDInput = $('check-section-id');
        var nameInput   = $('check-name');
        var kindSelect  = $('check-kind');
        var saveBtn   = $('check-save-btn');
        var cancelBtn = $('check-cancel-btn');
        var deleteBtn = $('check-delete-btn');
        var closeBtn  = $('check-editor-close');
        var fieldGroups = document.querySelectorAll('.check-fields');

        if (!overlay || !kindSelect || !saveBtn) {
            // Modal markup absent — host page must have it.  Bail silently
            // so callers in other contexts (preview, drafts) don't blow up.
            return {
                open: function () {},
                close: function () {},
                getChecks: function () { return checksState.slice(); }
            };
        }

        // ── Show/hide kind-specific fields ─────────────────────────────────
        function showFieldsForKind(kind) {
            for (var i = 0; i < fieldGroups.length; i++) {
                var g = fieldGroups[i];
                g.style.display = (g.dataset.kind === kind) ? 'flex' : 'none';
            }
        }

        kindSelect.addEventListener('change', function () {
            showFieldsForKind(kindSelect.value);
        });

        // ── Open / close ───────────────────────────────────────────────────
        // `presetKind` (optional) seeds the kind dropdown for a brand-new
        // check — used by the unified "+ Add Test" dispatcher so the
        // instructor lands directly on the right per-kind fields.  Ignored
        // when editing an existing check (its own kind wins).
        function open(checkID, sectionID, presetKind) {
            editingID = checkID || null;
            editingSectionID = sectionID || null;
            statusEl.textContent = '';
            sectionIDInput.value = editingSectionID || '';

            if (editingID) {
                var existing = checksState.find(function (c) { return c.id === editingID; });
                if (existing) {
                    populateForm(existing);
                    titleEl.textContent = 'Edit Notebook Check';
                    deleteBtn.style.display = 'inline-block';
                } else {
                    // ID supplied but no match — fall back to new
                    editingID = null;
                    resetForm();
                    titleEl.textContent = 'New Notebook Check';
                    deleteBtn.style.display = 'none';
                }
            } else {
                resetForm();
                titleEl.textContent = 'New Notebook Check';
                deleteBtn.style.display = 'none';
            }

            if (!editingID && presetKind) {
                kindSelect.value = presetKind;
                showFieldsForKind(kindSelect.value);
            }

            overlay.style.display = 'flex';
            // Focus the kind dropdown for keyboard users; the most common
            // first action on a new check is picking the kind.
            setTimeout(function () { kindSelect.focus(); }, 0);
        }

        function close() {
            overlay.style.display = 'none';
            editingID = null;
            editingSectionID = null;
        }

        cancelBtn.addEventListener('click', close);
        closeBtn.addEventListener('click', close);
        overlay.addEventListener('click', function (ev) {
            if (ev.target === overlay) close();
        });

        // ── Form helpers ───────────────────────────────────────────────────
        function resetForm() {
            idInput.value = '';
            nameInput.value = '';
            kindSelect.value = 'data_frame_shape';
            // Clear all kind-specific fields
            $('check-shape-variable').value = '';
            $('check-shape-rows').value = '';
            $('check-shape-cols').value = '';
            $('check-columns-variable').value = '';
            $('check-columns-list').value = '';
            var exactRadio = document.querySelector('input[name="check-columns-match"][value="exact"]');
            if (exactRadio) exactRadio.checked = true;
            $('check-eq-variable').value = '';
            $('check-eq-csv').value = '';
            $('check-eq-check-dtype').checked = true;
            $('check-eq-check-like').checked = false;
            $('check-eq-ignore-index').checked = true;
            $('check-eq-rtol').value = '';
            $('check-eq-atol').value = '';
            $('check-series-variable').value = '';
            $('check-series-csv').value = '';
            $('check-array-variable').value = '';
            $('check-array-values').value = '';
            $('check-array-rtol').value = '';
            $('check-array-atol').value = '';
            $('check-fig-min').value = '1';
            $('check-cc-text').value = '';
            $('check-cc-regex').checked = false;
            $('check-cc-must-differ').value = '';
            $('check-fexists-name').value = '';
            $('check-fexists-arity').value = '';
            $('check-vexists-name').value = '';
            $('check-vexists-type').value = '';
            $('check-ast-constructs').value = '';
            showFieldsForKind('data_frame_shape');
        }

        function populateForm(c) {
            idInput.value = c.id || '';
            nameInput.value = c.name || '';
            kindSelect.value = c.kind || 'data_frame_shape';

            if (c.kind === 'data_frame_shape') {
                $('check-shape-variable').value = c.variable || '';
                $('check-shape-rows').value = (c.expectedRows != null) ? c.expectedRows : '';
                $('check-shape-cols').value = (c.expectedCols != null) ? c.expectedCols : '';
            } else if (c.kind === 'data_frame_columns') {
                $('check-columns-variable').value = c.variable || '';
                $('check-columns-list').value = (c.expectedColumns || []).join('\n');
                var radio = document.querySelector(
                    'input[name="check-columns-match"][value="' + (c.columnMatch || 'exact') + '"]'
                );
                if (radio) radio.checked = true;
            } else if (c.kind === 'data_frame_equality') {
                $('check-eq-variable').value = c.variable || '';
                $('check-eq-csv').value = c.expectedCSV || '';
                $('check-eq-check-dtype').checked = (c.checkDtype !== false);
                $('check-eq-check-like').checked = (c.checkLike === true);
                $('check-eq-ignore-index').checked = (c.ignoreIndex !== false);
                $('check-eq-rtol').value = (c.rtol != null) ? c.rtol : '';
                $('check-eq-atol').value = (c.atol != null) ? c.atol : '';
            } else if (c.kind === 'series_equality') {
                $('check-series-variable').value = c.variable || '';
                $('check-series-csv').value = c.expectedCSV || '';
            } else if (c.kind === 'numeric_array_close') {
                $('check-array-variable').value = c.variable || '';
                $('check-array-values').value = (c.expectedArray || []).join('\n');
                $('check-array-rtol').value = (c.rtol != null) ? c.rtol : '';
                $('check-array-atol').value = (c.atol != null) ? c.atol : '';
            } else if (c.kind === 'figure_count') {
                $('check-fig-min').value = (c.minFigures != null) ? c.minFigures : '1';
            } else if (c.kind === 'cell_contains') {
                $('check-cc-text').value = c.containsText || '';
                $('check-cc-regex').checked = (c.regex === true);
                $('check-cc-must-differ').value = c.mustDifferFrom || '';
            } else if (c.kind === 'function_exists') {
                $('check-fexists-name').value = c.variable || '';
                $('check-fexists-arity').value = (c.expectedArity != null) ? c.expectedArity : '';
            } else if (c.kind === 'variable_exists') {
                $('check-vexists-name').value = c.variable || '';
                $('check-vexists-type').value = c.expectedType || '';
            } else if (c.kind === 'ast_structure') {
                $('check-ast-constructs').value = (c.requiredConstructs || []).join('\n');
            }
            showFieldsForKind(c.kind);
        }

        // ── Build a NotebookCheck object from the form state ───────────────
        function buildCheckFromForm() {
            var kind = kindSelect.value;
            var rawName = (nameInput.value || '').trim();
            var rawID = (idInput.value || '').trim();
            var id = rawID || generateID(kind, rawName);
            var sectionID = sectionIDInput.value || null;

            // Preserve tier / points / dependsOn from the existing check
            // when editing, so inline edits on the suite-table row aren't
            // clobbered by the modal save.  New checks default to
            // public / 1 / no deps; the instructor tunes from the inline
            // row afterwards (same model as scripts and pattern families).
            var existing = editingID
                ? checksState.find(function (c) { return c.id === editingID; })
                : null;

            var c = {
                id: id,
                kind: kind,
                tier: (existing && existing.tier) || 'public',
                points: (existing && existing.points != null) ? existing.points : 1,
                dependsOn: (existing && existing.dependsOn) || []
            };
            if (rawName) c.name = rawName;
            if (sectionID) c.sectionID = sectionID;

            if (kind === 'data_frame_shape') {
                c.variable = $('check-shape-variable').value.trim();
                c.expectedRows = parseInt($('check-shape-rows').value, 10);
                c.expectedCols = parseInt($('check-shape-cols').value, 10);
            } else if (kind === 'data_frame_columns') {
                c.variable = $('check-columns-variable').value.trim();
                c.expectedColumns = $('check-columns-list').value
                    .split('\n').map(function (s) { return s.trim(); })
                    .filter(function (s) { return s.length > 0; });
                var match = document.querySelector('input[name="check-columns-match"]:checked');
                c.columnMatch = match ? match.value : 'exact';
            } else if (kind === 'data_frame_equality') {
                c.variable = $('check-eq-variable').value.trim();
                c.expectedCSV = $('check-eq-csv').value;
                c.checkDtype = $('check-eq-check-dtype').checked;
                c.checkLike = $('check-eq-check-like').checked;
                c.ignoreIndex = $('check-eq-ignore-index').checked;
                var rtol = parseFloat($('check-eq-rtol').value);
                var atol = parseFloat($('check-eq-atol').value);
                if (!isNaN(rtol)) c.rtol = rtol;
                if (!isNaN(atol)) c.atol = atol;
            } else if (kind === 'series_equality') {
                c.variable = $('check-series-variable').value.trim();
                c.expectedCSV = $('check-series-csv').value;
            } else if (kind === 'numeric_array_close') {
                c.variable = $('check-array-variable').value.trim();
                var raw = $('check-array-values').value.trim();
                var values;
                if (raw.startsWith('[')) {
                    try { values = JSON.parse(raw); }
                    catch (e) { throw new Error('Expected array isn\'t valid JSON: ' + e.message); }
                } else {
                    values = raw.split('\n').map(function (s) { return s.trim(); })
                                .filter(function (s) { return s.length > 0; })
                                .map(function (s) {
                                    var n = parseFloat(s);
                                    if (isNaN(n)) throw new Error('Expected array contains a non-number: "' + s + '"');
                                    return n;
                                });
                }
                c.expectedArray = values;
                var arrRtol = parseFloat($('check-array-rtol').value);
                var arrAtol = parseFloat($('check-array-atol').value);
                if (!isNaN(arrRtol)) c.rtol = arrRtol;
                if (!isNaN(arrAtol)) c.atol = arrAtol;
            } else if (kind === 'figure_count') {
                c.minFigures = parseInt($('check-fig-min').value, 10);
            } else if (kind === 'cell_contains') {
                c.containsText = $('check-cc-text').value;
                c.regex = $('check-cc-regex').checked;
                var mustDiffer = $('check-cc-must-differ').value;
                if (mustDiffer.trim()) c.mustDifferFrom = mustDiffer;
            } else if (kind === 'function_exists') {
                c.variable = $('check-fexists-name').value.trim();
                var arityRaw = $('check-fexists-arity').value.trim();
                if (arityRaw !== '') {
                    var arity = parseInt(arityRaw, 10);
                    if (!isNaN(arity)) c.expectedArity = arity;
                }
            } else if (kind === 'variable_exists') {
                c.variable = $('check-vexists-name').value.trim();
                var typeRaw = $('check-vexists-type').value.trim();
                if (typeRaw !== '') c.expectedType = typeRaw;
            } else if (kind === 'ast_structure') {
                c.requiredConstructs = $('check-ast-constructs').value
                    .split('\n')
                    .map(function (s) { return s.trim(); })
                    .filter(function (s) { return s.length > 0; });
            }
            return c;
        }

        function generateID(kind, name) {
            // Slug from the user's name, or fall back to the kind.  Tail
            // a short timestamp so re-saving without renaming doesn't
            // collide.  Validation server-side enforces uniqueness.
            var base = (name || kind || 'check')
                .toLowerCase()
                .replace(/[^a-z0-9_]+/g, '_')
                .replace(/^_+|_+$/g, '')
                .slice(0, 32) || kind;
            return base + '_' + Date.now().toString(36).slice(-4);
        }

        // ── Save ───────────────────────────────────────────────────────────
        /// Persists the full check list. Phase 2a (v0.4.223) routes this
        /// through the single `PUT /suite` write path when the suite-table
        /// exposes the save hook (the table re-seeds itself, so no
        /// onChecksChange sync is needed and the pre-2a `PUT /checks` +
        /// follow-up `PUT /suite` double-write / page reload is gone). Falls
        /// back to the legacy `PUT /checks` + onChecksChange otherwise.
        async function persistChecks(nextChecks) {
            if (typeof window.chickadeeSaveChecksViaSuite === 'function') {
                checksState = await window.chickadeeSaveChecksViaSuite(nextChecks);
                return checksState;
            }
            var resp = await fetch(urls.putChecks(), {
                method: 'PUT',
                headers: {
                    'Content-Type': 'application/json',
                    'x-csrf-token': csrfToken
                },
                credentials: 'same-origin',
                body: JSON.stringify(nextChecks)
            });
            if (!resp.ok) {
                var bodyText = await resp.text();
                throw new Error(resp.status + ' ' + resp.statusText + ': ' + bodyText);
            }
            checksState = await resp.json();
            onChecksChange(checksState);
            return checksState;
        }

        async function save() {
            statusEl.textContent = 'Saving…';
            statusEl.style.color = 'var(--gray-500)';

            var built;
            try {
                built = buildCheckFromForm();
            } catch (e) {
                statusEl.textContent = e.message;
                statusEl.style.color = 'var(--red,#c0392b)';
                return;
            }

            // Splice into the in-memory list: replace if editing, append if new.
            var nextChecks = checksState.slice();
            if (editingID) {
                var idx = nextChecks.findIndex(function (c) { return c.id === editingID; });
                if (idx >= 0) nextChecks[idx] = built;
                else nextChecks.push(built);
            } else {
                // New check — guard against id collision with an existing one.
                if (nextChecks.some(function (c) { return c.id === built.id; })) {
                    statusEl.textContent = 'A check with id "' + built.id + '" already exists. Pick a different name.';
                    statusEl.style.color = 'var(--red,#c0392b)';
                    return;
                }
                nextChecks.push(built);
            }

            try {
                await persistChecks(nextChecks);
                statusEl.textContent = 'Saved.';
                statusEl.style.color = 'var(--green,#2e7d32)';
                setTimeout(close, 400);
            } catch (e) {
                statusEl.textContent = 'Save failed — ' + e.message;
                statusEl.style.color = 'var(--red,#c0392b)';
            }
        }

        saveBtn.addEventListener('click', save);

        // ── Delete ─────────────────────────────────────────────────────────
        async function deleteCheck() {
            if (!editingID) return;
            if (!confirm('Delete this notebook check?  This is permanent.')) return;
            statusEl.textContent = 'Deleting…';
            var nextChecks = checksState.filter(function (c) { return c.id !== editingID; });
            try {
                await persistChecks(nextChecks);
                close();
            } catch (e) {
                statusEl.textContent = 'Delete failed — ' + e.message;
                statusEl.style.color = 'var(--red,#c0392b)';
            }
        }

        deleteBtn.addEventListener('click', deleteCheck);

        return {
            open: open,
            close: close,
            getChecks: function () { return checksState.slice(); }
        };
    }

    global.initNotebookCheckEditor = initNotebookCheckEditor;

})(typeof window !== 'undefined' ? window : globalThis);
