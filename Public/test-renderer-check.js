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
//
// The decisions (schema parsing, what control a field becomes, how a value is
// read, written and defaulted per value type, id generation, the upsert) live
// in test-renderer-check-core.js, loaded before this file; what remains here
// is element creation and the modal contract.

(function (global) {
    'use strict';

    var Core = global.ChickadeeCheckRendererCore;

    function loadSchema() {
        var el = document.getElementById('check-schema');
        return el ? Core.parseSchema(el.textContent) : Core.normalizeSchema(null);
    }

    function el(tag, attrs) {
        var node = document.createElement(tag);
        if (attrs) for (var k in attrs) if (Object.prototype.hasOwnProperty.call(attrs, k)) node.setAttribute(k, attrs[k]);
        return node;
    }

    /// Materialises the core's description of a field's control.
    function buildControl(field) {
        var spec = Core.controlSpec(field);
        var node = el(spec.tag, spec.attrs);
        (spec.options || []).forEach(function (opt) {
            var o = el('option', { value: opt.value });
            o.textContent = opt.label;
            node.appendChild(o);
        });
        if (spec.placeholder) node.placeholder = spec.placeholder;
        if (spec.checked) node.checked = true;
        if (spec.disabled) node.disabled = true;
        return node;
    }

    function renderField(field) {
        // A field this assignment's language cannot use is DISABLED and
        // explained, not hidden. The reason comes from the same predicate the
        // save-time refusal reads, so an instructor cannot be told one thing
        // here and another on save -- which is exactly what happened to a Lua
        // author ticking `cell_contains` regex, whose save was guaranteed to
        // fail with a message they only saw afterwards.
        var helpText = Core.helpText(field);
        var help = helpText ? (function () {
            var p = el('p', { 'class': 'field-help' });
            p.textContent = helpText;
            return p;
        })() : null;
        if (field.control === 'checkbox') {
            var row = el('label', { 'class': 'checkbox-row' });
            row.appendChild(buildControl(field));
            row.appendChild(document.createTextNode(' ' + field.label));
            if (!help) return row;
            var wrap = el('div', { 'class': 'field-stack' });
            wrap.appendChild(row); wrap.appendChild(help);
            return wrap;
        }
        var label = el('label', { 'class': 'field-stack' });
        label.appendChild(document.createTextNode(field.label));
        label.appendChild(buildControl(field));
        if (help) label.appendChild(help);
        return label;
    }

    var readField = Core.readField;
    var writeField = Core.writeField;
    var defaultField = Core.defaultField;

    function currentChecks() {
        if (typeof global.chickadeeGetSuiteItems === 'function') {
            return Core.checksFrom(global.chickadeeGetSuiteItems());
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

            var nameLabel = el('label', { 'class': 'field-stack' });
            nameLabel.appendChild(document.createTextNode('Display name (shown to students)'));
            nameInput = el('input', { type: 'text', 'class': 'form-input editor-input', placeholder: '(auto-generated when blank)' });
            nameLabel.appendChild(nameInput);
            bodyEl.appendChild(nameLabel);

            var note = el('p', { 'class': 'field-help' });
            note.textContent = 'Tier (visibility) and points are edited inline on the test suite row. New checks default to public and 1 point.';
            bodyEl.appendChild(note);

            fieldsBody = el('div', { 'class': 'editor-stack' });
            commonBody = el('div', { 'class': 'editor-stack' });
            bodyEl.appendChild(fieldsBody);
            bodyEl.appendChild(commonBody);

            Object.keys(schema.kinds).forEach(function (kind) {
                var card = el('div', { 'data-kind': kind, 'class': 'editor-stack' });
                card.style.display = 'none';
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
            var existing = editingID
                ? currentChecks().find(function (c) { return c.id === editingID; })
                : null;
            var c = Core.baseSpec({
                kind: kind, rawName: rawName, editingID: editingID,
                existing: existing, sectionID: sectionID
            });
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
            var checks;
            try { checks = Core.mergeChecks(currentChecks(), spec, editingID); }
            catch (e) { return Promise.reject(e); }
            return global.chickadeeSaveChecksViaSuite(checks);
        },

        cleanup: function () { /* no transient resources */ }
    };

    global.ChickadeeTestRenderers = global.ChickadeeTestRenderers || {};
    global.ChickadeeTestRenderers.check = renderer;
})(typeof window !== 'undefined' ? window : globalThis);
