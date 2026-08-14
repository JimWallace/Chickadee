// Page wiring for the instructor students roster (instructor-students.leaf):
// the LEARN classlist reconciliation, row-click navigation, the roster's own
// student count, and the empty-state message — all re-applied after each
// background repaint by table-poll.js.  Extracted from the template's inline
// script block so it is linted and testable.
(function () {
    'use strict';

    var table = document.getElementById('enrolled-students-table');
    if (!table) return;
    var tbody = table.querySelector('tbody');
    var emptyMsg = document.getElementById('no-students-msg');
    var countEl = document.getElementById('enrolled-count');

    function updateEmptyState() {
        if (emptyMsg) emptyMsg.hidden = tbody.querySelectorAll('tr').length > 0;
    }

    // ── LEARN classlist reconciliation ───────────────────────────────
    // After a "Check against LEARN" run, rows whose student is no longer on
    // the LEARN classlist get a "not registered on LEARN" badge.  The id set
    // is kept in memory so the badges survive the 5s poll repaint.
    var learnNotOnLearn = new Set();
    var learnBtn = document.getElementById('learn-check-btn');
    var learnStatus = document.getElementById('learn-check-status');

    function applyLearnFlags() {
        Array.from(tbody.querySelectorAll('tr')).forEach(function (row) {
            var nameCell = row.cells[0];
            if (!nameCell) return;
            var existing = nameCell.querySelector('.learn-flag');
            if (existing) existing.remove();
            var id = row.getAttribute('data-student-id');
            if (id && learnNotOnLearn.has(id)) {
                var span = document.createElement('span');
                span.className = 'learn-flag';
                span.textContent = 'not registered on LEARN';
                span.title = 'Not on the LEARN classlist — remove if confirmed dropped';
                nameCell.appendChild(span);
            }
        });
    }

    async function checkAgainstLearn() {
        if (learnBtn) learnBtn.disabled = true;
        if (learnStatus) learnStatus.textContent = 'Checking against LEARN…';
        try {
            var res = await fetch('/instructor/students/learn-check', {
                headers: { 'Accept': 'application/json' },
                cache: 'no-store'
            });
            if (res.redirected || res.status === 401 || res.status === 403) {
                window.location.reload();
                return;
            }
            if (!res.ok) {
                if (learnStatus) learnStatus.textContent = 'LEARN check failed (HTTP ' + res.status + ').';
                return;
            }
            var data = await res.json();
            learnNotOnLearn = new Set(Array.isArray(data.notOnLearn) ? data.notOnLearn : []);
            applyLearnFlags();
            if (learnStatus) learnStatus.textContent = data.message || '';
        } catch (_) {
            if (learnStatus) learnStatus.textContent = 'LEARN check failed (network error).';
        } finally {
            if (learnBtn) learnBtn.disabled = false;
        }
    }

    if (learnBtn) learnBtn.addEventListener('click', checkAgainstLearn);

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

    // The roster's own count: students plus pending pre-enrolments, matching
    // the server's enrolledStudentCount — staff enrolled for testing appear in
    // the table but must not inflate the heading. Reads a role cell the same
    // way the filter and the sorter do (a <select>'s value, else its text).
    function updateCount() {
        if (!countEl) return;
        var n = Array.from(tbody.querySelectorAll('tr')).filter(function (row) {
            if (row.classList.contains('student-row-pending')) return true;
            var cell = row.cells[2];
            if (!cell) return false;
            var sel = cell.querySelector('select');
            return (sel ? sel.value : (cell.textContent || '').trim()) === 'student';
        }).length;
        countEl.textContent = String(n);
    }

    // Re-decorate after each background repaint (table-poll.js has already
    // re-applied the shared relative-time / sort / filter behaviours).
    table.addEventListener('chickadee:table-repaint', function () {
        updateCount();
        updateEmptyState();
        applyLearnFlags();
    });

    // ── Initial paint ────────────────────────────────────────────────
    // Sorting is declared in markup (data-sort-initial) and applied by
    // sortable-table.js on load.
    window.ChickadeeRelativeTime.applyRelativeTimes(document);
    updateEmptyState();
    applyLearnFlags();
})();
