// Page wiring for the instructor assignments dashboard (assignments.leaf):
// the diagnostic cards, section drag-reorder, section header edit mode,
// section delete, per-row copy-student-link buttons, and the publish form's
// UW-date warning.  Extracted from the template's inline script block so it
// is linted and testable.  Row/item drag-and-drop lives in
// Public/section-items-dnd.js; this file owns only the section-level pieces.
(function () {
    'use strict';

    // ── Dashboard diagnostic cards: headline + sparkline, click cycles ────────
    //   24h / 7d / 30d.  Polls /instructor/metrics/cards (course-scoped) and
    //   reuses the shared sparkline renderer + global card styles.
    (function initInstructorCards() {
        var cards = [
            { key: 'submissions', name: 'Submissions', valueEl: document.getElementById('idash-submissions'), unit: 'submission' },
            { key: 'activeStudents', name: 'Active students', valueEl: document.getElementById('idash-active-students') },
            { key: 'activeAssignments', name: 'Active assignments', valueEl: document.getElementById('idash-active-assignments') },
            { key: 'browserErrors', name: 'Browser errors', valueEl: document.getElementById('idash-browser-errors'), unit: 'error' }
        ].filter(function (c) { return c.valueEl; });
        if (!cards.length) return;

        var windowNouns = { '24h': 'last 24 hours', '1w': 'last 7 days', '1m': 'last 30 days' };
        var payload = null;
        var windowIndex = {};

        function unitLabel(unit) {
            return function (v) { return v + ' ' + unit + (v === 1 ? '' : 's'); };
        }

        function renderCard(card) {
            if (!payload || !card.cardEl) return;
            var idx = windowIndex[card.key] || 0;
            var win = payload.windows[idx % payload.windows.length];
            var data = win && win[card.key];
            if (!data) return;
            card.valueEl.textContent = data.headline == null ? '—' : String(data.headline);
            var chip = card.cardEl.querySelector('.diagnostic-window-chip');
            if (chip) chip.textContent = win.label;
            ChickadeeUI.renderSparkline(
                card.cardEl.querySelector('.diagnostic-spark'),
                data.series, win.bucketLabels || [],
                card.unit ? unitLabel(card.unit) : function (v) { return String(v); });
            card.cardEl.setAttribute(
                'aria-label',
                card.name + ', ' + (windowNouns[win.window] || win.label) + '. Press to change time window.');
        }

        cards.forEach(function (card) {
            card.cardEl = document.querySelector('.diagnostic-card[data-idash-card="' + card.key + '"]');
            windowIndex[card.key] = 0;
            if (!card.cardEl) return;
            function cycle() {
                if (!payload || !payload.windows.length) return;
                windowIndex[card.key] = (windowIndex[card.key] + 1) % payload.windows.length;
                renderCard(card);
            }
            card.cardEl.addEventListener('click', cycle);
            card.cardEl.addEventListener('keydown', function (e) {
                if (e.key !== 'Enter' && e.key !== ' ') return;
                e.preventDefault();
                cycle();
            });
        });

        async function refresh() {
            try {
                var res = await fetch('/instructor/metrics/cards', {
                    headers: { 'Accept': 'application/json', 'X-Background-Refresh': '1' },
                    cache: 'no-store'
                });
                if (!res.ok) return;
                payload = await res.json();
                cards.forEach(renderCard);
            } catch (_) {
                // Keep current values on transient polling errors.
            }
        }
        refresh();
        setInterval(refresh, 60000);
    }());

    var csrfToken = ChickadeeUI.getCsrfToken();

    // ── Section drag-and-drop (reorder sections) ──────────────────────────────
    var sectionsContainer = document.getElementById('sections-container');
    if (sectionsContainer) {
        var draggedSection = null;
        var sectionDragStartOrder = '';

        var currentSectionOrder = function () {
            return Array.from(sectionsContainer.querySelectorAll('.section-block[data-section-id]'))
                .map(function (el) { return el.getAttribute('data-section-id'); })
                .filter(Boolean);
        };

        var persistSectionOrderIfChanged = async function () {
            var order = currentSectionOrder();
            if (order.join(',') === sectionDragStartOrder) return;
            try {
                var res = await fetch('/instructor/sections/reorder', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json', 'x-csrf-token': csrfToken },
                    body: JSON.stringify({ sectionIDs: order })
                });
                if (!res.ok) window.location.reload();
            } catch (_) { window.location.reload(); }
        };

        // Track whether the most-recent mousedown was on a section drag handle,
        // so accidental drags on the pencil / buttons / name text don't reorder.
        var sectionDragHandleDown = false;
        sectionsContainer.addEventListener('mousedown', function (event) {
            var t = event.target;
            sectionDragHandleDown = !!(t instanceof Element && t.closest('.section-drag-handle'));
        });
        document.addEventListener('mouseup', function () {
            sectionDragHandleDown = false;
        });

        // Attach dragstart directly to each section header with stopPropagation.
        // This guarantees section-drag events NEVER reach the document-level
        // row-drag handler, and row-drag events NEVER trigger section logic.
        sectionsContainer.querySelectorAll('.section-header').forEach(function (header) {
            header.setAttribute('draggable', 'true');
            header.addEventListener('dragstart', function (event) {
                if (!sectionDragHandleDown) { event.preventDefault(); return; }
                event.stopPropagation(); // prevent reaching document.dragstart
                var block = header.closest('.section-block[data-section-id]');
                if (!block) return;
                draggedSection = block;
                sectionDragStartOrder = currentSectionOrder().join(',');
                block.classList.add('section-dragging');
                if (event.dataTransfer) {
                    event.dataTransfer.effectAllowed = 'move';
                    event.dataTransfer.setData('text/plain', block.getAttribute('data-section-id') || '');
                }
            });
        });

        sectionsContainer.addEventListener('dragover', function (event) {
            if (!draggedSection) return;
            event.preventDefault();
            var target = event.target;
            if (!(target instanceof Element)) return;
            var overBlock = target.closest('.section-block[data-section-id]');
            if (!overBlock || overBlock === draggedSection) return;
            var rect = overBlock.getBoundingClientRect();
            var after = event.clientY > rect.top + rect.height / 2;
            sectionsContainer.insertBefore(draggedSection, after ? overBlock.nextSibling : overBlock);
        });

        sectionsContainer.addEventListener('drop', function (event) {
            if (!draggedSection) return;
            event.preventDefault();
        });

        sectionsContainer.addEventListener('dragend', function () {
            if (!draggedSection) return;
            draggedSection.classList.remove('section-dragging');
            draggedSection = null;
            persistSectionOrderIfChanged();
        });
    }

    // ── Section edit mode ─────────────────────────────────────────────────────
    document.querySelectorAll('.section-edit-toggle').forEach(function (btn) {
        btn.addEventListener('click', function () {
            var header = btn.closest('.section-header');
            if (!header) return;
            header.querySelector('.section-view').style.display = 'none';
            var editDiv = header.querySelector('.section-edit');
            editDiv.style.display = 'flex';
            var input = editDiv.querySelector('.section-name-input');
            if (input) { input.focus(); input.select(); }
        });
    });

    document.querySelectorAll('.section-edit-cancel').forEach(function (btn) {
        btn.addEventListener('click', function () {
            var header = btn.closest('.section-header');
            if (!header) return;
            header.querySelector('.section-view').style.display = 'flex';
            header.querySelector('.section-edit').style.display = 'none';
        });
    });

    document.querySelectorAll('.section-delete-btn').forEach(function (btn) {
        btn.addEventListener('click', function () {
            var name = btn.getAttribute('data-name');
            var action = btn.getAttribute('data-action');
            if (!ChickadeeUI.confirmAction('Delete section “' + name + '”? Its assignments will become ungrouped.')) return;
            var form = document.createElement('form');
            form.method = 'post';
            form.action = action;
            document.body.appendChild(form);
            form.submit();
        });
    });

    // ── Copy student link ─────────────────────────────────────────────────────
    // Per-row buttons carry the assignment's vanity path on data-copy-url; the
    // "copied" cue is a transient class + title swap (no JS styling decision).
    document.body.addEventListener('click', function (event) {
        var btn = event.target instanceof Element ? event.target.closest('[data-copy-url]') : null;
        if (!btn) return;
        var url = window.location.origin + btn.getAttribute('data-copy-url');
        navigator.clipboard.writeText(url).then(function () {
            var prev = btn.title;
            btn.title = 'Copied!';
            btn.classList.add('action-copied');
            setTimeout(function () {
                btn.title = prev;
                btn.classList.remove('action-copied');
            }, 2000);
        });
    });

    // ── UWaterloo important-date proximity warning ────────────────────────────
    // Shared implementation (Public/chickadee-ui.js, loaded from base.leaf).
    // The compact publish form keeps its shorter label.
    document.querySelectorAll('.publish-due-date').forEach(function (input) {
        var warning = input.closest('form')?.querySelector('.publish-uw-warning');
        if (!warning) return;
        input.addEventListener('change', function () {
            ChickadeeUI.checkUWDates(input.value, warning, { label: 'Near:' });
        });
    });
})();
