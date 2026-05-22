// Chickadee — Notebook Check Editor (schema-driven)
//
// Browser-side module that drives the notebook-check modal on the
// instructor assignment editor.  Sibling to pattern-family-editor.js;
// each NotebookCheck expands at save time into a single generated test
// script (and optionally a sidecar `_expected_<id>.csv` for the
// DataFrame/Series equality kinds), so the modal needs no cases table
// — it's one form per check.
//
// The per-kind fields are NOT hand-coded here.  The backend emits a form
// schema (see Sources/APIServer/Utilities/NotebookCheckFormSchema.swift) as
// a `<script id="check-schema">` seed; this module renders one hidden card
// per kind from that schema into `#check-fields-body`, plus the common
// fields (the instructor hint) into `#check-common-fields`.  reset / populate
// / build are one generic engine driven by each field's `valueType`, so
// adding or changing a check kind means editing only the Swift schema +
// validator — never this file or the Leaf templates.
//
// The modal chrome lives in assignment-edit.leaf / assignment-new.leaf with
// stable DOM ids (`check-editor-overlay`, `check-id`, `check-name`,
// `check-kind`, `check-fields-body`, `check-common-fields`, …).
//
// Host page wires the module via:
//
//   window.initNotebookCheckEditor({
//       assignmentID: 'TWTFKZ',
//       csrfToken: '<token>',
//       initialChecks: [...],         // parsed notebook-checks-seed JSON
//       urls: { getChecks, putChecks },
//       onChecksChange: function (applied) {} // suite-table sync hook
//   })
//
// Returns `{ open(idOrNull, sectionID, presetKind), close(), getChecks() }`.

(function (global) {
    'use strict';

    // ── Schema loading ──────────────────────────────────────────────────
    // Parsed once from the #check-schema seed.  Shape:
    //   { common: [field...], kinds: { "<kind>": [field...] } }
    // A field is { name, control, valueType, label, required, placeholder,
    //   help, rows, enumOptions:[{value,label}], defaultChecked, defaultValue }.
    function loadSchema() {
        var el = document.getElementById('check-schema');
        if (!el) return { common: [], kinds: {} };
        try {
            var parsed = JSON.parse(el.textContent || '{}');
            return {
                common: Array.isArray(parsed.common) ? parsed.common : [],
                kinds: (parsed.kinds && typeof parsed.kinds === 'object') ? parsed.kinds : {}
            };
        } catch (e) {
            return { common: [], kinds: {} };
        }
    }

    // ── Field DOM construction ──────────────────────────────────────────
    function el(tag, attrs, style) {
        var node = document.createElement(tag);
        if (attrs) {
            for (var k in attrs) {
                if (Object.prototype.hasOwnProperty.call(attrs, k)) node.setAttribute(k, attrs[k]);
            }
        }
        if (style) node.style.cssText = style;
        return node;
    }

    // Build the input/control element for a field, tagged with data-field so
    // the read/write engine can find it within its card.
    function buildControl(field) {
        var common = 'padding:.3rem .5rem;font-size:.85rem';
        if (field.control === 'textarea') {
            var ta = el('textarea', {
                'class': 'form-input',
                'data-field': field.name,
                rows: String(field.rows || 4)
            }, common + ';font-family:monospace');
            if (field.placeholder) ta.placeholder = field.placeholder;
            return ta;
        }
        if (field.control === 'select') {
            var sel = el('select', { 'class': 'form-input', 'data-field': field.name }, common);
            (field.enumOptions || []).forEach(function (opt) {
                var o = el('option', { value: opt.value });
                o.textContent = opt.label;
                sel.appendChild(o);
            });
            return sel;
        }
        if (field.control === 'checkbox') {
            var cb = el('input', { type: 'checkbox', 'data-field': field.name });
            if (field.defaultChecked) cb.checked = true;
            return cb;
        }
        // text or number
        var input = el('input', {
            type: field.control === 'number' ? 'number' : 'text',
            'class': 'form-input',
            'data-field': field.name
        }, common);
        if (field.control === 'number') {
            // Integer fields step by 1 with a 0 floor; float fields (rtol /
            // atol, valueType optionalFloat) allow arbitrary precision.
            if (field.valueType === 'optionalFloat') {
                input.setAttribute('step', 'any');
            } else {
                input.setAttribute('step', '1');
                input.setAttribute('min', '0');
            }
        }
        if (field.placeholder) input.placeholder = field.placeholder;
        return input;
    }

    // Wrap a field's control in its label + optional help text.
    function renderField(field) {
        var help = field.help
            ? (function () {
                var p = el('p', { 'class': 'card-meta' }, 'font-size:.72rem;margin:0');
                p.textContent = field.help;
                return p;
            })()
            : null;

        if (field.control === 'checkbox') {
            var row = el('label', null, 'font-size:.82rem;display:flex;align-items:center;gap:.3rem');
            row.appendChild(buildControl(field));
            row.appendChild(document.createTextNode(' ' + field.label));
            if (!help) return row;
            var wrap = el('div', null, 'display:flex;flex-direction:column;gap:.2rem');
            wrap.appendChild(row);
            wrap.appendChild(help);
            return wrap;
        }

        var label = el('label', null, 'font-size:.85rem;display:flex;flex-direction:column;gap:.2rem');
        label.appendChild(document.createTextNode(field.label));
        label.appendChild(buildControl(field));
        if (help) label.appendChild(help);
        return label;
    }

    // ── Value coercion ──────────────────────────────────────────────────
    // Read a field's value off its control into the JS form-state, returning
    // { set: bool, value } — `set:false` means "omit this property".
    function readField(control, field) {
        var vt = field.valueType;
        if (vt === 'bool') return { set: true, value: !!control.checked };
        if (vt === 'enum') return { set: true, value: control.value };
        if (vt === 'string') return { set: true, value: (control.value || '').trim() };
        if (vt === 'optionalString') {
            var s = (control.value || '').trim();
            return s ? { set: true, value: s } : { set: false };
        }
        if (vt === 'rawString') return { set: true, value: control.value || '' };
        if (vt === 'optionalRawString') {
            var raw = control.value || '';
            return raw.trim() ? { set: true, value: raw } : { set: false };
        }
        if (vt === 'int') return { set: true, value: parseInt(control.value, 10) };
        if (vt === 'optionalInt') {
            var n = parseInt(control.value, 10);
            return isNaN(n) ? { set: false } : { set: true, value: n };
        }
        if (vt === 'optionalFloat') {
            var f = parseFloat(control.value);
            return isNaN(f) ? { set: false } : { set: true, value: f };
        }
        if (vt === 'stringList') {
            var list = (control.value || '').split('\n')
                .map(function (x) { return x.trim(); })
                .filter(function (x) { return x.length > 0; });
            return { set: true, value: list };
        }
        if (vt === 'numberList') {
            var rawArr = (control.value || '').trim();
            var values;
            if (rawArr.indexOf('[') === 0) {
                try { values = JSON.parse(rawArr); }
                catch (e) { throw new Error('Expected array isn\'t valid JSON: ' + e.message); }
            } else {
                values = rawArr.split('\n').map(function (x) { return x.trim(); })
                    .filter(function (x) { return x.length > 0; })
                    .map(function (x) {
                        var num = parseFloat(x);
                        if (isNaN(num)) throw new Error('Expected array contains a non-number: "' + x + '"');
                        return num;
                    });
            }
            return { set: true, value: values };
        }
        return { set: false };
    }

    // Write a stored check's value back into the control (edit/populate).
    function writeField(control, field, value) {
        var vt = field.valueType;
        if (vt === 'bool') {
            control.checked = (value != null) ? !!value : !!field.defaultChecked;
            return;
        }
        if (vt === 'enum') {
            control.value = (value != null) ? value : (field.defaultValue || '');
            return;
        }
        if (vt === 'stringList' || vt === 'numberList') {
            control.value = Array.isArray(value) ? value.join('\n') : '';
            return;
        }
        if (vt === 'int' || vt === 'optionalInt') {
            control.value = (value != null) ? String(value) : (field.defaultValue || '');
            return;
        }
        // string / optionalString / rawString / optionalRawString / optionalFloat
        control.value = (value != null) ? value : (field.defaultValue || '');
    }

    // Seed a control with its authoring default (reset / new check).
    function defaultField(control, field) {
        if (field.control === 'checkbox') { control.checked = !!field.defaultChecked; return; }
        control.value = field.defaultValue || '';
    }

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

        var schema = loadSchema();

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
        var fieldsBody = $('check-fields-body');
        var commonBody = $('check-common-fields');

        if (!overlay || !kindSelect || !saveBtn || !fieldsBody) {
            // Modal markup absent — host page must have it.  Bail silently
            // so callers in other contexts (preview, drafts) don't blow up.
            return {
                open: function () {},
                close: function () {},
                getChecks: function () { return checksState.slice(); }
            };
        }

        // ── Render the schema into per-kind cards + common fields ───────────
        var kindCards = {};   // kind → card element
        (function buildCards() {
            Object.keys(schema.kinds).forEach(function (kind) {
                var card = el('div', { 'class': 'check-fields', 'data-kind': kind },
                    'display:none;flex-direction:column;gap:.5rem');
                (schema.kinds[kind] || []).forEach(function (field) {
                    card.appendChild(renderField(field));
                });
                fieldsBody.appendChild(card);
                kindCards[kind] = card;
            });
            if (commonBody) {
                schema.common.forEach(function (field) {
                    commonBody.appendChild(renderField(field));
                });
            }
        })();

        function activeCard(kind) { return kindCards[kind] || null; }
        function fieldControl(card, name) {
            return card ? card.querySelector('[data-field="' + name + '"]') : null;
        }
        function commonControl(name) {
            return commonBody ? commonBody.querySelector('[data-field="' + name + '"]') : null;
        }

        function showFieldsForKind(kind) {
            Object.keys(kindCards).forEach(function (k) {
                kindCards[k].style.display = (k === kind) ? 'flex' : 'none';
            });
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

            if (!editingID && presetKind && kindCards[presetKind]) {
                kindSelect.value = presetKind;
                showFieldsForKind(kindSelect.value);
            }

            overlay.style.display = 'flex';
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

        // ── Form helpers (generic, schema-driven) ──────────────────────────
        var firstKind = kindSelect.options.length ? kindSelect.options[0].value : 'data_frame_shape';

        function resetForm() {
            idInput.value = '';
            nameInput.value = '';
            kindSelect.value = firstKind;
            // Reset every generated control across every card to its default.
            Object.keys(schema.kinds).forEach(function (kind) {
                var card = kindCards[kind];
                (schema.kinds[kind] || []).forEach(function (field) {
                    var ctrl = fieldControl(card, field.name);
                    if (ctrl) defaultField(ctrl, field);
                });
            });
            schema.common.forEach(function (field) {
                var ctrl = commonControl(field.name);
                if (ctrl) defaultField(ctrl, field);
            });
            showFieldsForKind(firstKind);
        }

        function populateForm(c) {
            // Default the whole form first, then write this check's values
            // into its kind's card + the common fields.
            resetForm();
            var kind = c.kind || firstKind;
            idInput.value = c.id || '';
            nameInput.value = c.name || '';
            kindSelect.value = kind;

            var card = activeCard(kind);
            (schema.kinds[kind] || []).forEach(function (field) {
                var ctrl = fieldControl(card, field.name);
                if (ctrl) writeField(ctrl, field, c[field.name]);
            });
            schema.common.forEach(function (field) {
                var ctrl = commonControl(field.name);
                if (ctrl) writeField(ctrl, field, c[field.name]);
            });
            showFieldsForKind(kind);
        }

        // ── Build a NotebookCheck object from the form state ───────────────
        function buildCheckFromForm() {
            var kind = kindSelect.value;
            var rawName = (nameInput.value || '').trim();
            var rawID = (idInput.value || '').trim();
            var id = rawID || generateID(kind, rawName);
            var sectionID = sectionIDInput.value || null;

            // Preserve tier / points / dependsOn from the existing check when
            // editing, so inline edits on the suite-table row aren't clobbered
            // by the modal save.  New checks default to public / 1 / no deps;
            // the instructor tunes from the inline row afterwards.
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

            var card = activeCard(kind);
            (schema.kinds[kind] || []).forEach(function (field) {
                var ctrl = fieldControl(card, field.name);
                if (!ctrl) return;
                var r = readField(ctrl, field);   // may throw on bad number list
                if (r.set) c[field.name] = r.value;
            });
            schema.common.forEach(function (field) {
                var ctrl = commonControl(field.name);
                if (!ctrl) return;
                var rc = readField(ctrl, field);
                if (rc.set) c[field.name] = rc.value;
            });
            return c;
        }

        function generateID(kind, name) {
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
        /// onChecksChange sync is needed). Falls back to the legacy
        /// `PUT /checks` + onChecksChange otherwise.
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

        // Seed the form once so a fresh "+ Add" lands on sane defaults.
        resetForm();

        return {
            open: open,
            close: close,
            getChecks: function () { return checksState.slice(); }
        };
    }

    global.initNotebookCheckEditor = initNotebookCheckEditor;

})(typeof window !== 'undefined' ? window : globalThis);
