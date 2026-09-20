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
//
// The decisions (template groups per language, extensions, filename
// renaming, highlighting mode, time-limit validation, the spec per mode) live
// in test-renderer-script-core.js, a classic script the page loads before
// this module; what remains here is CodeMirror, the DOM and the fetches.

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

    var Core = global.ChickadeeScriptRendererCore;

    /// The groups this assignment may pick from, in menu order.
    function templateGroups() { return Core.templateGroups(global.ChickadeeLanguage); }

    /// The extension a new test file gets when the instructor has not named
    /// one, and the extension a chosen template forces.
    function extensionFor(templateKey) { return Core.extensionFor(templateKey, global.ChickadeeLanguage); }

    function cfg() { return global.ChickadeeScriptRendererConfig || {}; }

    var langComp = new Compartment();
    /// Syntax highlighting for the open file: the core names the mode, this
    /// maps it onto the three the vendored CodeMirror bundle carries.
    function langExtensionFor(filename) {
        var mode = Core.highlightModeFor(filename);
        if (mode === 'python') return python();
        if (mode === 'r') return StreamLanguage.define(r);
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

    function el(tag, attrs) {
        var node = document.createElement(tag);
        if (attrs) for (var k in attrs) if (Object.prototype.hasOwnProperty.call(attrs, k)) node.setAttribute(k, attrs[k]);
        return node;
    }

    // ── Renderer state ───────────────────────────────────────────────────────
    var newControls = null;   // filename + template row (shown only for create)
    var nameInput = null;
    var templateSel = null;
    var applyBtn = null;
    var cmMount = null;
    var hintInput = null;
    var timeLimitInput = null;
    var failureDetailSelect = null;
    // The student-facing failure-detail levels. The values are
    // FailureDetail's raw values; FailureDetailOptionCoverageTests pins this
    // list to `FailureDetail.allCases` so it cannot drift from the server.
    var FAILURE_DETAIL_OPTIONS = [
        { value: '', label: 'Full (default)' },
        { value: 'actualOnly', label: 'Actual output only' },
        { value: 'verdictOnly', label: 'Verdict only' }
    ];

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
        var language = global.ChickadeeLanguage && global.ChickadeeLanguage.facts().name;
        return fetch(Core.templatesURL(language), { headers: { 'x-csrf-token': cfg().csrfToken || '' } })
            .then(function (r) { return r.ok ? r.json() : Promise.reject(r.status); })
            .then(function (data) { templateCache = data; return data; });
    }

    var renderer = {
        mechanism: 'script',
        title: function (isEditing) { return isEditing ? 'Edit Test Script' : 'Add Test'; },

        mount: function (bodyEl, ctx) {
            statusFn = (ctx && ctx.setStatus) || function () {};

            // Filename + template controls (create only).
            newControls = el('div', { 'class': 'editor-stack' });
            var nameLabel = el('label', { 'class': 'field-stack' });
            nameLabel.appendChild(document.createTextNode('Filename'));
            nameInput = el('input', {
                type: 'text', 'class': 'form-input editor-input',
                placeholder: 'e.g. test_correctness.' + extensionFor(null)
            });
            nameLabel.appendChild(nameInput);
            newControls.appendChild(nameLabel);

            var tplRow = el('div', { 'class': 'toolbar' });
            var tplCaption = el('span', { 'class': 'editor-status' });
            tplCaption.textContent = 'Template:';
            tplRow.appendChild(tplCaption);
            templateSel = el('select', { 'class': 'form-input select-xs' });
            templateGroups().forEach(function (g) {
                var og = el('optgroup', { label: g.group });
                g.items.forEach(function (it) { var o = el('option', { value: it.value }); o.textContent = it.label; og.appendChild(o); });
                templateSel.appendChild(og);
            });
            var blank = el('option', { value: 'blank' }); blank.textContent = 'Blank'; templateSel.appendChild(blank);
            tplRow.appendChild(templateSel);
            applyBtn = el('button', { type: 'button', 'class': 'btn action-btn' });
            applyBtn.textContent = 'Apply';
            tplRow.appendChild(applyBtn);
            newControls.appendChild(tplRow);
            bodyEl.appendChild(newControls);

            // CodeMirror mount.
            cmMount = el('div', { id: 'cm-editor-mount', 'class': 'editor-cm-mount' });
            bodyEl.appendChild(cmMount);

            // Hint (shown to students on failure) + per-test time limit —
            // visible in all modes, side by side on one row.
            var metaRow = el('div', { 'class': 'toolbar' });
            var hintLabel = el('label', { 'class': 'field-stack field-stack--grow' });
            hintLabel.appendChild(document.createTextNode('Hint (optional — shown to students when this test fails)'));
            hintInput = el('input', { type: 'text', 'class': 'form-input input-compact', placeholder: 'e.g. Re-read the function’s docstring for the expected return type.' });
            hintLabel.appendChild(hintInput);
            metaRow.appendChild(hintLabel);
            var limitLabel = el('label', { 'class': 'field-stack field-stack--narrow' });
            limitLabel.appendChild(document.createTextNode('Time limit (s, blank = default)'));
            timeLimitInput = el('input', {
                type: 'number', 'class': 'form-input input-compact', min: '1', max: '600',
                placeholder: 'assignment default',
                title: 'Seconds this one test may run before it is killed and recorded as a timeout. Blank inherits the assignment default.'
            });
            limitLabel.appendChild(timeLimitInput);
            metaRow.appendChild(limitLabel);
            var detailLabel = el('label', { 'class': 'field-stack field-stack--narrow' });
            detailLabel.appendChild(document.createTextNode('Failure detail'));
            failureDetailSelect = el('select', {
                'class': 'form-input input-compact',
                title: 'Detail a student sees on failure'
            });
            FAILURE_DETAIL_OPTIONS.forEach(function (opt) {
                var o = el('option', { value: opt.value });
                o.textContent = opt.label;
                failureDetailSelect.appendChild(o);
            });
            detailLabel.appendChild(failureDetailSelect);
            metaRow.appendChild(detailLabel);
            bodyEl.appendChild(metaRow);

            // Keep the filename extension in sync with the chosen template.
            // "Blank" leaves a name the instructor has already typed alone —
            // it carries no language of its own.
            templateSel.addEventListener('change', function () {
                var renamed = Core.renamedForTemplate(
                    nameInput.value, templateSel.value || '', global.ChickadeeLanguage);
                if (renamed !== null) nameInput.value = renamed;
            });
            applyBtn.addEventListener('click', function () {
                var tplKey = templateSel ? templateSel.value : 'blank';
                var apply = function (content) {
                    if (!nameInput.value.trim()) {
                        nameInput.value = Core.defaultFilename(tplKey, global.ChickadeeLanguage);
                    }
                    if (view) {
                        view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: content } });
                        view.dispatch({ effects: langComp.reconfigure(langExtensionFor(nameInput.value)) });
                        view.focus();
                    }
                };
                if (tplKey === 'blank') { apply(''); return; }
                fetchTemplates()
                    .then(function (t) { apply(Core.templateContent(t, tplKey)); })
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
            if (timeLimitInput) timeLimitInput.value = '';
            if (failureDetailSelect) failureDetailSelect.value = '';
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
                if (timeLimitInput) timeLimitInput.value = '';
                if (failureDetailSelect) failureDetailSelect.value = '';
                freshView(item.content || '', item.name || '');
                return;
            }
            // Editing an existing saved script — body fetched from the server.
            mode = 'edit';
            currentFilename = item.script || item.id || '';
            if (newControls) newControls.style.display = 'none';
            if (hintInput) hintInput.value = item.hint || '';
            if (timeLimitInput) {
                timeLimitInput.value = item.timeLimitSeconds != null ? String(item.timeLimitSeconds) : '';
            }
            if (failureDetailSelect) failureDetailSelect.value = item.failureDetail || '';
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
            // The core validates the time limit and shapes the spec per mode;
            // this only reads the controls.
            return Core.buildSpec({
                mode: mode,
                content: docText(),
                hint: hintInput ? hintInput.value : '',
                timeLimitText: timeLimitInput ? timeLimitInput.value : '',
                failureDetail: failureDetailSelect ? failureDetailSelect.value : '',
                filename: mode === 'edit' ? currentFilename : (nameInput ? nameInput.value : ''),
                uploadEditName: uploadEditName
            });
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
