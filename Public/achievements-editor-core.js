// Public/achievements-editor-core.js
//
// The decisions behind the composable Achievements editor
// (achievements-editor.js): how a row is summarised for the table, which
// signals a scope may offer, how a condition row serialises, what a Save must
// refuse, and how a failed PUT is worded. Nothing here touches the DOM. Every
// input is a plain value the wiring reads off the page, so the rules run
// under node (achievements-editor-core.test.mjs) and the wiring keeps only
// element lookups, cloning and event listeners.
//
// Labels for record dimensions are NOT here: the wiring reads them off the
// "Ranked by" select so RecordDimensionPresentation stays the single source
// of truth (RecordDimensionCoverageTests pins that no JS hand-types one).
(function () {
    'use strict';

    var SCOPE_LABEL = {
        individual: 'This student', classWide: 'The class', record: 'Class record'
    };
    var CMP_LABEL = { atLeast: '≥', atMost: '≤', equals: '=' };
    var NAME_REQUIRED = 'Name is required.';

    function n(v) { return v == null ? '' : v; }

    /// Every fact about one signal, read off a rendered <option>'s data
    /// attributes so AchievementSignalPresentation stays the single source of
    /// truth. `option` needs only `value`, `text` and `getAttribute`.
    function signalMetaFromOption(option) {
        return {
            label: option.text, unit: option.getAttribute('data-unit') || '',
            scopes: (option.getAttribute('data-scope') || '').split(/\s+/),
            refControl: option.getAttribute('data-ref-control') || '',
            refField: option.getAttribute('data-ref-field') || '',
            refLabel: option.getAttribute('data-ref-label') || '',
            refPlaceholder: option.getAttribute('data-ref-placeholder') || '',
            refReplacesValue: option.getAttribute('data-ref-replaces-value') === 'true'
        };
    }

    /// signal value -> meta, for every option in `options`.
    function signalMetaFromOptions(options) {
        var out = {};
        Array.prototype.forEach.call(options, function (o) {
            out[o.value] = signalMetaFromOption(o);
        });
        return out;
    }

    /// May a signal be chosen under `scope`? A signal the dropdown knows
    /// nothing about is allowed everywhere, as before.
    function isSignalAllowed(meta, scope) {
        return !meta || !meta.scopes || meta.scopes.indexOf(scope) >= 0;
    }

    /// The signal a condition row should show under `scope`: its current one
    /// when that is allowed, otherwise the first allowed value in `values`
    /// (menu order), or the current one when nothing is allowed.
    function signalForScope(current, values, signalMeta, scope) {
        var meta = signalMeta[current];
        if (meta && meta.scopes && meta.scopes.indexOf(scope) < 0) {
            var first = values.filter(function (v) {
                return isSignalAllowed(signalMeta[v] || {}, scope);
            })[0];
            if (first != null) return first;
        }
        return current;
    }

    /// One condition as a human phrase for the table's Earned-when cell.
    /// `ctx.esc` escapes HTML, `ctx.sectionNames` maps section id -> name.
    function condPhrase(c, ctx) {
        var meta = ctx.signalMeta[c.signal] || { label: c.signal, unit: '', refField: '' };
        var ref = meta.refField ? n(c[meta.refField]) : '';
        if (meta.refReplacesValue) { return '“' + ctx.esc(ref) + '” passes'; }
        var unit = meta.unit ? (meta.unit === '%' ? '%' : ' ' + meta.unit) : '';
        var phrase = ctx.esc(meta.label) + ' ' + (CMP_LABEL[c.comparator] || c.comparator)
            + ' ' + n(c.value) + unit;
        // A section ref is stored as an opaque id; show the name the author
        // gave it, never the id.
        if (ref) { phrase += ' in “' + ctx.esc(ctx.sectionNames[ref] || ref) + '”'; }
        return phrase;
    }

    function conditionsText(row, ctx) {
        var conds = row.conditions || [];
        if (!conds.length) { return 'always'; }
        var joiner = row.match === 'any' ? ' or ' : ' and ';
        return conds.map(function (c) { return condPhrase(c, ctx); }).join(joiner);
    }

    /// The Earned-when cell. `ctx.dimLabel` names a record dimension.
    function summary(row, ctx) {
        if (row.scope === 'record') {
            return 'record · ' + ctx.dimLabel(row.recordDimension);
        }
        if (row.scope === 'classWide') {
            return conditionsText(row, ctx) + ' · by ' + n(row.classPercent)
                + '% of class · +' + n(row.points) + (row.points === 1 ? ' pt' : ' pts');
        }
        return conditionsText(row, ctx);
    }

    /// The options a section-reference select offers. "" counts every test in
    /// the suite, including tests in no section, so it reads "Whole suite". A
    /// ref left behind by a deleted section matches no option; without a home
    /// it would render blank and then serialise as "", silently widening the
    /// rule to the whole suite, so it gets a disabled option of its own and
    /// the save refuses it by name.
    function sectionOptions(names, storedRef) {
        var out = [{ value: '', label: 'Whole suite', disabled: false }];
        Object.keys(names).forEach(function (id) {
            out.push({ value: id, label: names[id], disabled: false });
        });
        var stored = n(storedRef);
        if (stored && !names[stored]) {
            out.push({ value: stored, label: 'Deleted section', disabled: true });
        }
        return out;
    }

    /// One condition row's inputs, serialised for the server. A signal either
    /// compares a value, names a reference, or does both (items-covered counts
    /// AND scopes); refReplacesValue distinguishes the second case. The server
    /// names the reference field, so a third ref kind lands in the right one
    /// with no edit here.
    function conditionFromRow(fields, signalMeta) {
        var meta = signalMeta[fields.signal] || {};
        var refText = (fields.refText || '').trim();
        var out = meta.refReplacesValue
            ? { signal: fields.signal, comparator: 'atLeast', value: 1 }
            : {
                signal: fields.signal,
                comparator: fields.comparator,
                value: Number(fields.value || 0)
            };
        if (meta.refField) { out[meta.refField] = refText; }
        return out;
    }

    /// The achievement a Save persists, or the reason it must not.
    /// `form` carries the editor's raw field values; `existing` is the row
    /// being edited (its id survives) or null for a new one.
    function buildAchievement(form, existing) {
        var name = (form.name || '').trim();
        if (!name) { return { ok: false, error: NAME_REQUIRED }; }
        var next = { name: name, scope: form.scope, match: form.match };
        var detail = (form.detail || '').trim();
        if (detail) next.detail = detail;
        if (existing && existing.id) next.id = existing.id;
        if (form.scope === 'record') {
            next.recordDimension = form.recordDimension;
        } else {
            next.conditions = form.conditions || [];
            if (form.scope === 'classWide') {
                next.classPercent = Number(form.classPercent || 0);
                next.points = Number(form.points || 0);
            }
        }
        return { ok: true, achievement: next };
    }

    /// The message for a failed PUT: the server's `reason` when the body is
    /// JSON, else the raw text, else the status; capped for the status line.
    function persistErrorMessage(text, status) {
        var msg = text || ('HTTP ' + status);
        try { var p = JSON.parse(text); if (p && p.reason) msg = p.reason; } catch (_) { /* text */ }
        return msg.slice(0, 240);
    }

    var api = {
        SCOPE_LABEL: SCOPE_LABEL,
        CMP_LABEL: CMP_LABEL,
        NAME_REQUIRED: NAME_REQUIRED,
        signalMetaFromOption: signalMetaFromOption,
        signalMetaFromOptions: signalMetaFromOptions,
        isSignalAllowed: isSignalAllowed,
        signalForScope: signalForScope,
        condPhrase: condPhrase,
        conditionsText: conditionsText,
        summary: summary,
        sectionOptions: sectionOptions,
        conditionFromRow: conditionFromRow,
        buildAchievement: buildAchievement,
        persistErrorMessage: persistErrorMessage
    };

    var root = typeof window !== 'undefined' ? window : globalThis;
    root.ChickadeeAchievementsCore = api;
    // Node export for the .mjs unit tests.
    if (typeof module === 'object' && module.exports) {
        module.exports = api;
    }
}());
