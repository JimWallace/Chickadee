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

(function () {
    'use strict';

    var SCOPE_LABEL = {
        individual: 'This student', classWide: 'The class', record: 'Class record'
    };
    var CMP_LABEL = { atLeast: '≥', atMost: '≤', equals: '=' };
    var DIM_LABEL = {
        firstToSubmit: 'first to submit', firstToSolve: 'first to 100%',
        fastest: 'fastest run', shortest: 'fewest attempts'
    };
    // signal value -> { label, unit, isTest }; populated from the condition
    // template's <option>s so AchievementSignalPresentation stays the single
    // source of truth.
    var SIGNAL_META = {};

    var csrf = ChickadeeUI.getCsrfToken;
    var esc = ChickadeeUI.escapeHtml;
    function n(v) { return v == null ? '' : v; }

    // One condition rendered as a human phrase for the table's Earned-when cell.
    function condPhrase(c) {
        var meta = SIGNAL_META[c.signal] || { label: c.signal, unit: '', isTest: false };
        if (meta.isTest) { return '“' + esc(c.testRef) + '” passes'; }
        var unit = meta.unit ? (meta.unit === '%' ? '%' : ' ' + meta.unit) : '';
        return esc(meta.label) + ' ' + (CMP_LABEL[c.comparator] || c.comparator)
            + ' ' + n(c.value) + unit;
    }

    function conditionsText(row) {
        var conds = row.conditions || [];
        if (!conds.length) { return 'always'; }
        var joiner = row.match === 'any' ? ' or ' : ' and ';
        return conds.map(condPhrase).join(joiner);
    }

    function summary(row) {
        if (row.scope === 'record') {
            return 'record · ' + (DIM_LABEL[row.recordDimension] || n(row.recordDimension));
        }
        if (row.scope === 'classWide') {
            return conditionsText(row) + ' · by ' + n(row.classPercent)
                + '% of class · +' + n(row.points) + (row.points === 1 ? ' pt' : ' pts');
        }
        return conditionsText(row);
    }

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

        Array.prototype.slice.call(condTemplate.content.querySelectorAll('.am-cond-signal option'))
            .forEach(function (o) {
                SIGNAL_META[o.value] = {
                    label: o.text, unit: o.getAttribute('data-unit') || '',
                    isTest: o.getAttribute('data-is-test') === 'true'
                };
            });

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
                    + '<td>' + esc(SCOPE_LABEL[row.scope] || row.scope) + '</td>'
                    + '<td>' + summary(row) + '</td>'
                    + '<td class="time">'
                    + ChickadeeUI.accordion.CARET_HTML + ' '
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
                        var msg = t || ('HTTP ' + r.status);
                        try { var p = JSON.parse(t); if (p && p.reason) msg = p.reason; } catch (_) { /* text */ }
                        throw new Error(msg.slice(0, 240));
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
            var finishNow = ChickadeeUI.accordion.close(o.detailRow, {
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
            var ref = rowEl.querySelector('.am-cond-testref');
            if (cond) {
                sig.value = cond.signal || 'grade';
                cmp.value = cond.comparator || 'atLeast';
                val.value = n(cond.value);
                ref.value = n(cond.testRef);
            }
            function sync() {
                var meta = SIGNAL_META[sig.value] || { unit: '', isTest: false };
                var isTest = meta.isTest;
                cmp.style.display = isTest ? 'none' : '';
                val.style.display = isTest ? 'none' : '';
                unit.style.display = isTest ? 'none' : '';
                ref.style.display = isTest ? '' : 'none';
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

            var parts = ChickadeeUI.accordion.build({ colspan: 4 });
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
            });

            saveBtn.addEventListener('click', function () {
                var name = (el('am-name').value || '').trim();
                if (!name) {
                    st.textContent = 'Name is required.';
                    st.classList.add('suite-detail-status-error');
                    return;
                }
                var scope = scopeSel.value;
                var next = { name: name, scope: scope, match: el('am-match').value };
                var detail = (el('am-detail').value || '').trim();
                if (detail) next.detail = detail;
                if (index >= 0 && state[index] && state[index].id) next.id = state[index].id;

                if (scope === 'record') {
                    next.recordDimension = el('am-recordDimension').value;
                } else {
                    next.conditions = Array.prototype.slice.call(
                        conditionsBox.querySelectorAll('.am-condition')).map(function (rowEl) {
                            var signal = rowEl.querySelector('.am-cond-signal').value;
                            var meta = SIGNAL_META[signal] || {};
                            if (meta.isTest) {
                                return {
                                    signal: signal, comparator: 'atLeast', value: 1,
                                    testRef: (rowEl.querySelector('.am-cond-testref').value || '').trim()
                                };
                            }
                            return {
                                signal: signal,
                                comparator: rowEl.querySelector('.js-am-cond-comparator').value,
                                value: Number(rowEl.querySelector('.am-cond-value').value || 0)
                            };
                        });
                    if (scope === 'classWide') {
                        next.classPercent = Number(el('am-classPercent').value || 0);
                        next.points = Number(el('am-points').value || 0);
                    }
                }

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

            ChickadeeUI.accordion.open(parts, parent);
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
