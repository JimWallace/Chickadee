// Public/achievements-editor.js
//
// The single "Achievements" editor table (unification C2).  Every achievement —
// class goals, individual badges, and the built-in awards — is one row
// (Name / Kind / Summary / Edit / Remove).  Rows are edited inline in an
// accordion detail row (the same pattern as the suite editor: see
// expandInlineEditor in suite-table.js), whose fields show/hide by kind.
// Every Save and Remove persists immediately via PUT /instructor/:id/achievements
// (the unified `achievements` array) — there is no separate "Save Achievements"
// button.  No icon authoring (the generic badge rendering is used).

(function () {
    'use strict';

    // Kind labels come from the editor template's #am-kind options (their
    // data-label attributes), so the Swift AchievementKindPresentation
    // registry is the single source of truth; populated in init().
    var KIND_LABEL = {};
    // Which template fields apply to each kind.
    var KIND_FIELDS = {
        classGoal: ['thresholdPercent', 'classPercent', 'points'],
        thresholdBadge: ['thresholdPercent'],
        testBadge: ['testName'],
        firstTryPerfect: ['thresholdPercent', 'attemptThreshold'],
        comeback: ['jumpThresholdPercent'],
        persistence: ['thresholdPercent', 'attemptThreshold'],
        speedRun: ['thresholdPercent', 'timeThresholdMs'],
        classRecord: ['recordDimension']
    };
    var DIM_LABEL = {
        firstToSubmit: 'first to submit', firstToSolve: 'first to 100%',
        fastest: 'fastest run', shortest: 'fewest attempts'
    };
    var NUM_FIELDS = [
        'thresholdPercent', 'classPercent', 'points',
        'attemptThreshold', 'timeThresholdMs', 'jumpThresholdPercent'
    ];
    var ALL_FIELDS = [
        'thresholdPercent', 'classPercent', 'points', 'testName',
        'recordDimension', 'attemptThreshold', 'timeThresholdMs', 'jumpThresholdPercent'
    ];

    // Shared implementations (Public/chickadee-ui.js); local aliases keep
    // the call sites short.
    var csrf = ChickadeeUI.getCsrfToken;
    var esc = ChickadeeUI.escapeHtml;
    function n(v) { return v == null ? '' : v; }

    function summary(row) {
        switch (row.kind) {
            case 'classGoal':
                return '≥ ' + n(row.thresholdPercent) + '% by ' + n(row.classPercent)
                    + '% of class · +' + n(row.points) + ' pts';
            case 'thresholdBadge': return 'score ≥ ' + n(row.thresholdPercent) + '%';
            case 'testBadge': return esc(row.testName) + ' passes';
            case 'firstTryPerfect': return '100% within ' + n(row.attemptThreshold || 1) + ' attempt(s)';
            case 'comeback': return 'grade jumped ≥ ' + n(row.jumpThresholdPercent || 50) + ' pts';
            case 'persistence': return '100% after ≥ ' + n(row.attemptThreshold || 5) + ' attempts';
            case 'speedRun': return '100% under ' + n(row.timeThresholdMs || 2000) + ' ms';
            case 'classRecord': return 'record · ' + (DIM_LABEL[row.recordDimension] || n(row.recordDimension));
            default: return '';
        }
    }

    function init() {
        var block = document.getElementById('achievements-block');
        if (!block) return;
        var tbody = block.querySelector('tbody.achievements-body');
        var assignmentID = block.getAttribute('data-assignment-id') || '';
        var template = document.getElementById('achievement-editor-template');
        if (!tbody || !assignmentID || !template) return;
        var url = '/instructor/' + encodeURIComponent(assignmentID) + '/achievements';
        var status = document.getElementById('achievements-status');

        // Kind labels: read the template's <select> options so the Swift
        // AchievementKindPresentation registry stays the single source of truth.
        Array.prototype.slice.call(template.content.querySelectorAll('#am-kind option'))
            .forEach(function (o) { KIND_LABEL[o.value] = o.getAttribute('data-label') || o.text; });

        var state = [];
        var open = null;   // { index } of the currently-expanded editor, or null

        function setStatus(text, kind) {
            if (!status) return;
            status.textContent = text || '';
            status.style.color = kind === 'error'
                ? 'var(--red)' : (kind === 'ok' ? 'var(--green)' : 'var(--gray-500)');
        }

        function render() {
            open = null;   // tbody is about to be rebuilt; any open editor goes with it
            tbody.innerHTML = '';
            state.forEach(function (row, i) {
                var tr = document.createElement('tr');
                tr.setAttribute('data-i', i);
                tr.innerHTML =
                    '<td><strong>' + esc(row.name) + '</strong></td>'
                    + '<td>' + esc(KIND_LABEL[row.kind] || row.kind) + '</td>'
                    + '<td>' + summary(row) + '</td>'
                    + '<td class="time">'
                    + '<button type="button" class="btn action-btn ach-edit" data-i="' + i + '">Edit</button> '
                    + '<button type="button" class="btn action-btn action-danger ach-remove" data-i="' + i + '">Remove</button>'
                    + '</td>';
                tbody.appendChild(tr);
            });
        }

        // PUT the whole list; refresh local state from the server's reconciled
        // response.  Returns the fetch promise (rejects with an Error on !ok).
        function persist() {
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

        // Tear down the open inline editor and un-expand its parent row.
        function collapse() {
            if (!open) return;
            var detail = tbody.querySelector('tr.suite-detail-row');
            if (detail && detail.parentNode) detail.parentNode.removeChild(detail);
            var parent = tbody.querySelector('tr[data-i="' + open.index + '"]');
            if (parent) parent.classList.remove('suite-row-expanded');
            open = null;
        }

        // Open an accordion editor for state[index] (or index < 0 to add a new
        // achievement, whose editor is appended to the table). Re-clicking the
        // open row toggles it shut.
        function expand(index) {
            if (open && open.index === index) { collapse(); return; }
            collapse();

            var parent = index >= 0 ? tbody.querySelector('tr[data-i="' + index + '"]') : null;
            var row = index >= 0 ? (state[index] || {}) : { kind: 'classGoal' };

            var tr = document.createElement('tr');
            tr.className = 'suite-detail-row';
            var td = document.createElement('td');
            td.setAttribute('colspan', '4');
            var host = document.createElement('div');
            host.className = 'suite-detail-host';
            host.appendChild(template.content.cloneNode(true));

            var actions = document.createElement('div');
            actions.className = 'suite-detail-actions';
            var saveBtn = document.createElement('button');
            saveBtn.type = 'button';
            saveBtn.className = 'btn btn-primary btn-compact';
            saveBtn.textContent = 'Save';
            var cancelBtn = document.createElement('button');
            cancelBtn.type = 'button';
            cancelBtn.className = 'btn btn-compact';
            cancelBtn.textContent = 'Cancel';
            var st = document.createElement('span');
            st.className = 'suite-detail-status card-meta';
            actions.appendChild(saveBtn);
            actions.appendChild(cancelBtn);
            actions.appendChild(st);
            td.appendChild(host);
            td.appendChild(actions);
            tr.appendChild(td);

            if (parent) {
                parent.parentNode.insertBefore(tr, parent.nextSibling);
                parent.classList.add('suite-row-expanded');
            } else {
                tbody.appendChild(tr);
            }
            open = { index: index };

            // Field helpers are scoped to this host — only one editor is open
            // at a time, so the template's element ids resolve unambiguously.
            function fieldEl(name) { return host.querySelector('#am-' + name); }
            function showFieldsFor(kind) {
                var fields = KIND_FIELDS[kind] || [];
                Array.prototype.slice.call(host.querySelectorAll('.am-field')).forEach(function (el) {
                    el.style.display = fields.indexOf(el.getAttribute('data-field')) >= 0 ? '' : 'none';
                });
            }

            var kindSel = fieldEl('kind');
            fieldEl('name').value = n(row.name);
            kindSel.value = row.kind || 'classGoal';
            ALL_FIELDS.forEach(function (f) { var el = fieldEl(f); if (el) el.value = n(row[f]); });
            showFieldsFor(kindSel.value);
            kindSel.addEventListener('change', function () { showFieldsFor(kindSel.value); });

            saveBtn.addEventListener('click', function () {
                var kind = kindSel.value;
                var name = (fieldEl('name').value || '').trim();
                if (!name) {
                    st.textContent = 'Name is required.';
                    st.classList.add('suite-detail-status-error');
                    return;
                }
                var next = { kind: kind, name: name };
                if (index >= 0 && state[index] && state[index].id) next.id = state[index].id;
                (KIND_FIELDS[kind] || []).forEach(function (f) {
                    var v = fieldEl(f).value;
                    if (v === '') return;
                    next[f] = NUM_FIELDS.indexOf(f) >= 0 ? Number(v) : v;
                });

                // Apply optimistically, persist, then rebuild from the server's
                // reconciled list; roll back the local state on failure.
                var snapshot = state.slice();
                if (index < 0) { state.push(next); } else { state[index] = next; }
                st.textContent = 'Saving…';
                st.classList.remove('suite-detail-status-error');
                saveBtn.disabled = true;
                persist()
                    .then(function () { collapse(); render(); setStatus('Saved.', 'ok'); })
                    .catch(function (err) {
                        state = snapshot;
                        st.textContent = 'Save failed — ' + ((err && err.message) ? err.message : err);
                        st.classList.add('suite-detail-status-error');
                        saveBtn.disabled = false;
                    });
            });
            cancelBtn.addEventListener('click', collapse);

            if (tr.scrollIntoView) tr.scrollIntoView({ block: 'nearest' });
        }

        var addBtn = document.getElementById('achievement-add');
        if (addBtn) addBtn.addEventListener('click', function () { expand(-1); });

        block.addEventListener('click', function (e) {
            var edit = e.target.closest && e.target.closest('.ach-edit');
            if (edit) { expand(Number(edit.getAttribute('data-i'))); return; }
            var rm = e.target.closest && e.target.closest('.ach-remove');
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
            .then(function (r) { return r.ok ? r.json() : { achievements: [] }; })
            .then(function (body) { state = (body && body.achievements) || []; render(); })
            .catch(function () { render(); });
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
