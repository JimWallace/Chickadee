// Public/achievements-editor.js
//
// The single "Achievements" editor table (unification C2).  Every achievement —
// class goals, individual badges, and the built-in awards — is one row
// (Name / Kind / Summary / Edit / Remove).  Rows are edited in a <dialog> whose
// fields show/hide by kind.  Loads via GET and saves the whole typed list via
// PUT /instructor/:id/achievements (the unified `achievements` array).  No icon
// authoring (the generic badge rendering is used).

(function () {
    'use strict';

    // Kind labels come from the server-rendered #am-kind options (their
    // data-label attributes), so the Swift AchievementKindPresentation
    // registry is the single source of truth; populated in init().
    var KIND_LABEL = {};
    // Which modal fields apply to each kind.
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
        if (!tbody || !assignmentID) return;
        var url = '/instructor/' + encodeURIComponent(assignmentID) + '/achievements';
        var status = document.getElementById('achievements-status');
        var modal = document.getElementById('achievement-modal');
        var kindSel = document.getElementById('am-kind');
        if (kindSel) {
            Array.prototype.slice.call(kindSel.options).forEach(function (o) {
                KIND_LABEL[o.value] = o.getAttribute('data-label') || o.text;
            });
        }

        var state = [];
        var editingIndex = -1;

        function setStatus(text, kind) {
            if (!status) return;
            status.textContent = text || '';
            status.style.color = kind === 'error'
                ? 'var(--red)' : (kind === 'ok' ? 'var(--green)' : 'var(--gray-500)');
        }

        function render() {
            tbody.innerHTML = '';
            state.forEach(function (row, i) {
                var tr = document.createElement('tr');
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

        function fieldEl(name) { return document.getElementById('am-' + name); }

        function showFieldsFor(kind) {
            var fields = KIND_FIELDS[kind] || [];
            Array.prototype.slice.call(modal.querySelectorAll('.am-field')).forEach(function (el) {
                el.style.display = fields.indexOf(el.getAttribute('data-field')) >= 0 ? '' : 'none';
            });
        }

        function openModal(row, index) {
            editingIndex = index;
            document.getElementById('achievement-modal-title').textContent =
                index < 0 ? 'Add Achievement' : 'Edit Achievement';
            fieldEl('name').value = n(row.name);
            kindSel.value = row.kind || 'classGoal';
            ALL_FIELDS.forEach(function (f) { fieldEl(f).value = n(row[f]); });
            showFieldsFor(kindSel.value);
            if (modal.showModal) modal.showModal();
        }

        function applyModal() {
            var kind = kindSel.value;
            var row = { kind: kind, name: (fieldEl('name').value || '').trim() };
            if (editingIndex >= 0 && state[editingIndex] && state[editingIndex].id) {
                row.id = state[editingIndex].id;
            }
            (KIND_FIELDS[kind] || []).forEach(function (f) {
                var v = fieldEl(f).value;
                if (v === '') return;
                row[f] = NUM_FIELDS.indexOf(f) >= 0 ? Number(v) : v;
            });
            if (!row.name) return;
            if (editingIndex < 0) { state.push(row); } else { state[editingIndex] = row; }
            render();
        }

        if (kindSel) kindSel.addEventListener('change', function () { showFieldsFor(kindSel.value); });
        if (modal) {
            modal.addEventListener('close', function () {
                if (modal.returnValue === 'done') applyModal();
            });
        }

        var addBtn = document.getElementById('achievement-add');
        if (addBtn) {
            addBtn.addEventListener('click', function () { openModal({ kind: 'classGoal' }, -1); });
        }
        block.addEventListener('click', function (e) {
            var edit = e.target.closest && e.target.closest('.ach-edit');
            if (edit) {
                var ei = Number(edit.getAttribute('data-i'));
                openModal(state[ei] || {}, ei);
                return;
            }
            var rm = e.target.closest && e.target.closest('.ach-remove');
            if (rm) { state.splice(Number(rm.getAttribute('data-i')), 1); render(); }
        });

        var saveBtn = document.getElementById('achievements-save');
        if (saveBtn) {
            saveBtn.addEventListener('click', function () {
                setStatus('Saving…', null);
                fetch(url, {
                    method: 'PUT',
                    headers: { 'Content-Type': 'application/json', 'x-csrf-token': csrf() },
                    body: JSON.stringify({ achievements: state })
                }).then(function (r) {
                    if (r.ok) {
                        return r.json().then(function (body) {
                            state = (body && body.achievements) || [];
                            render();
                            setStatus('Saved.', 'ok');
                        }).catch(function () { setStatus('Saved.', 'ok'); });
                    }
                    return r.text().then(function (t) {
                        var msg = t || ('HTTP ' + r.status);
                        try { var p = JSON.parse(t); if (p && p.reason) msg = p.reason; } catch (_) { /* text */ }
                        setStatus('Save failed: ' + msg.slice(0, 240), 'error');
                    });
                }).catch(function (err) {
                    setStatus('Save failed: ' + (err && err.message ? err.message : err), 'error');
                });
            });
        }

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
