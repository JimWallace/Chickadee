// Public/builtin-awards-editor.js
//
// Wires the "Built-in Awards" card on the assignment edit page.  Lists the
// built-in awards (the per-submission Ace/Rally/Tenacious/Swift and the
// competitive Pathfinder/Trailblazer/Fastest/Minimalist class records) with an
// on/off checkbox each.  Loads via GET and saves the DISABLED set via PUT
// /instructor/:id/built-in-awards.  An instructor can, e.g., turn the
// competitive records off for a collaborative course.

(function () {
    'use strict';

    function csrf() {
        var m = document.querySelector('meta[name="csrf-token"]');
        return m ? m.getAttribute('content') : '';
    }

    function escapeHTML(s) {
        return String(s == null ? '' : s)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;');
    }

    var GROUP_LABEL = {
        perSubmission: 'Per-submission badges',
        classRecord: 'Class records (competitive)'
    };

    function renderRows(tbody, awards) {
        tbody.innerHTML = '';
        var lastGroup = null;
        awards.forEach(function (award) {
            if (award.group !== lastGroup) {
                lastGroup = award.group;
                var head = document.createElement('tr');
                head.className = 'builtin-awards-group';
                head.innerHTML = '<td colspan="3"><strong>'
                    + escapeHTML(GROUP_LABEL[award.group] || award.group) + '</strong></td>';
                tbody.appendChild(head);
            }
            var tr = document.createElement('tr');
            tr.className = 'builtin-award-row';
            tr.setAttribute('data-award-id', award.id);
            tr.innerHTML = ''
                + '<td><strong>' + escapeHTML(award.name) + '</strong></td>'
                + '<td>' + escapeHTML(award.detail) + '</td>'
                + '<td class="time"><input type="checkbox" class="ba-enabled"'
                + (award.enabled ? ' checked' : '') + '></td>';
            tbody.appendChild(tr);
        });
    }

    function disabledIDs(tbody) {
        var rows = Array.prototype.slice.call(tbody.querySelectorAll('tr.builtin-award-row'));
        var disabled = [];
        rows.forEach(function (tr) {
            var box = tr.querySelector('.ba-enabled');
            if (box && !box.checked) disabled.push(tr.getAttribute('data-award-id'));
        });
        return disabled;
    }

    function init() {
        var block = document.getElementById('builtin-awards-block');
        if (!block) return;
        var tbody = block.querySelector('tbody.builtin-awards-body');
        var saveBtn = document.getElementById('builtin-awards-save');
        var status = document.getElementById('builtin-awards-status');
        var assignmentID = block.getAttribute('data-assignment-id') || '';
        if (!tbody || !assignmentID) return;
        var url = '/instructor/' + encodeURIComponent(assignmentID) + '/built-in-awards';

        function setStatus(text, kind) {
            if (!status) return;
            status.textContent = text || '';
            status.style.color = kind === 'error'
                ? 'var(--red)'
                : (kind === 'ok' ? 'var(--green)' : 'var(--gray-500)');
        }

        fetch(url, { headers: { 'x-csrf-token': csrf() } })
            .then(function (r) { return r.ok ? r.json() : { awards: [] }; })
            .then(function (body) { renderRows(tbody, (body && body.awards) || []); })
            .catch(function () { /* leave empty on load failure */ });

        if (saveBtn) {
            saveBtn.addEventListener('click', function () {
                setStatus('Saving…', null);
                fetch(url, {
                    method: 'PUT',
                    headers: { 'Content-Type': 'application/json', 'x-csrf-token': csrf() },
                    body: JSON.stringify({ disabled: disabledIDs(tbody) })
                }).then(function (r) {
                    if (r.ok) {
                        return r.json().then(function (body) {
                            renderRows(tbody, (body && body.awards) || []);
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
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
