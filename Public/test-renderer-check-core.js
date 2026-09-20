// Public/test-renderer-check-core.js
//
// The decisions behind the notebook-check body renderer
// (test-renderer-check.js): how the `#check-schema` seed is read, what
// control each schema field becomes, how a control's value is read back,
// written and defaulted per value type, how a new check is named, and how a
// saved check merges into the suite's list. Nothing here touches the DOM: a
// "control" is any object with `value` and `checked`, so the rules run under
// node (test-renderer-check-core.test.mjs) and the wiring keeps only element
// creation and the modal contract.
(function () {
    'use strict';

    /// The schema seed as the renderer uses it: a `common` field list and a
    /// `kinds` map, each defaulting to empty when the seed is absent or odd.
    function normalizeSchema(parsed) {
        var p = parsed || {};
        return {
            common: Array.isArray(p.common) ? p.common : [],
            kinds: (p.kinds && typeof p.kinds === 'object') ? p.kinds : {}
        };
    }

    function parseSchema(text) {
        try { return normalizeSchema(JSON.parse(text || '{}')); }
        catch (e) { return normalizeSchema(null); }
    }

    /// What a schema field's control looks like: the tag, its attributes, its
    /// options for a select, and the properties the wiring sets after creating
    /// it. A field this language cannot use is disabled and never checked, so
    /// the value the form reads back is the one that saves.
    function controlSpec(field) {
        if (field.control === 'textarea') {
            return {
                tag: 'textarea',
                attrs: { 'class': 'form-input editor-input input-mono', 'data-field': field.name, rows: String(field.rows || 4) },
                placeholder: field.placeholder || null
            };
        }
        if (field.control === 'select') {
            return {
                tag: 'select',
                attrs: { 'class': 'form-input editor-input', 'data-field': field.name },
                options: (field.enumOptions || []).map(function (opt) { return { value: opt.value, label: opt.label }; })
            };
        }
        if (field.control === 'checkbox') {
            var unusable = !!field.unsupportedReason;
            return {
                tag: 'input',
                attrs: { type: 'checkbox', 'data-field': field.name },
                checked: unusable ? false : !!field.defaultChecked,
                disabled: unusable
            };
        }
        var attrs = {
            type: field.control === 'number' ? 'number' : 'text',
            'class': 'form-input editor-input', 'data-field': field.name
        };
        if (field.control === 'number') {
            if (field.valueType === 'optionalFloat') { attrs.step = 'any'; }
            else { attrs.step = '1'; attrs.min = '0'; }
        }
        return { tag: 'input', attrs: attrs, placeholder: field.placeholder || null };
    }

    /// The help line under a field. A field this assignment's language cannot
    /// use is disabled and EXPLAINED, not hidden; its reason comes from the
    /// same predicate the save-time refusal reads and wins over ordinary help.
    function helpText(field) {
        return field.unsupportedReason || field.help || null;
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
                try { values = JSON.parse(rawArr); } catch (e) { throw new Error('Expected array isn\'t valid JSON: ' + e.message, { cause: e }); }
            } else {
                values = rawArr.split('\n').map(function (x) { return x.trim(); }).filter(function (x) { return x.length > 0; })
                    .map(function (x) { var num = parseFloat(x); if (isNaN(num)) throw new Error('Expected array contains a non-number: "' + x + '"'); return num; });
            }
            return { set: true, value: values };
        }
        return { set: false };
    }

    function defaultField(control, field) {
        if (field.control === 'checkbox') {
            control.checked = field.unsupportedReason ? false : !!field.defaultChecked;
            return;
        }
        control.value = field.unsupportedReason ? '' : (field.defaultValue || '');
    }

    function writeField(control, field, value) {
        var vt = field.valueType;
        // A stored value for a field this language cannot use does not get
        // restored into a disabled control: that would produce a check the
        // instructor can neither save (the server refuses it) nor fix (the
        // control is disabled). Clearing it makes re-saving the recovery path.
        if (field.unsupportedReason) { defaultField(control, field); return; }
        if (vt === 'bool') { control.checked = (value != null) ? !!value : !!field.defaultChecked; return; }
        if (vt === 'enum') { control.value = (value != null) ? value : (field.defaultValue || ''); return; }
        if (vt === 'stringList' || vt === 'numberList') { control.value = Array.isArray(value) ? value.join('\n') : ''; return; }
        if (vt === 'int' || vt === 'optionalInt') { control.value = (value != null) ? String(value) : (field.defaultValue || ''); return; }
        control.value = (value != null) ? value : (field.defaultValue || '');
    }

    /// A new check's id: the name (or kind) as a lowercase identifier, capped,
    /// plus a short time suffix so two checks named alike stay distinct.
    function generateID(kind, name, now) {
        var stamp = (typeof now === 'number') ? now : Date.now();
        var base = (name || kind || 'check').toLowerCase().replace(/[^a-z0-9_]+/g, '_').replace(/^_+|_+$/g, '').slice(0, 32) || kind;
        return base + '_' + stamp.toString(36).slice(-4);
    }

    /// The checks among the suite table's items.
    function checksFrom(items) {
        return (items || [])
            .filter(function (i) { return i.kind === 'check' && i.check; })
            .map(function (i) { return i.check; });
    }

    /// The part of a check the form does not edit: tier, points and
    /// dependencies come from the existing row when editing, else defaults.
    function baseSpec(args) {
        var existing = args.existing || null;
        var c = {
            id: args.editingID || generateID(args.kind, args.rawName, args.now),
            kind: args.kind,
            tier: (existing && existing.tier) || 'public',
            points: (existing && existing.points != null) ? existing.points : 1,
            dependsOn: (existing && existing.dependsOn) || []
        };
        if (args.rawName) c.name = args.rawName;
        if (args.sectionID) c.sectionID = args.sectionID;
        return c;
    }

    /// The suite's check list with `spec` upserted. Editing replaces the row
    /// with its id (or appends when it vanished); creating refuses an id that
    /// is already taken rather than overwriting someone else's check.
    function mergeChecks(checks, spec, editingID) {
        var next = checks.slice();
        var idx = next.findIndex(function (c) { return c.id === spec.id; });
        if (editingID) {
            if (idx >= 0) next[idx] = spec; else next.push(spec);
            return next;
        }
        if (idx >= 0) throw new Error('A check with id "' + spec.id + '" already exists. Pick a different name.');
        next.push(spec);
        return next;
    }

    var api = {
        normalizeSchema: normalizeSchema,
        parseSchema: parseSchema,
        controlSpec: controlSpec,
        helpText: helpText,
        readField: readField,
        writeField: writeField,
        defaultField: defaultField,
        generateID: generateID,
        checksFrom: checksFrom,
        baseSpec: baseSpec,
        mergeChecks: mergeChecks
    };

    var root = typeof window !== 'undefined' ? window : globalThis;
    root.ChickadeeCheckRendererCore = api;
    // Node export for the .mjs unit tests.
    if (typeof module === 'object' && module.exports) {
        module.exports = api;
    }
}());
