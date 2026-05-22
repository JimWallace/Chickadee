// Chickadee — Custom-script body renderer for the unified Test Editor modal.
//
// ES module (CodeMirror 6 imports) registering `window.ChickadeeTestRenderers
// .script`. The shell (test-editor-modal.js) owns the chrome, the type
// `<select>`, the status line, and the Save button; this renderer owns the
// filename / template controls, the CodeMirror editor, and the per-script hint
// field. Replaces the inline `#script-editor-overlay` editor on both the edit
// and new-assignment pages.
//
// Per-page config is read lazily from `window.ChickadeeScriptRendererConfig`:
//   csrfToken          string
//   scriptContentURL   function(name) -> URL  (edit-existing fetch; null if the
//                                              page can't edit saved scripts)
//   uploadFilesInputID string | null          (id of the <input type=file> for
//                                              editing not-yet-saved uploads)
//
// Persistence (create + content/hint edit) flows through the single PUT /suite
// path via `window.chickadeeSaveScriptViaSuite`. Editing a queued-but-unsaved
// upload writes the new body back into the file <input> client-side instead.

import {
    EditorView, keymap, lineNumbers, highlightActiveLine,
    drawSelection, dropCursor,
    EditorState, Compartment,
    defaultKeymap, history, historyKeymap, indentWithTab,
    syntaxHighlighting, defaultHighlightStyle, StreamLanguage,
    python, shell, r
} from '/vendor/codemirror.js';

(function (global) {
    'use strict';

    var TEMPLATE_OPTIONS = [
        { group: 'Python', items: [
            { value: 'py:exists', label: 'Function Exists' },
            { value: 'py:correctness', label: 'Correctness (input/output pairs)' },
            { value: 'py:corner_cases', label: 'Corner Cases' },
            { value: 'py:exception', label: 'Exception Handling' },
            { value: 'py:type_check', label: 'Return Type Check' },
            { value: 'py:performance', label: 'Performance / Runtime' },
            { value: 'py:differential', label: 'Differential (reference solution)' },
            { value: 'py:variable_equality', label: 'Variable Equality' },
            { value: 'py:structural_check', label: 'Structural Check (AST properties)' }
        ] },
        { group: 'Shell', items: [
            { value: 'sh:always_pass', label: 'Always Pass (placeholder)' },
            { value: 'sh:file_exists', label: 'File Exists Check' },
            { value: 'sh:command_output', label: 'Command Output Check' }
        ] }
    ];

    function cfg() { return global.ChickadeeScriptRendererConfig || {}; }

    var langComp = new Compartment();
    function langExtensionFor(filename) {
        var ext = (filename || '').split('.').pop().toLowerCase();
        if (ext === 'py') return python();
        if (ext === 'r') return StreamLanguage.define(r);
        return StreamLanguage.define(shell);
    }
    function makeEditorState(content, filename) {
        return EditorState.create({
            doc: content,
            extensions: [
                lineNumbers(), highlightActiveLine(), drawSelection(), dropCursor(),
                history(), syntaxHighlighting(defaultHighlightStyle),
                keymap.of(defaultKeymap.concat(historyKeymap, [indentWithTab])),
                langComp.of(langExtensionFor(filename)),
                EditorView.lineWrapping,
                EditorView.theme({ '&': { height: '100%' } })
            ]
        });
    }

    function el(tag, attrs, style) {
        var node = document.createElement(tag);
        if (attrs) for (var k in attrs) if (Object.prototype.hasOwnProperty.call(attrs, k)) node.setAttribute(k, attrs[k]);
        if (style) node.style.cssText = style;
        return node;
    }

    // ── Renderer state ───────────────────────────────────────────────────────
    var newControls = null;   // filename + template row (shown only for create)
    var nameInput = null;
    var templateSel = null;
    var applyBtn = null;
    var cmMount = null;
    var hintInput = null;

    var view = null;
    var mode = 'create';      // 'create' | 'edit' | 'uploadEdit'
    var currentFilename = null;
    var uploadEditName = null;
    var templateCache = null;
    var statusFn = function () {};

    function destroyView() { if (view) { try { view.destroy(); } catch (e) { /* ignore */ } view = null; } }
    function freshView(content, filename) {
        destroyView();
        try { view = new EditorView({ state: makeEditorState(content, filename), parent: cmMount }); }
        catch (e) { statusFn('Editor failed to load: ' + e.message, 'error'); }
    }
    function docText() { return view ? view.state.doc.toString() : ''; }

    function fetchTemplates() {
        if (templateCache) return Promise.resolve(templateCache);
        return fetch('/instructor/script-templates', { headers: { 'x-csrf-token': cfg().csrfToken || '' } })
            .then(function (r) { return r.ok ? r.json() : Promise.reject(r.status); })
            .then(function (data) { templateCache = data; return data; });
    }

    var renderer = {
        mechanism: 'script',
        title: function (isEditing) { return isEditing ? 'Edit Test Script' : 'Add Test'; },

        mount: function (bodyEl, ctx) {
            statusFn = (ctx && ctx.setStatus) || function () {};

            // Filename + template controls (create only).
            newControls = el('div', null, 'display:flex;flex-direction:column;gap:.5rem');
            var nameLabel = el('label', null, 'font-size:.85rem;display:flex;flex-direction:column;gap:.2rem');
            nameLabel.appendChild(document.createTextNode('Filename'));
            nameInput = el('input', { type: 'text', 'class': 'form-input', placeholder: 'e.g. test_correctness.py' }, 'padding:.3rem .5rem;font-size:.85rem');
            nameLabel.appendChild(nameInput);
            newControls.appendChild(nameLabel);

            var tplRow = el('div', null, 'display:flex;align-items:center;gap:.5rem;flex-wrap:wrap');
            var tplCaption = el('span', null, 'font-size:.8rem;color:var(--gray-500)');
            tplCaption.textContent = 'Template:';
            tplRow.appendChild(tplCaption);
            templateSel = el('select', { 'class': 'form-input' }, 'padding:.25rem .5rem;font-size:.8rem;max-width:28rem');
            TEMPLATE_OPTIONS.forEach(function (g) {
                var og = el('optgroup', { label: g.group });
                g.items.forEach(function (it) { var o = el('option', { value: it.value }); o.textContent = it.label; og.appendChild(o); });
                templateSel.appendChild(og);
            });
            var blank = el('option', { value: 'blank' }); blank.textContent = 'Blank'; templateSel.appendChild(blank);
            tplRow.appendChild(templateSel);
            applyBtn = el('button', { type: 'button', 'class': 'btn' }, 'padding:.2rem .6rem;font-size:.8rem');
            applyBtn.textContent = 'Apply';
            tplRow.appendChild(applyBtn);
            newControls.appendChild(tplRow);
            bodyEl.appendChild(newControls);

            // CodeMirror mount.
            cmMount = el('div', { id: 'cm-editor-mount' }, 'min-height:240px;border:1px solid var(--border,#ddd);border-radius:.3rem;overflow:auto;font-size:.875rem');
            bodyEl.appendChild(cmMount);

            // Hint (shown to students on failure) — visible in all modes.
            var hintLabel = el('label', null, 'font-size:.8rem;display:flex;flex-direction:column;gap:.2rem');
            hintLabel.appendChild(document.createTextNode('Hint (optional — shown to students when this test fails)'));
            hintInput = el('input', { type: 'text', 'class': 'form-input', placeholder: 'e.g. Re-read the function’s docstring for the expected return type.' }, 'padding:.25rem .5rem;font-size:.85rem');
            hintLabel.appendChild(hintInput);
            bodyEl.appendChild(hintLabel);

            // Keep the filename extension in sync with the chosen template lang.
            templateSel.addEventListener('change', function () {
                var lang = (templateSel.value || '').split(':')[0];
                var name = (nameInput.value || '').trim();
                if (!name) return;
                var stem = name.replace(/\.[^.]*$/, '');
                if (lang === 'py') nameInput.value = stem + '.py';
                if (lang === 'sh') nameInput.value = stem + '.sh';
            });
            applyBtn.addEventListener('click', function () {
                var tplKey = templateSel ? templateSel.value : 'blank';
                var apply = function (content) {
                    if (!nameInput.value.trim()) {
                        var lang = (tplKey || '').split(':')[0];
                        nameInput.value = 'test_new.' + (lang === 'sh' ? 'sh' : 'py');
                    }
                    if (view) {
                        view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: content } });
                        view.dispatch({ effects: langComp.reconfigure(langExtensionFor(nameInput.value)) });
                        view.focus();
                    }
                };
                if (tplKey === 'blank') { apply(''); return; }
                fetchTemplates()
                    .then(function (t) { apply(t[tplKey] || ''); })
                    .catch(function (err) { statusFn('Could not load template: ' + err, 'error'); });
            });
        },

        reset: function (/* kind, ctx */) {
            mode = 'create';
            currentFilename = null;
            uploadEditName = null;
            if (newControls) newControls.style.display = 'flex';
            if (nameInput) { nameInput.value = ''; }
            if (hintInput) hintInput.value = '';
            freshView('', '');
            setTimeout(function () { if (nameInput) nameInput.focus(); }, 0);
        },

        populate: function (item /*, ctx */) {
            if (item && item.uploadEdit) {
                // Editing a queued-but-unsaved upload (client-side only).
                mode = 'uploadEdit';
                uploadEditName = item.name;
                currentFilename = item.name;
                if (newControls) newControls.style.display = 'none';
                if (hintInput) hintInput.value = '';
                freshView(item.content || '', item.name || '');
                return;
            }
            // Editing an existing saved script — body fetched from the server.
            mode = 'edit';
            currentFilename = item.script || item.id || '';
            if (newControls) newControls.style.display = 'none';
            if (hintInput) hintInput.value = item.hint || '';
            freshView('Loading…', currentFilename);
            var urlFn = cfg().scriptContentURL;
            if (typeof urlFn === 'function') {
                fetch(urlFn(currentFilename), { headers: { 'x-csrf-token': cfg().csrfToken || '' } })
                    .then(function (r) { return r.ok ? r.text() : r.text().then(function (t) { return Promise.reject(t); }); })
                    .then(function (content) { freshView(content, currentFilename); })
                    .catch(function (err) { statusFn('Could not load script: ' + err, 'error'); });
            }
        },

        readSpec: function () {
            var content = docText();
            var hint = hintInput ? hintInput.value.trim() : '';
            if (mode === 'uploadEdit') {
                return { uploadEdit: true, name: uploadEditName, content: content };
            }
            if (mode === 'edit') {
                if (!currentFilename) throw new Error('No script selected.');
                return { filename: currentFilename, content: content, hint: hint };
            }
            // create
            var filename = (nameInput.value || '').trim();
            if (!filename) throw new Error('Enter a filename first.');
            return { filename: filename, content: content, hint: hint, tier: 'public', points: 1, isTest: true };
        },

        persistAndSync: function (spec) {
            if (spec.uploadEdit) {
                // Write the edited body back into the upload file <input>.
                var inputID = cfg().uploadFilesInputID;
                var input = inputID ? document.getElementById(inputID) : null;
                if (!input) return Promise.reject(new Error('Upload input not found.'));
                try {
                    var updated = new File([spec.content], spec.name, { type: 'text/plain' });
                    var dt = new DataTransfer();
                    Array.from(input.files || []).forEach(function (f) { dt.items.add(f.name === spec.name ? updated : f); });
                    input.files = dt.files;
                    input.dispatchEvent(new Event('change'));
                    return Promise.resolve();
                } catch (e) { return Promise.reject(e); }
            }
            if (typeof global.chickadeeSaveScriptViaSuite !== 'function') {
                return Promise.reject(new Error('suite table not ready'));
            }
            return global.chickadeeSaveScriptViaSuite(spec);
        },

        cleanup: function () { destroyView(); }
    };

    global.ChickadeeTestRenderers = global.ChickadeeTestRenderers || {};
    global.ChickadeeTestRenderers.script = renderer;
})(typeof window !== 'undefined' ? window : globalThis);
