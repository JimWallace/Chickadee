// Shared live filtering for list tables (UI audit S1; re-engineered 2026-08).
//
// A page declares one thing — the table this input filters:
//
//   <span class="filter-group">
//     <label class="filter-label" for="enrolled-filter">Filter</label>
//     <input id="enrolled-filter" class="form-input filter-input" type="search"
//            placeholder="Filter by name or username…"
//            data-list-filter="enrolled-students-table"
//            data-list-filter-empty="No students match this filter.">
//   </span>
//
// Everything else is derived here: which columns are searchable, the result
// count, the no-match message, autofill suppression, aria-controls. The two
// GET-form filters (activity, audit) carry no data-list-filter — they get the
// suppression and the Escape-clears binding, and the server does the filtering.
//
// ── What is matched ─────────────────────────────────────────────────────────
//
// SEARCHABLE COLUMNS ARE THE ONES THE TABLE DECLARES SORTABLE — a `th` with
// `data-sort-key`. Whole-row textContent matched markup the user cannot see: on
// instructor-students a *pending* row's Actions cell holds a collapsed
// registration panel, so on a STUDENTS roster the query "student" matched every
// pending row through the label "Student number (optional)", and "email" matched
// them too. That is the same defect as the pre-S1 "ta" bug (a role <select>'s
// option labels are all row text) — which was fixed as a special case. This is
// the general rule it was an instance of: match the row's DATA, not its markup.
// Deriving the column set from data-sort-key rather than a new per-page list
// reuses a convention the table already states, and the two agree today: every
// data column carries one and the trailing Actions column is the only one that
// does not. A table declaring no sort keys at all falls back to every cell, so a
// plain table still filters.
//
// A cell contributes WHAT IT DISPLAYS: a <select> contributes its selected
// option, everything else its text. Deliberately NOT sortable-table.js's
// cellValue(), whose first two rules are `data-sort-value` and `data-iso` — you
// sort the Last Seen column by its ISO timestamp and filter it by the "2 hours
// ago" the user can actually see. The two components' rules diverge on purpose;
// only the <select> case is common to both.
//
// Terms are whitespace-separated and ANDed, each matching ANY cell: "lovelace
// ada" finds Ada Lovelace (one joined string could not), and no query matches
// across a cell boundary. Text is folded to lowercase with diacritics stripped,
// so "Munoz" finds "Muñoz" — on a real roster that is not an edge case.
//
// ── What is reported ────────────────────────────────────────────────────────
//
// The component owns both. Filtering to nothing used to leave a silent empty
// table on all three pages: instructor-students' own empty-state message counts
// tbody rows, filtered ones included, so it stayed hidden exactly when it was
// needed, and the other two have no such message at all. A `role="status"` count
// rides along, because rows disappearing is otherwise invisible to a screen
// reader. Both are empty/hidden while the box is empty, so an unfiltered page
// looks exactly as it did.
//
// Escape clears the box: `type=search` renders a native ✕ on Chromium and
// WebKit but not Firefox, and the keyboard affordance is free.
//
// State is deliberately not persisted (no URL, no sessionStorage). A stale
// filter that hides most of a roster is a worse failure than retyping it.
//
// ── Speed ───────────────────────────────────────────────────────────────────
//
// Folded cell text is cached in a WeakMap keyed by the <tr>. A poll repaint
// replaces tbody.innerHTML, so its rows are new nodes and every stale entry
// becomes unreachable — invalidation costs nothing and cannot go stale.
// `hidden` is written only when it changes, and a narrowing keystroke (the new
// query extends the last one over the same rows) skips the string work for rows
// already hidden, since no such row can come back.
(function (global) {
    'use strict';

    var COMBINING_MARKS = /[\u0300-\u036f]/g;
    var WHITESPACE = /\s+/;
    var DEFAULT_EMPTY_MESSAGE = 'Nothing matches this filter.';

    // <tr> → folded text, one string per searchable cell.
    var rowCache = new WeakMap();
    // table → searchable column indices ([] = no declared data columns).
    var columnCache = new WeakMap();
    // input → the previous pass, for the narrowing shortcut.
    var passCache = new WeakMap();
    // input → its lazily created status / no-match elements.
    var chromeCache = new WeakMap();

    function fold(value) {
        return String(value === null || value === undefined ? '' : value)
            .normalize('NFD').replace(COMBINING_MARKS, '').toLowerCase();
    }

    function tableFor(input) {
        var id = input.getAttribute('data-list-filter');
        return id ? document.getElementById(id) : null;
    }

    function searchableColumns(table) {
        var cached = columnCache.get(table);
        if (cached) return cached;
        var indices = [];
        var headers = table.querySelectorAll ? table.querySelectorAll('thead th') : [];
        for (var i = 0; i < headers.length; i += 1) {
            if (headers[i].getAttribute('data-sort-key') !== null) indices.push(i);
        }
        columnCache.set(table, indices);
        return indices;
    }

    // What the cell shows: a <select>'s selected option, else the text. The
    // fallback to .value covers a select with no selectedOptions.
    function cellText(cell) {
        if (!cell) return '';
        var select = cell.querySelector ? cell.querySelector('select') : null;
        if (select) {
            var picked = select.selectedOptions && select.selectedOptions[0];
            return picked ? (picked.text || '') : (select.value || '');
        }
        return cell.textContent || '';
    }

    function foldedCells(row, indices) {
        var cached = rowCache.get(row);
        if (cached) return cached;
        var cells = row.cells && row.cells.length ? row.cells : null;
        var parts = [];
        if (!cells) {
            parts.push(fold(row.textContent));
        } else if (indices.length) {
            for (var i = 0; i < indices.length; i += 1) parts.push(fold(cellText(cells[indices[i]])));
        } else {
            for (var j = 0; j < cells.length; j += 1) parts.push(fold(cellText(cells[j])));
        }
        rowCache.set(row, parts);
        return parts;
    }

    // Every term must match at least one cell.
    function matchesTerms(parts, terms) {
        for (var t = 0; t < terms.length; t += 1) {
            var found = false;
            for (var p = 0; p < parts.length; p += 1) {
                if (parts[p].indexOf(terms[t]) !== -1) { found = true; break; }
            }
            if (!found) return false;
        }
        return true;
    }

    // The status span and the no-match paragraph, created on first use so a
    // page declares neither. .filter-status is styled; the message reuses the
    // global .empty look and takes a js- hook, since it adds no styling of its
    // own. JS mints structure only.
    function chromeFor(input, table) {
        var chrome = chromeCache.get(input);
        if (chrome) return chrome;
        chrome = { status: null, message: null };
        if (typeof document !== 'undefined' && document.createElement) {
            var group = input.parentNode;
            if (group && group.appendChild) {
                chrome.status = document.createElement('span');
                chrome.status.className = 'filter-status';
                chrome.status.setAttribute('role', 'status');
                chrome.status.setAttribute('aria-live', 'polite');
                group.appendChild(chrome.status);
            }
            var anchor = (table.closest && table.closest('.table-scroll')) || table;
            if (anchor.parentNode && anchor.parentNode.insertBefore) {
                chrome.message = document.createElement('p');
                chrome.message.className = 'empty js-filter-no-match';
                chrome.message.textContent =
                    input.getAttribute('data-list-filter-empty') || DEFAULT_EMPTY_MESSAGE;
                chrome.message.hidden = true;
                anchor.parentNode.insertBefore(chrome.message, anchor.nextSibling);
            }
        }
        chromeCache.set(input, chrome);
        return chrome;
    }

    function report(input, table, shown, total, filtering) {
        // Nothing is minted until a filter is actually typed. table-poll.js
        // calls apply() every few seconds on the users and students pages, so
        // creating the chrome unconditionally would add an empty span (and its
        // flex gap) to a page nobody has filtered.
        var chrome = chromeCache.get(input);
        if (!chrome && !filtering) return;
        chrome = chrome || chromeFor(input, table);
        if (chrome.status) {
            chrome.status.textContent = filtering ? ('Showing ' + shown + ' of ' + total) : '';
        }
        if (chrome.message) {
            chrome.message.hidden = !(filtering && shown === 0 && total > 0);
        }
    }

    /// Re-run the filter over the table's current rows. Pages that repaint from
    /// a poll call this afterwards (table-poll.js does, in a fixed order after
    /// the relative times and the sort).
    function apply(input) {
        if (!input) return;
        var table = tableFor(input);
        var tbody = table ? table.querySelector('tbody') : null;
        if (!tbody) return;

        var rows = tbody.querySelectorAll('tr');
        var indices = searchableColumns(table);
        var query = fold(input.value).trim();
        var terms = query ? query.split(WHITESPACE) : [];
        var filtering = terms.length > 0;

        // Narrowing: the same rows, and a query that extends the last one. A row
        // already hidden cannot match a stricter query, so skip its string work.
        var prev = passCache.get(input);
        var sameRows = !!prev && prev.count === rows.length && prev.first === rows[0];
        var narrowing = filtering && sameRows && !!prev.query && query.indexOf(prev.query) === 0;

        var shown = 0;
        for (var i = 0; i < rows.length; i += 1) {
            var row = rows[i];
            if (narrowing && row.hidden) continue;
            var visible = !filtering || matchesTerms(foldedCells(row, indices), terms);
            if (row.hidden !== !visible) row.hidden = !visible;
            if (visible) shown += 1;
        }

        passCache.set(input, { query: query, count: rows.length, first: rows[0] || null });
        report(input, table, shown, rows.length, filtering);
    }

    function enhance(input) {
        // Autofill suppression, on EVERY filter box. These are search fields
        // whose id and placeholder read as credential-ish to browser
        // heuristics, and autocomplete="off" alone is ignored by password
        // managers; readonly-until-first-focus is the one reliable suppression.
        // Owned here so no page hand-carries it — and so the GET-form filters
        // are not left with the weaker half, which is what happened when this
        // was scoped to inputs naming a table.
        if (!input.hasAttribute('autocomplete')) input.setAttribute('autocomplete', 'off');
        input.setAttribute('readonly', '');
        input.addEventListener('focus', function () {
            input.removeAttribute('readonly');
        }, { once: true });

        input.addEventListener('keydown', function (event) {
            if (event.key !== 'Escape' || !input.value) return;
            input.value = '';
            if (input.hasAttribute('data-list-filter')) apply(input);
        });

        if (!input.hasAttribute('data-list-filter')) return;
        input.setAttribute('aria-controls', input.getAttribute('data-list-filter'));
        input.addEventListener('input', function () { apply(input); });
    }

    function init() {
        document.querySelectorAll('input.filter-input').forEach(enhance);
    }

    global.ChickadeeListFilter = {
        apply: apply,
        enhance: enhance,
        fold: fold,
        cellText: cellText,
        matchesTerms: matchesTerms,
        searchableColumns: searchableColumns
    };

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
