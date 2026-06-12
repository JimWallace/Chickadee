// Chickadee — Notebook-check body renderer for the unified Test Editor modal.
//
// Registers `window.ChickadeeTestRenderers.check`. The shell
// (test-editor-modal.js) owns the chrome, the type `<select>` (which supplies
// the check `kind`), the status line, and the Save button; this renderer owns
// only the per-kind form body, built generically from the backend-emitted
// `#check-schema` seed (PR3). Replaces the standalone notebook-check editor
// modal + its `initNotebookCheckEditor` entry point.
//
// Contract: mount / reset(kind) / populate(item) / readSpec / persistAndSync /
// cleanup / title. Persistence flows through the single `PUT /suite` write
// path via `window.chickadeeSaveChecksViaSuite` (full check list, upserted).

(function (global) {
    'use strict';

    function loadSchema() {
        var el = document.getElementById('check-schema');
        if (!el) return { common: [], kinds: {} };
        try {
            var p = JSON.parse(el.textContent || '{}');
            return {
                common: Array.isArray(p.common) ? p.common : [],
                kinds: (p.kinds && typeof p.kinds === 'object') ? p.kinds : {}
            };
        } catch (e) { return { common: [], kinds: {} }; }
    }

    function el(tag, attrs, style) {
        var node = document.createElement(tag);
        if (attrs) for (var k in attrs) if (Object.prototype.hasOwnProperty.call(attrs, k)) node.setAttribute(k, attrs[k]);
        if (style) node.style.cssText = style;
        return node;
    }

    function buildControl(field) {
        var common = 'padding:.3rem .5rem;font-size:.85rem';
        if (field.control === 'textarea') {
            var ta = el('textarea', { 'class': 'form-input', 'data-field': field.name, rows: String(field.rows || 4) }, common + ';font-family:monospace');
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
        var input = el('input', {
            type: field.control === 'number' ? 'number' : 'text',
            'class': 'form-input', 'data-field': field.name
        }, common);
        if (field.control === 'number') {
            if (field.valueType === 'optionalFloat') { input.setAttribute('step', 'any'); }
            else { input.setAttribute('step', '1'); input.setAttribute('min', '0'); }
        }
        if (field.placeholder) input.placeholder = field.placeholder;
        return input;
    }

    function renderField(field) {
        var help = field.help ? (function () {
            var p = el('p', { 'class': 'card-meta' }, 'font-size:.72rem;margin:0');
            p.textContent = field.help;
            return p;
        })() : null;
        if (field.control === 'checkbox') {
            var row = el('label', null, 'font-size:.82rem;display:flex;align-items:center;gap:.3rem');
            row.appendChild(buildControl(field));
            row.appendChild(document.createTextNode(' ' + field.label));
            if (!help) return row;
            var wrap = el('div', null, 'display:flex;flex-direction:column;gap:.2rem');
            wrap.appendChild(row); wrap.appendChild(help);
            return wrap;
        }
        var label = el('label', null, 'font-size:.85rem;display:flex;flex-direction:column;gap:.2rem');
        label.appendChild(document.createTextNode(field.label));
        label.appendChild(buildControl(field));
        if (help) label.appendChild(help);
        return label;
    }

    function readField(control, field) {
        var vt = field.valueType;
        if (vt === 'bool') return { set: true, value: !!control.checked };
        if (vt === 'enum') return { set: true, value: control.value };
        if (vt === 'string') return { set: true, value: (control.value || '').trim() };
        if (vt === 'optionalString') { var s = (control.value || '').trim(); return s ? { set: true, value: s } : { set: false }; }
        if (vt === 'rawString') return { set: true, value: control.value || '' };
        if (vt === 'optionalRawString') { var raw = control.value || ''; return raw.trim() ? { set: true, value: raw } : { set: false }; }
        if (vt === 'int') return { set: true, value: parseInt(control.value, 10) };
        if (vt === 'optionalInt') { var n = parseInt(control.value, 10); return isNaN(n) ? { set: false } : { set: true, value: n }; }
        if (vt === 'optionalFloat') { var f = parseFloat(control.value); return isNaN(f) ? { set: false } : { set: true, value: f }; }
        if (vt === 'stringList') {
            var list = (control.value || '').split('\n').map(function (x) { return x.trim(); }).filter(function (x) { return x.length > 0; });
            return { set: true, value: list };
        }
        if (vt === 'numberList') {
            var rawArr = (control.value || '').trim(), values;
            if (rawArr.indexOf('[') === 0) {
                try { values = JSON.parse(rawArr); } catch (e) { throw new Error('Expected array isn\'t valid JSON: ' + e.message); }
            } else {
                values = rawArr.split('\n').map(function (x) { return x.trim(); }).filter(function (x) { return x.length > 0; })
                    .map(function (x) { var num = parseFloat(x); if (isNaN(num)) throw new Error('Expected array contains a non-number: "' + x + '"'); return num; });
            }
            return { set: true, value: values };
        }
        return { set: false };
    }

    function writeField(control, field, value) {
        var vt = field.valueType;
        if (vt === 'bool') { control.checked = (value != null) ? !!value : !!field.defaultChecked; return; }
        if (vt === 'enum') { control.value = (value != null) ? value : (field.defaultValue || ''); return; }
        if (vt === 'stringList' || vt === 'numberList') { control.value = Array.isArray(value) ? value.join('\n') : ''; return; }
        if (vt === 'int' || vt === 'optionalInt') { control.value = (value != null) ? String(value) : (field.defaultValue || ''); return; }
        control.value = (value != null) ? value : (field.defaultValue || '');
    }

    function defaultField(control, field) {
        if (field.control === 'checkbox') { control.checked = !!field.defaultChecked; return; }
        control.value = field.defaultValue || '';
    }

    function generateID(kind, name) {
        var base = (name || kind || 'check').toLowerCase().replace(/[^a-z0-9_]+/g, '_').replace(/^_+|_+$/g, '').slice(0, 32) || kind;
        return base + '_' + Date.now().toString(36).slice(-4);
    }

    function currentChecks() {
        if (typeof global.chickadeeGetSuiteItems === 'function') {
            return global.chickadeeGetSuiteItems()
                .filter(function (i) { return i.kind === 'check' && i.check; })
                .map(function (i) { return i.check; });
        }
        return [];
    }

    // ── Renderer ────────────────────────────────────────────────────────────
    var schema = null;
    var nameInput = null;
    var fieldsBody = null;
    var commonBody = null;
    var kindCards = {};      // kind → card element
    var currentKind = null;
    var editingID = null;    // null = new
    var sectionID = null;

    function fieldControl(card, name) { return card ? card.querySelector('[data-field="' + name + '"]') : null; }
    function commonControl(name) { return commonBody ? commonBody.querySelector('[data-field="' + name + '"]') : null; }

    function showFieldsForKind(kind) {
        Object.keys(kindCards).forEach(function (k) {
            kindCards[k].style.display = (k === kind) ? 'flex' : 'none';
        });
    }

    var renderer = {
        mechanism: 'check',

        title: function (isEditing) { return isEditing ? 'Edit Notebook Check' : 'Add Test'; },

        mount: function (bodyEl /*, ctx */) {
            schema = loadSchema();

            var nameLabel = el('label', null, 'font-size:.85rem;display:flex;flex-direction:column;gap:.2rem');
            nameLabel.appendChild(document.createTextNode('Display name (shown to students)'));
            nameInput = el('input', { type: 'text', 'class': 'form-input', placeholder: '(auto-generated when blank)' }, 'padding:.3rem .5rem;font-size:.85rem');
            nameLabel.appendChild(nameInput);
            bodyEl.appendChild(nameLabel);

            var note = el('p', { 'class': 'card-meta' }, 'font-size:.72rem;margin:.1rem 0 0');
            note.textContent = 'Tier (visibility) and points are edited inline on the test suite row. New checks default to public and 1 point.';
            bodyEl.appendChild(note);

            fieldsBody = el('div', null, 'display:flex;flex-direction:column;gap:.5rem');
            commonBody = el('div', null, 'display:flex;flex-direction:column;gap:.5rem');
            bodyEl.appendChild(fieldsBody);
            bodyEl.appendChild(commonBody);

            Object.keys(schema.kinds).forEach(function (kind) {
                var card = el('div', { 'data-kind': kind }, 'display:none;flex-direction:column;gap:.5rem');
                (schema.kinds[kind] || []).forEach(function (f) { card.appendChild(renderField(f)); });
                fieldsBody.appendChild(card);
                kindCards[kind] = card;
            });
            schema.common.forEach(function (f) { commonBody.appendChild(renderField(f)); });
        },

        reset: function (kind, ctx) {
            editingID = null;
            currentKind = kind;
            sectionID = ctx && typeof ctx.getSectionID === 'function' ? ctx.getSectionID() : null;
            if (nameInput) nameInput.value = '';
            Object.keys(schema.kinds).forEach(function (k) {
                (schema.kinds[k] || []).forEach(function (f) {
                    var c = fieldControl(kindCards[k], f.name);
                    if (c) defaultField(c, f);
                });
            });
            schema.common.forEach(function (f) { var c = commonControl(f.name); if (c) defaultField(c, f); });
            showFieldsForKind(kind);
        },

        populate: function (item, ctx) {
            this.reset(item.kind, ctx);
            editingID = item.id || null;
            currentKind = item.kind;
            sectionID = (item.sectionID != null) ? item.sectionID : sectionID;
            if (nameInput) nameInput.value = item.name || '';
            var card = kindCards[item.kind];
            (schema.kinds[item.kind] || []).forEach(function (f) {
                var c = fieldControl(card, f.name);
                if (c) writeField(c, f, item[f.name]);
            });
            schema.common.forEach(function (f) { var c = commonControl(f.name); if (c) writeField(c, f, item[f.name]); });
            showFieldsForKind(item.kind);
        },

        readSpec: function () {
            var kind = currentKind;
            var rawName = (nameInput.value || '').trim();
            var id = editingID || generateID(kind, rawName);
            var existing = editingID
                ? currentChecks().find(function (c) { return c.id === editingID; })
                : null;
            var c = {
                id: id, kind: kind,
                tier: (existing && existing.tier) || 'public',
                points: (existing && existing.points != null) ? existing.points : 1,
                dependsOn: (existing && existing.dependsOn) || []
            };
            if (rawName) c.name = rawName;
            if (sectionID) c.sectionID = sectionID;
            var card = kindCards[kind];
            (schema.kinds[kind] || []).forEach(function (f) {
                var ctrl = fieldControl(card, f.name);
                if (!ctrl) return;
                var r = readField(ctrl, f);   // may throw on bad number list
                if (r.set) c[f.name] = r.value;
            });
            schema.common.forEach(function (f) {
                var ctrl = commonControl(f.name);
                if (!ctrl) return;
                var rc = readField(ctrl, f);
                if (rc.set) c[f.name] = rc.value;
            });
            return c;
        },

        persistAndSync: function (spec) {
            if (typeof global.chickadeeSaveChecksViaSuite !== 'function') {
                return Promise.reject(new Error('suite table not ready'));
            }
            var checks = currentChecks();
            var idx = checks.findIndex(function (c) { return c.id === spec.id; });
            if (editingID) {
                if (idx >= 0) checks[idx] = spec; else checks.push(spec);
            } else {
                if (idx >= 0) return Promise.reject(new Error('A check with id "' + spec.id + '" already exists. Pick a different name.'));
                checks.push(spec);
            }
            return global.chickadeeSaveChecksViaSuite(checks);
        },

        cleanup: function () { /* no transient resources */ }
    };

    global.ChickadeeTestRenderers = global.ChickadeeTestRenderers || {};
    global.ChickadeeTestRenderers.check = renderer;
})(typeof window !== 'undefined' ? window : globalThis);
