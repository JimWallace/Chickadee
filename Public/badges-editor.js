// Public/badges-editor.js
//
// Wires the "Badges" card on the assignment edit page. Each row authors an
// individual (per-student) badge: a caption, an emoji, and the condition that
// earns it — either a score threshold ("Score ≥ 90%") or a specific test
// passing. Loads via GET and saves the whole list via PUT
// /instructor/:id/badges. Evaluation + display are server-side; authoring only.

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

    // The Value cell means different things per kind: a percent for a score
    // threshold, a test filename for a test-pass badge.
    function valueFor(badge) {
        if (badge.kind === 'testBadge') return badge.testName == null ? '' : badge.testName;
        return badge.thresholdPercent == null ? '' : badge.thresholdPercent;
    }

    function placeholderFor(kind) {
        return kind === 'testBadge' ? 'secrettest_x.py' : '90';
    }

    function rowHTML(badge) {
        badge = badge || {};
        var kind = badge.kind === 'testBadge' ? 'testBadge' : 'thresholdBadge';
        function opt(v, label) {
            return '<option value="' + v + '"' + (kind === v ? ' selected' : '') + '>' + label + '</option>';
        }
        return ''
            + '<td><input type="text" class="form-input b-name" value="' + escapeAttr(badge.name) + '" placeholder="e.g. Sharpshooter"></td>'
            + '<td><input type="text" class="form-input b-icon" value="' + escapeAttr(badge.icon) + '" placeholder="🌟"></td>'
            + '<td><select class="form-input b-kind">'
            +     opt('thresholdBadge', 'Score ≥ (%)')
            +     opt('testBadge', 'Test passes')
            + '</select></td>'
            + '<td><input type="text" class="form-input b-value" value="' + escapeAttr(valueFor(badge)) + '" placeholder="' + placeholderFor(kind) + '"></td>'
            + '<td class="time"><button type="button" class="btn action-btn action-danger b-remove" title="Remove badge" aria-label="Remove badge">✕</button></td>';
    }

    function addRow(tbody, badge) {
        var tr = document.createElement('tr');
        tr.className = 'b-row';
        tr.innerHTML = rowHTML(badge);
        tbody.appendChild(tr);
        return tr;
    }

    function buildPayload(tbody) {
        var rows = Array.prototype.slice.call(tbody.querySelectorAll('tr.b-row'));
        var badges = [];
        rows.forEach(function (tr) {
            var name = (tr.querySelector('.b-name').value || '').trim();
            if (!name) return;  // skip blank rows
            var kind = tr.querySelector('.b-kind').value;
            var icon = (tr.querySelector('.b-icon').value || '').trim();
            var rawValue = (tr.querySelector('.b-value').value || '').trim();
            var badge = { name: name, kind: kind, icon: icon || null };
            if (kind === 'testBadge') {
                badge.testName = rawValue;
            } else {
                badge.thresholdPercent = Number(rawValue || 0);
            }
            badges.push(badge);
        });
        return { badges: badges };
    }

    function init() {
        var block = document.getElementById('badges-block');
        if (!block) return;
        var tbody = block.querySelector('tbody.badges-body');
        var addBtn = document.getElementById('badge-add');
        var saveBtn = document.getElementById('badges-save');
        var status = document.getElementById('badges-status');
        var assignmentID = block.getAttribute('data-assignment-id') || '';
        if (!tbody || !assignmentID) return;
        var url = '/instructor/' + encodeURIComponent(assignmentID) + '/badges';

        function setStatus(text, kind) {
            if (!status) return;
            status.textContent = text || '';
            status.style.color = kind === 'error'
                ? 'var(--red)'
                : (kind === 'ok' ? 'var(--green)' : 'var(--gray-500)');
        }

        fetch(url, { headers: { 'x-csrf-token': csrf() } })
            .then(function (r) { return r.ok ? r.json() : { badges: [] }; })
            .then(function (body) {
                (body && body.badges ? body.badges : []).forEach(function (b) { addRow(tbody, b); });
            })
            .catch(function () { /* leave empty on load failure */ });

        if (addBtn) {
            addBtn.addEventListener('click', function () {
                var tr = addRow(tbody, {});
                var input = tr.querySelector('.b-name');
                if (input) input.focus();
            });
        }

        // Keep the Value placeholder in step with the selected kind.
        block.addEventListener('change', function (e) {
            if (e.target && e.target.classList.contains('b-kind')) {
                var tr = e.target.closest('tr.b-row');
                var value = tr && tr.querySelector('.b-value');
                if (value) value.placeholder = placeholderFor(e.target.value);
            }
        });

        block.addEventListener('click', function (e) {
            var btn = e.target.closest && e.target.closest('.b-remove');
            if (btn && block.contains(btn)) {
                var tr = btn.closest('tr.b-row');
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
