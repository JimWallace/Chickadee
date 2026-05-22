// Chickadee — Test Editor Modal (shell)
//
// One shared modal shell behind the "+ Add Test" button. It owns the chrome
// (overlay, open/close, Escape, overlay-click), the type `<select>` (the
// instructor-facing catalog of test *types* — no script/family/check jargon),
// a color-coded status line, and the generic Save flow. Picking a type morphs
// the body in place — no two-step hop.
//
// The three editors are **body renderers** registered on
// `window.ChickadeeTestRenderers[mechanism]`. Each renderer implements the
// contract:
//
//   mechanism                       'family' | 'check' | 'script'
//   mount(bodyEl, ctx)              build the renderer's DOM into bodyEl once
//   reset(kind, ctx)                clear to defaults for a NEW item of `kind`
//   populate(item, ctx)             fill the form to EDIT an existing item
//   readSpec()                      → spec object; throw Error on validation
//   persistAndSync(spec)            → Promise (writes via PUT /suite)
//   cleanup()                       teardown (kill Pyodide worker, destroy CM)
//   title(isEditing)                → modal title string
//
// All three mechanisms (family / check / script) register a renderer, so every
// test type morphs in this one overlay — there is no hop to a separate editor.
//
// Host page: `window.initTestEditorModal({ csrfToken, getSectionID })`.
// Returns `{ open(opts), close() }` where opts =
//   { mechanism?, kind?, editing?: { mechanism, id, item } }.

(function (global) {
    'use strict';

    // Instructor-facing catalog. `mechanism` selects the renderer; `value` is
    // the underlying PatternKind / NotebookCheckKind ("script" for the raw
    // custom-script flow). Labels stay in the instructor's mental model.
    var CATALOG = [
        {
            group: 'Test a function',
            items: [
                { value: 'boundary_equality',     mechanism: 'family', label: 'Returns the right value' },
                { value: 'approximate_equality',  mechanism: 'family', label: 'Returns the right value (within tolerance)' },
                { value: 'return_type_check',     mechanism: 'family', label: 'Returns the right type' },
                { value: 'exception_expected',    mechanism: 'family', label: 'Raises the right error' },
                { value: 'stdout_equality',       mechanism: 'family', label: 'Prints the right output' },
                { value: 'performance_threshold', mechanism: 'family', label: 'Runs within a time budget' }
            ]
        },
        {
            group: 'Test a value or data structure',
            items: [
                { value: 'variable_exists',     mechanism: 'check',  label: 'Variable is defined' },
                { value: 'variable_equality',   mechanism: 'family', label: 'Variable equals a value' },
                { value: 'function_exists',     mechanism: 'check',  label: 'Function is defined' },
                { value: 'data_frame_shape',    mechanism: 'check',  label: 'DataFrame has the right shape' },
                { value: 'data_frame_columns',  mechanism: 'check',  label: 'DataFrame has the right columns' },
                { value: 'data_frame_equality', mechanism: 'check',  label: 'DataFrame matches expected' },
                { value: 'series_equality',     mechanism: 'check',  label: 'Series matches expected' },
                { value: 'numeric_array_close', mechanism: 'check',  label: 'Array is close to expected' }
            ]
        },
        {
            group: 'Test notebook structure & output',
            items: [
                { value: 'figure_count',  mechanism: 'check', label: 'Produces enough figures' },
                { value: 'cell_contains', mechanism: 'check', label: 'Code contains specific text' },
                { value: 'ast_structure', mechanism: 'check', label: 'Code uses / avoids constructs' }
            ]
        },
        {
            group: 'Custom',
            items: [
                { value: 'script', mechanism: 'script', label: 'Write a custom script' }
            ]
        }
    ];

    var DESCRIPTIONS = {
        boundary_equality:     'Call the student’s function with a table of inputs and check each return value.',
        approximate_equality:  'Like “Returns the right value”, but compares floats within a tolerance.',
        return_type_check:     'Check that the function returns a value of the expected type.',
        exception_expected:    'Check that the function raises the expected exception for given inputs.',
        stdout_equality:       'Check what the function prints to stdout for given inputs.',
        performance_threshold: 'Check that the function completes within a millisecond budget.',
        variable_exists:       'Check that a notebook variable is defined (optionally of a given type).',
        variable_equality:     'Check that a notebook variable equals an expected value.',
        function_exists:       'Check that a function is defined and callable (optionally with a given arity).',
        data_frame_shape:      'Check that a DataFrame has an expected number of rows and columns.',
        data_frame_columns:    'Check that a DataFrame has the expected columns.',
        data_frame_equality:   'Check that a DataFrame matches an expected table.',
        series_equality:       'Check that a Series matches an expected column of values.',
        numeric_array_close:   'Check that a numeric array is element-wise close to an expected array.',
        figure_count:          'Check that the notebook produces at least N matplotlib figures.',
        cell_contains:         'Check that the submission source contains a given substring or regex.',
        ast_structure:         'Check that the code uses (or avoids) constructs like loops, recursion, imports.',
        script:                'Write a raw .py / .sh / .r test script by hand in the code editor.'
    };

    // Status colors — single source so every renderer reports consistently.
    var STATUS_COLORS = {
        info:    'var(--gray-500)',
        working: 'var(--gray-500)',
        success: 'var(--green,#2e7d32)',
        error:   'var(--red,#c0392b)'
    };

    // One deduped error-message extractor (renderers reuse via ctx).
    function extractErrorMessage(text) {
        if (!text) return '';
        try {
            var j = JSON.parse(text);
            return j.reason || j.error || j.message || text;
        } catch (e) {
            return text;
        }
    }

    function mechanismForKind(kind) {
        for (var g = 0; g < CATALOG.length; g++) {
            for (var i = 0; i < CATALOG[g].items.length; i++) {
                if (CATALOG[g].items[i].value === kind) return CATALOG[g].items[i].mechanism;
            }
        }
        return null;
    }

    function escHtml(s) {
        return String(s == null ? '' : s)
            .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    }
    function escAttr(s) { return escHtml(s).replace(/"/g, '&quot;'); }

    function initTestEditorModal(config) {
        config = config || {};
        var csrfToken = config.csrfToken || '';
        // Looked up lazily (not cached): renderers self-register on
        // `window.ChickadeeTestRenderers`, and a `<script type="module">`
        // renderer (CodeMirror imports) registers AFTER this inline init runs.
        // As long as it's registered before the modal is opened, we're fine.
        function rendererFor(mechanism) {
            return (global.ChickadeeTestRenderers || {})[mechanism] || null;
        }
        var getSectionID = typeof config.getSectionID === 'function'
            ? config.getSectionID
            : function () {
                var t = global.__chickadeeTargetSection;
                return (typeof t === 'string' && t) ? t : null;
            };

        if (document.getElementById('test-editor-overlay')) {
            return global.__chickadeeTestEditorModal || { open: function () {}, close: function () {} };
        }

        // ── Build the shell DOM ─────────────────────────────────────────────
        var overlay = document.createElement('div');
        overlay.id = 'test-editor-overlay';
        overlay.setAttribute('role', 'dialog');
        overlay.setAttribute('aria-modal', 'true');
        overlay.style.cssText =
            'display:none;position:fixed;inset:0;z-index:1000;align-items:center;' +
            'justify-content:center;background:rgba(0,0,0,.5)';

        var card = document.createElement('div');
        card.style.cssText =
            'background:var(--surface);color:var(--gray-900);border-radius:.5rem;' +
            'width:min(960px,96vw);max-height:92vh;display:flex;flex-direction:column;' +
            'box-shadow:0 8px 32px rgba(0,0,0,.25)';

        var optionsHTML = CATALOG.map(function (g) {
            var opts = g.items.map(function (it) {
                return '<option value="' + escAttr(it.value) + '" data-mechanism="' +
                    escAttr(it.mechanism) + '">' + escHtml(it.label) + '</option>';
            }).join('');
            return '<optgroup label="' + escAttr(g.group) + '">' + opts + '</optgroup>';
        }).join('');

        card.innerHTML =
            '<div style="display:flex;align-items:center;gap:.75rem;padding:.75rem 1rem;border-bottom:1px solid var(--border,#ddd);flex-shrink:0">' +
            '  <div id="test-editor-title" style="font-weight:600;flex:1">Add Test</div>' +
            '  <button type="button" id="test-editor-close" class="btn-link" aria-label="Close" title="Close" style="font-size:1.1rem;color:var(--gray-500);padding:.1rem .3rem">✕</button>' +
            '</div>' +
            '<div style="padding:.75rem 1rem;overflow:auto;flex:1;display:flex;flex-direction:column;gap:.6rem">' +
            '  <label id="test-editor-type-row" style="font-size:.85rem;display:flex;flex-direction:column;gap:.2rem">' +
            '    What do you want to test?' +
            '    <select class="form-input" id="test-editor-type" style="padding:.3rem .5rem;font-size:.85rem">' + optionsHTML + '</select>' +
            '    <span id="test-editor-desc" class="card-meta" style="font-size:.78rem;line-height:1.3;min-height:1.2em"></span>' +
            '  </label>' +
            '  <div id="test-editor-body" style="display:flex;flex-direction:column;gap:.6rem"></div>' +
            '</div>' +
            '<div style="display:flex;align-items:center;gap:.6rem;padding:.75rem 1rem;border-top:1px solid var(--border,#ddd);flex-shrink:0">' +
            '  <button class="btn btn-primary" id="test-editor-save" type="button">Save</button>' +
            '  <button class="btn" id="test-editor-cancel" type="button">Cancel</button>' +
            '  <span id="test-editor-status" style="font-size:.8rem;color:var(--gray-500);margin-left:.5rem"></span>' +
            '</div>';

        overlay.appendChild(card);
        document.body.appendChild(overlay);

        var typeSelect = document.getElementById('test-editor-type');
        var typeRow    = document.getElementById('test-editor-type-row');
        var descEl     = document.getElementById('test-editor-desc');
        var titleEl    = document.getElementById('test-editor-title');
        var bodyEl     = document.getElementById('test-editor-body');
        var statusEl   = document.getElementById('test-editor-status');
        var saveBtn    = document.getElementById('test-editor-save');
        var cancelBtn  = document.getElementById('test-editor-cancel');
        var closeBtn   = document.getElementById('test-editor-close');

        function setStatus(text, kind) {
            statusEl.textContent = text || '';
            statusEl.style.color = STATUS_COLORS[kind || 'info'] || STATUS_COLORS.info;
        }

        // Shared context handed to every renderer.
        var ctx = {
            csrfToken: csrfToken,
            extractErrorMessage: extractErrorMessage,
            setStatus: setStatus,
            getSectionID: getSectionID
        };

        // Per-mechanism body container + "mounted" flag (renderers build once).
        var panels = {};
        function panelFor(mechanism) {
            if (panels[mechanism]) return panels[mechanism];
            var el = document.createElement('div');
            el.setAttribute('data-mechanism', mechanism);
            el.style.display = 'none';
            bodyEl.appendChild(el);
            panels[mechanism] = { el: el, mounted: false };
            return panels[mechanism];
        }

        var activeMechanism = null;
        var activeRenderer = null;
        var editingItem = null;   // { mechanism, id, item } when editing

        function showPanel(mechanism) {
            Object.keys(panels).forEach(function (m) {
                panels[m].el.style.display = (m === mechanism) ? 'flex' : 'none';
                panels[m].el.style.flexDirection = 'column';
                panels[m].el.style.gap = '.6rem';
            });
        }

        // Enter the mode for `mechanism`/`kind`: tear down any previously-active
        // renderer, then morph the body in place with the selected renderer.
        function enterMode(mechanism, kind) {
            if (activeRenderer && typeof activeRenderer.cleanup === 'function') {
                try { activeRenderer.cleanup(); } catch (e) { /* ignore */ }
            }
            activeMechanism = mechanism;
            var r = rendererFor(mechanism);
            activeRenderer = r || null;
            if (!r) {
                // No renderer registered (a renderer module failed to load) —
                // show a clear message instead of a blank body.
                Object.keys(panels).forEach(function (m) { panels[m].el.style.display = 'none'; });
                setStatus('This test type is unavailable — reload the page.', 'error');
                return;
            }
            var panel = panelFor(mechanism);
            if (!panel.mounted) { r.mount(panel.el, ctx); panel.mounted = true; }
            showPanel(mechanism);
            titleEl.textContent = r.title ? r.title(!!editingItem) : 'Add Test';
            if (editingItem && editingItem.mechanism === mechanism) {
                r.populate(editingItem.item, ctx);
            } else {
                r.reset(kind, ctx);
            }
        }

        function refreshDescription() {
            descEl.textContent = DESCRIPTIONS[typeSelect.value] || '';
        }

        // ── Open / close ─────────────────────────────────────────────────────
        function open(opts) {
            opts = opts || {};
            editingItem = opts.editing || null;
            var kind = opts.kind || (editingItem && editingItem.kind) || typeSelect.value;
            var mechanism = opts.mechanism || mechanismForKind(kind) || 'script';

            // Editing fixes the type; creating lets the instructor switch it.
            typeRow.style.display = editingItem ? 'none' : 'flex';
            setStatus('', 'info');
            if (typeSelect.value !== kind) typeSelect.value = kind;
            refreshDescription();
            enterMode(mechanism, kind);
            overlay.style.display = 'flex';
            setTimeout(function () { if (!editingItem) typeSelect.focus(); }, 0);
        }

        function close() {
            overlay.style.display = 'none';
            if (activeRenderer && typeof activeRenderer.cleanup === 'function') {
                try { activeRenderer.cleanup(); } catch (e) { /* ignore */ }
            }
            editingItem = null;
        }

        // ── Type switch ────────────────────────────────────────────────────
        typeSelect.addEventListener('change', function () {
            refreshDescription();
            setStatus('', 'info');
            var kind = typeSelect.value;
            enterMode(mechanismForKind(kind) || 'script', kind);
        });

        // ── Save ─────────────────────────────────────────────────────────────
        saveBtn.addEventListener('click', function () {
            if (!activeRenderer) return;
            var spec;
            try {
                spec = activeRenderer.readSpec();
            } catch (e) {
                setStatus(e && e.message ? e.message : String(e), 'error');
                return;
            }
            setStatus('Saving…', 'working');
            saveBtn.disabled = true;
            activeRenderer.persistAndSync(spec)
                .then(function () { setStatus('Saved.', 'success'); setTimeout(close, 300); })
                .catch(function (err) {
                    setStatus('Save failed — ' + (err && err.message ? err.message : err), 'error');
                })
                .finally(function () { saveBtn.disabled = false; });
        });

        cancelBtn.addEventListener('click', close);
        closeBtn.addEventListener('click', close);
        overlay.addEventListener('click', function (e) { if (e.target === overlay) close(); });
        document.addEventListener('keydown', function (e) {
            if (e.key === 'Escape' && overlay.style.display !== 'none') close();
        });

        // Per-section "+ Add Test" buttons (body-level delegation, same flag
        // the legacy dispatcher used so downstream placement is unchanged).
        document.body.addEventListener('click', function (e) {
            var btn = e.target && e.target.closest && e.target.closest('.section-add-test-btn');
            if (!btn) return;
            e.preventDefault();
            var sid = btn.getAttribute('data-section-id') || '';
            global.__chickadeeTargetSection = sid || null;
            open({});
        });

        var api = { open: open, close: close };
        global.__chickadeeTestEditorModal = api;
        return api;
    }

    global.initTestEditorModal = initTestEditorModal;
    global.ChickadeeTestEditorCatalog = CATALOG;   // exposed for renderers/tests
})(typeof window !== 'undefined' ? window : globalThis);
