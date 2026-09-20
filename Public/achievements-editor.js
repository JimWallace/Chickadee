// Public/achievements-editor.js
//
// The composable Achievements editor.  Every achievement — individual badges,
// collaborative class goals, and competitive records — is one row
// (Name / Scope / Earned-when / Edit / Remove).  Rows are edited inline in an
// accordion detail row (the suite editor's pattern, see expandInlineEditor in
// suite-table.js): the body is cloned from #achievement-editor-template and the
// instructor composes a scope + a list of typed conditions (combined all/any) +
// the scope's reward parameters.  Every Save and Remove persists immediately via
// PUT /instructor/:id/achievements (the unified `achievements` array) — there is
// no separate "Save Achievements" button.  No icon authoring (the generic badge
// rendering is used).
//
// The decisions (row summaries, which signals a scope offers, condition
// serialisation, what a Save refuses) live in achievements-editor-core.js,
// loaded before this file; what remains here is the DOM: element lookups,
// template cloning, event listeners and the fetches.

(function () {
    'use strict';

    var Core = ChickadeeAchievementsCore;
    // record dimension -> label, read off the "Ranked by" select's options so
    // RecordDimensionPresentation stays the single source of truth.  Filled
    // lazily: the select lives inside a <template> until the editor opens.
    var DIM_LABEL = null;
    function dimLabel(value) {
        if (!DIM_LABEL) {
            DIM_LABEL = {};
            var tpl = document.getElementById('achievement-editor-template');
            var root = tpl && tpl.content ? tpl.content : document;
            var opts = root.querySelectorAll('#am-recordDimension option');
            Array.prototype.forEach.call(opts, function (o) {
                DIM_LABEL[o.value] = o.textContent.trim().toLowerCase();
            });
        }
        return DIM_LABEL[value] || n(value);
    }
    // signal value -> every fact about the signal, read off the condition
    // template's <option> data attributes so AchievementSignalPresentation stays
    // the single source of truth.  Nothing per-signal is written here: a JS-side
    // table is exactly the drift the data attributes exist to prevent.
    var SIGNAL_META = {};

    /// What the core needs to phrase a row: the signal facts, the live
    /// section names, the HTML escaper and the dimension labels.
    function presenterCtx() {
        return { signalMeta: SIGNAL_META, sectionNames: sectionNames(), esc: esc, dimLabel: dimLabel };
    }

    // id -> name for the suite sections currently on the page.  Read live from
    // the suite editor's own DOM rather than a server-rendered copy, so a
    // section added or renamed without a page reload is named correctly here.
    // The two inputs a reference can use, keyed by the server-named control.
    // Hoisted so `sync` and the save serializer read one mapping: a third
    // control kind that edited only one of them would serialize from the wrong
    // element, silently.
    function refInputs(rowEl) {
        return {
            text: rowEl.querySelector('input.am-cond-ref'),
            sections: rowEl.querySelector('select.am-cond-ref')
        };
    }
    function refInput(rowEl, meta) {
        return refInputs(rowEl)[meta && meta.refControl] || null;
    }

    function sectionNames() {
        var out = {};
        Array.prototype.slice.call(
            document.querySelectorAll('#suite-sections .section-block')).forEach(function (b) {
                var id = b.getAttribute('data-section-id') || '';
                var label = b.querySelector('.section-view strong');
                if (id) { out[id] = label ? label.textContent.trim() : id; }
            });
        return out;
    }

    var csrf = ChickadeeUI.getCsrfToken;
    var esc = ChickadeeUI.escapeHtml;
    function n(v) { return v == null ? '' : v; }

    function init() {
        var block = document.getElementById('achievements-block');
        if (!block) return;
        var tbody = block.querySelector('tbody.achievements-body');
        var assignmentID = block.getAttribute('data-assignment-id') || '';
        var template = document.getElementById('achievement-editor-template');
        var condTemplate = document.getElementById('achievement-condition-template');
        if (!tbody || !assignmentID || !template || !condTemplate) return;
        var url = '/instructor/' + encodeURIComponent(assignmentID) + '/achievements';
        var status = document.getElementById('achievements-status');

        SIGNAL_META = Core.signalMetaFromOptions(
            condTemplate.content.querySelectorAll('.am-cond-signal option'));

        var state = [];
        // Until the initial GET succeeds, saving is disabled: persisting the
        // placeholder empty list would wipe every achievement on the server.
        var loaded = false;
        var open = null;          // { index, detailRow } of the open editor, or null
        var lingeringClose = null; // finishNow() of an in-flight animated collapse

        function setStatus(text, kind) {
            ChickadeeUI.setStatus(status, text, kind);
        }

        function render() {
            open = null;
            tbody.innerHTML = '';
            state.forEach(function (row, i) {
                var tr = document.createElement('tr');
                tr.setAttribute('data-i', i);
                tr.innerHTML =
                    '<td><strong>' + esc(row.name) + '</strong></td>'
                    + '<td>' + esc(Core.SCOPE_LABEL[row.scope] || row.scope) + '</td>'
                    + '<td>' + Core.summary(row, presenterCtx()) + '</td>'
                    + '<td class="time">'
                    + ChickadeeAccordion.CARET_HTML + ' '
                    + '<button type="button" class="btn action-btn js-ach-edit" data-i="' + i + '">Edit</button> '
                    + '<button type="button" class="btn action-btn action-danger js-ach-remove" data-i="' + i + '">Remove</button>'
                    + '</td>';
                tbody.appendChild(tr);
            });
        }

        // PUT the whole list; refresh local state from the reconciled response.
        function persist() {
            if (!loaded) {
                return Promise.reject(new Error(
                    'The achievements list never loaded — refresh the page before editing.'));
            }
            return fetch(url, {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json', 'x-csrf-token': csrf() },
                body: JSON.stringify({ achievements: state })
            }).then(function (r) {
                if (!r.ok) {
                    return r.text().then(function (t) {
                        throw new Error(Core.persistErrorMessage(t, r.status));
                    });
                }
                return r.json()
                    .then(function (body) { state = (body && body.achievements) || []; })
                    .catch(function () { /* keep optimistic state if body unparseable */ });
            });
        }

        // Animated collapse via the shared accordion helper.  `immediate`
        // tears down synchronously — used before opening another editor and
        // before render() (which rebuilds the tbody and would wipe the
        // animation anyway).
        function collapse(immediate) {
            if (!open) {
                if (lingeringClose) { var f = lingeringClose; lingeringClose = null; f(); }
                return;
            }
            var o = open;
            open = null;
            var parent = o.index >= 0 ? tbody.querySelector('tr[data-i="' + o.index + '"]') : null;
            var finishNow = ChickadeeAccordion.close(o.detailRow, {
                immediate: !!immediate,
                parentRow: parent,
                onDone: function () { lingeringClose = null; }
            });
            lingeringClose = immediate ? null : finishNow;
        }

        // Build one condition row inside `container` from an optional `cond`.
        function addConditionRow(container, cond) {
            container.appendChild(condTemplate.content.cloneNode(true));
            var rowEl = container.lastElementChild;
            var sig = rowEl.querySelector('.am-cond-signal');
            var cmp = rowEl.querySelector('.js-am-cond-comparator');
            var val = rowEl.querySelector('.am-cond-value');
            var unit = rowEl.querySelector('.am-cond-unit');
            var inputs = refInputs(rowEl);
            var textRef = inputs.text;
            var sectionRef = inputs.sections;
            // The core decides the option list: "Whole suite" first, then the
            // live sections, then a disabled home for a ref whose section was
            // deleted, so a stale ref cannot serialise as the whole suite.
            var stored = cond ? n(cond.sectionRef) : '';
            sectionRef.innerHTML = '';
            Core.sectionOptions(sectionNames(), stored).forEach(function (opt) {
                var o = document.createElement('option');
                o.value = opt.value;
                o.textContent = opt.label;
                if (opt.disabled) o.disabled = true;
                sectionRef.appendChild(o);
            });

            if (cond) {
                sig.value = cond.signal || 'grade';
                cmp.value = cond.comparator || 'atLeast';
                val.value = n(cond.value);
                textRef.value = n(cond.testRef);
                sectionRef.value = stored;
            }
            // A signal either compares a value, names a reference, or does both
            // (items-covered counts AND scopes).  refReplacesValue is what
            // distinguishes the third case from the second; refControl picks
            // which input the reference uses.
            // Signals that read the whole class are meaningless per student, so
            // the dropdown offers them only under the scope that can evaluate
            // them. Hidden AND disabled: `hidden` on an option is honoured
            // unevenly, and a disabled option cannot be chosen either way.
            function syncScope(scope) {
                var options = Array.prototype.slice.call(sig.options);
                options.forEach(function (o) {
                    var allowed = Core.isSignalAllowed(SIGNAL_META[o.value] || {}, scope);
                    o.hidden = !allowed;
                    o.disabled = !allowed;
                });
                sig.value = Core.signalForScope(
                    sig.value, options.map(function (o) { return o.value; }), SIGNAL_META, scope);
                sync();
            }
            rowEl.syncScope = syncScope;

            function sync() {
                var meta = SIGNAL_META[sig.value] || {};
                var active = refInput(rowEl, meta);
                var hasValue = !meta.refReplacesValue;
                cmp.style.display = hasValue ? '' : 'none';
                val.style.display = hasValue ? '' : 'none';
                unit.style.display = hasValue ? '' : 'none';
                [textRef, sectionRef].forEach(function (el) {
                    el.style.display = el === active ? '' : 'none';
                });
                textRef.placeholder = meta.refPlaceholder || '';
                if (active) { active.setAttribute('aria-label', meta.refLabel || 'Reference'); }
                unit.textContent = meta.unit || '';
            }
            sig.addEventListener('change', sync);
            rowEl.querySelector('.am-cond-remove').addEventListener('click', function () {
                rowEl.parentNode.removeChild(rowEl);
            });
            sync();
        }

        function expand(index) {
            if (open && open.index === index) { collapse(false); return; }
            collapse(true);

            var parent = index >= 0 ? tbody.querySelector('tr[data-i="' + index + '"]') : null;
            var row = index >= 0 ? (state[index] || {}) : { scope: 'individual' };

            var parts = ChickadeeAccordion.build({ colspan: 4 });
            var tr = parts.tr;
            var host = parts.host;
            var saveBtn = parts.saveBtn;
            var cancelBtn = parts.cancelBtn;
            var st = parts.status;
            host.appendChild(template.content.cloneNode(true));

            if (parent) {
                parent.parentNode.insertBefore(tr, parent.nextSibling);
            } else {
                tbody.appendChild(tr);
            }
            open = { index: index, detailRow: tr };

            function el(id) { return host.querySelector('#' + id); }
            var scopeSel = el('am-scope');
            var conditionsBox = el('am-conditions');

            function showScopeFields() {
                var scope = scopeSel.value;
                Array.prototype.slice.call(host.querySelectorAll('.js-am-scope-field')).forEach(function (f) {
                    var scopes = (f.getAttribute('data-scope') || '').split(/\s+/);
                    f.style.display = scopes.indexOf(scope) >= 0 ? '' : 'none';
                });
                // Each condition row filters its own signal dropdown to the
                // signals this scope can evaluate.
                Array.prototype.slice.call(
                    conditionsBox.querySelectorAll('.am-condition')).forEach(function (rowEl) {
                        if (rowEl.syncScope) { rowEl.syncScope(scope); }
                    });
            }

            el('am-name').value = n(row.name);
            el('am-detail').value = n(row.detail);
            scopeSel.value = row.scope || 'individual';
            el('am-match').value = row.match || 'all';
            el('am-classPercent').value = n(row.classPercent);
            el('am-points').value = n(row.points);
            el('am-recordDimension').value = row.recordDimension || 'firstToSolve';
            (row.conditions || []).forEach(function (c) { addConditionRow(conditionsBox, c); });
            showScopeFields();

            scopeSel.addEventListener('change', showScopeFields);
            el('am-add-condition').addEventListener('click', function () {
                addConditionRow(conditionsBox, null);
                showScopeFields();
            });

            saveBtn.addEventListener('click', function () {
                var conditions = Array.prototype.slice.call(
                    conditionsBox.querySelectorAll('.am-condition')).map(function (rowEl) {
                        var signal = rowEl.querySelector('.am-cond-signal').value;
                        var source = refInput(rowEl, SIGNAL_META[signal] || {});
                        return Core.conditionFromRow({
                            signal: signal,
                            comparator: rowEl.querySelector('.js-am-cond-comparator').value,
                            value: rowEl.querySelector('.am-cond-value').value,
                            refText: source ? source.value : ''
                        }, SIGNAL_META);
                    });
                var built = Core.buildAchievement({
                    name: el('am-name').value,
                    detail: el('am-detail').value,
                    scope: scopeSel.value,
                    match: el('am-match').value,
                    conditions: conditions,
                    classPercent: el('am-classPercent').value,
                    points: el('am-points').value,
                    recordDimension: el('am-recordDimension').value
                }, index >= 0 ? state[index] : null);
                if (!built.ok) {
                    st.textContent = built.error;
                    st.classList.add('suite-detail-status-error');
                    return;
                }
                var next = built.achievement;

                var snapshot = state.slice();
                if (index < 0) { state.push(next); } else { state[index] = next; }
                st.textContent = 'Saving…';
                st.classList.remove('suite-detail-status-error');
                saveBtn.disabled = true;
                persist()
                    .then(function () { collapse(true); render(); setStatus('Saved.', 'ok'); })
                    .catch(function (err) {
                        state = snapshot;
                        st.textContent = 'Save failed — ' + ((err && err.message) ? err.message : err);
                        st.classList.add('suite-detail-status-error');
                        saveBtn.disabled = false;
                    });
            });
            cancelBtn.addEventListener('click', function () { collapse(false); });

            ChickadeeAccordion.open(parts, parent);
        }

        var addBtn = document.getElementById('achievement-add');
        if (addBtn) addBtn.addEventListener('click', function () { expand(-1); });

        block.addEventListener('click', function (e) {
            var edit = e.target.closest && e.target.closest('.js-ach-edit');
            if (edit) { expand(Number(edit.getAttribute('data-i'))); return; }
            var rm = e.target.closest && e.target.closest('.js-ach-remove');
            if (rm) {
                var ri = Number(rm.getAttribute('data-i'));
                var snapshot = state.slice();
                state.splice(ri, 1);
                setStatus('Saving…', null);
                persist()
                    .then(function () { render(); setStatus('Saved.', 'ok'); })
                    .catch(function (err) {
                        state = snapshot;
                        setStatus('Remove failed: ' + ((err && err.message ? err.message : err)), 'error');
                    });
            }
        });

        fetch(url, { headers: { 'x-csrf-token': csrf() } })
            .then(function (r) {
                if (!r.ok) { throw new Error('HTTP ' + r.status); }
                return r.json();
            })
            .then(function (body) {
                state = (body && body.achievements) || [];
                loaded = true;
                render();
            })
            .catch(function (err) {
                // A failed load used to render an empty table whose next Save
                // PUT that emptiness wholesale, destroying every achievement.
                render();
                setStatus(
                    'Could not load achievements ('
                    + ((err && err.message) ? err.message : err)
                    + ') — editing is disabled; refresh the page.', 'error');
            });
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
