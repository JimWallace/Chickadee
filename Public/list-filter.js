// Shared live filtering for list tables (UI audit S1).
//
// One implementation replaces the three drifted inline `applyFilter` copies
// (admin-users, instructor-students, assignment-submissions). An input opts
// in by naming its target table:
//
//   <input class="form-input filter-input" type="search"
//          data-list-filter="enrolled-students-table" …>
//
// Every <tbody> row is shown or hidden on a case-insensitive match against
// the row's text — except that a cell containing a <select> contributes the
// select's VALUE, not its text. That exception is the point of sharing this:
// two of the three inline copies matched raw row text, and a row whose role
// cell is a <select> contains every option label as text, so typing "ta"
// matched every row. The admin-users copy had the fix; now every consumer
// does.
//
// Pages that repaint their rows from a poll call
// `ChickadeeListFilter.apply(input)` afterwards (the ChickadeeRelativeTime
// convention). Empty-state messages stay the page's concern — "no rows at
// all" and "nothing matches" are different sentences.
//
// Autofill suppression covers EVERY .filter-input, live or GET-form. These
// are search fields whose id and placeholder look credential-ish to browser
// heuristics, and autocomplete="off" alone is ignored by password managers;
// readonly-until-first-focus is the one reliable suppression, owned here so
// pages stop hand-carrying it in markup. Scoping it to data-list-filter is
// what left the activity/audit boxes carrying a bare autocomplete="off" the
// component's own comment calls insufficient — two suppression strengths for
// one control. Live filtering still binds only where a target table is named.
(function (global) {
    'use strict';

    function rowMatchText(row) {
        var cells = row.cells && row.cells.length ? row.cells : null;
        if (!cells) return row.textContent || '';
        var parts = [];
        for (var i = 0; i < cells.length; i += 1) {
            var sel = cells[i].querySelector ? cells[i].querySelector('select') : null;
            parts.push(sel ? (sel.value || '') : (cells[i].textContent || ''));
        }
        return parts.join(' ');
    }

    function apply(input) {
        if (!input) return;
        var table = document.getElementById(input.getAttribute('data-list-filter') || '');
        var tbody = table ? table.querySelector('tbody') : null;
        if (!tbody) return;
        var query = (input.value || '').trim().toLowerCase();
        Array.prototype.forEach.call(tbody.querySelectorAll('tr'), function (row) {
            row.hidden = query ? !rowMatchText(row).toLowerCase().includes(query) : false;
        });
    }

    function enhance(input) {
        if (!input.hasAttribute('autocomplete')) input.setAttribute('autocomplete', 'off');
        input.setAttribute('readonly', '');
        input.addEventListener('focus', function () {
            input.removeAttribute('readonly');
        }, { once: true });
        if (input.hasAttribute('data-list-filter')) {
            input.addEventListener('input', function () { apply(input); });
        }
    }

    function init() {
        document.querySelectorAll('input.filter-input').forEach(enhance);
    }

    global.ChickadeeListFilter = { apply: apply, rowMatchText: rowMatchText, enhance: enhance };

    if (typeof document !== 'undefined') {
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', init);
        } else {
            init();
        }
    }

    // Node export for the .mjs unit tests (Tests/BrowserRunnerJSTests);
    // browsers take the global above.
    if (typeof module === 'object' && module.exports) {
        module.exports = global.ChickadeeListFilter;
    }
})(typeof self !== 'undefined' ? self : this);
