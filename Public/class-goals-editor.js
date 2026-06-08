// Public/class-goals-editor.js
//
// Wires the "Class Goals" card on the assignment edit page.  Each row is one
// class-wide goal: a name, a per-student grade threshold (%), the share of the
// class that must reach it (%), and the bonus points everyone who submitted
// earns once the class gets there.  Loads the current goals via GET and saves
// the whole list via PUT /instructor/:id/achievements.  Evaluation + display of
// these goals are server-side; this module is authoring only.

(function () {
    'use strict';

    function csrf() {
        var m = document.querySelector('meta[name="csrf-token"]');
        return m ? m.getAttribute('content') : '';
    }

    function escapeAttr(s) {
        return String(s == null ? '' : s)
            .replace(/&/g, '&amp;')
            .replace(/"/g, '&quot;')
            .replace(/</g, '&lt;');
    }

    function rowHTML(goal) {
        goal = goal || {};
        function v(x) { return x == null ? '' : String(x); }
        return ''
            + '<td><input type="text" class="form-input cg-name" value="' + escapeAttr(goal.name) + '" placeholder="e.g. 80% Mastery"></td>'
            + '<td><input type="number" class="form-input cg-threshold" min="0" max="100" value="' + escapeAttr(v(goal.thresholdPercent)) + '"></td>'
            + '<td><input type="number" class="form-input cg-class" min="0" max="100" value="' + escapeAttr(v(goal.classPercent)) + '"></td>'
            + '<td><input type="number" class="form-input cg-bonus" min="0" value="' + escapeAttr(v(goal.bonusPoints)) + '"></td>'
            + '<td class="time"><button type="button" class="btn action-btn action-danger cg-remove" title="Remove goal" aria-label="Remove goal">✕</button></td>';
    }

    function addRow(tbody, goal) {
        var tr = document.createElement('tr');
        tr.className = 'cg-row';
        tr.innerHTML = rowHTML(goal);
        tbody.appendChild(tr);
        return tr;
    }

    function buildPayload(tbody) {
        var rows = Array.prototype.slice.call(tbody.querySelectorAll('tr.cg-row'));
        var goals = [];
        rows.forEach(function (tr) {
            var name = (tr.querySelector('.cg-name').value || '').trim();
            if (!name) return;  // skip blank rows
            goals.push({
                name: name,
                thresholdPercent: Number(tr.querySelector('.cg-threshold').value || 0),
                classPercent: Number(tr.querySelector('.cg-class').value || 0),
                bonusPoints: Math.max(0, parseInt(tr.querySelector('.cg-bonus').value || 0, 10) || 0)
            });
        });
        return { goals: goals };
    }

    function init() {
        var block = document.getElementById('class-goals-block');
        if (!block) return;
        var tbody = block.querySelector('tbody.class-goals-body');
        var addBtn = document.getElementById('class-goal-add');
        var saveBtn = document.getElementById('class-goals-save');
        var status = document.getElementById('class-goals-status');
        var assignmentID = block.getAttribute('data-assignment-id') || '';
        if (!tbody || !assignmentID) return;
        var url = '/instructor/' + encodeURIComponent(assignmentID) + '/achievements';

        function setStatus(text, kind) {
            if (!status) return;
            status.textContent = text || '';
            status.style.color = kind === 'error'
                ? 'var(--red)'
                : (kind === 'ok' ? 'var(--green)' : 'var(--gray-500)');
        }

        // Load the current goals into rows.
        fetch(url, { headers: { 'x-csrf-token': csrf() } })
            .then(function (r) { return r.ok ? r.json() : { goals: [] }; })
            .then(function (body) {
                (body && body.goals ? body.goals : []).forEach(function (g) { addRow(tbody, g); });
            })
            .catch(function () { /* leave empty on load failure */ });

        if (addBtn) {
            addBtn.addEventListener('click', function () {
                var tr = addRow(tbody, {});
                var input = tr.querySelector('.cg-name');
                if (input) input.focus();
            });
        }

        block.addEventListener('click', function (e) {
            var btn = e.target.closest && e.target.closest('.cg-remove');
            if (btn && block.contains(btn)) {
                var tr = btn.closest('tr.cg-row');
                if (tr) tr.remove();
            }
        });

        if (saveBtn) {
            saveBtn.addEventListener('click', function () {
                setStatus('Saving…', null);
                fetch(url, {
                    method: 'PUT',
                    headers: { 'Content-Type': 'application/json', 'x-csrf-token': csrf() },
                    body: JSON.stringify(buildPayload(tbody))
                }).then(function (r) {
                    if (r.ok) { setStatus('Saved.', 'ok'); return; }
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
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
