// Page wiring for the instructor students roster (instructor-students.leaf):
// row-click navigation, the roster's own enrolled and pending counts, and the
// empty-state message — all re-applied after each background repaint by
// table-poll.js. LEARN readiness is rendered by the server from what the
// roster-readiness sweep stored, so nothing here checks it.  Extracted from the template's inline
// script block so it is linted and testable.
(function () {
    'use strict';

    var table = document.getElementById('enrolled-students-table');
    if (!table) return;
    var tbody = table.querySelector('tbody');
    var emptyMsg = document.getElementById('no-students-msg');
    var countEl = document.getElementById('enrolled-count');
    var pendingEl = document.getElementById('pending-count');

    function updateEmptyState() {
        if (emptyMsg) emptyMsg.hidden = tbody.querySelectorAll('tr').length > 0;
    }

    // Row-click navigation (delegated so it survives repaints).  data-href is
    // server-rendered and always an in-app path; resolving it against the
    // origin and requiring same-origin keeps a DOM-injected value from ever
    // becoming a javascript: or cross-site navigation (CodeQL, js/xss-through-dom).
    table.addEventListener('click', function (event) {
        var t = event.target;
        if (!(t instanceof Element)) return;
        if (t.closest('a') || t.closest('button') || t.closest('form')) return;
        var row = t.closest('tr.student-row-link');
        if (!row) return;
        var href = row.getAttribute('data-href');
        if (!href) return;
        var url;
        try { url = new URL(href, window.location.origin); } catch (_) { return; }
        if (url.origin === window.location.origin) window.location.href = url.href;
    });

    // The roster's own counts: enrolled students, and pending pre-enrolments
    // beside them. Staff live in their own list, so every row here is one or the
    // other. Reads a role cell the same way the filter and the sorter do (a
    // <select>'s value, else its text).
    function updateCount() {
        var rows = Array.from(tbody.querySelectorAll('tr'));
        var pending = rows.filter(function (row) {
            return row.classList.contains('student-row-pending');
        }).length;
        var enrolled = rows.filter(function (row) {
            if (row.classList.contains('student-row-pending')) return false;
            var cell = row.cells[2];
            if (!cell) return false;
            var sel = cell.querySelector('select');
            return (sel ? sel.value : (cell.textContent || '').trim()) === 'student';
        }).length;
        if (countEl) countEl.textContent = String(enrolled);
        if (pendingEl) pendingEl.textContent = String(pending);
    }

    // Re-decorate after each background repaint (table-poll.js has already
    // re-applied the shared relative-time / sort / filter behaviours).
    table.addEventListener('chickadee:table-repaint', function () {
        updateCount();
        updateEmptyState();
    });

    // ── Initial paint ────────────────────────────────────────────────
    // Sorting is declared in markup (data-sort-initial) and applied by
    // sortable-table.js on load.
    window.ChickadeeRelativeTime.applyRelativeTimes(document);
    updateEmptyState();
})();
