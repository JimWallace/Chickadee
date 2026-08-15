// Shared client-side column sorting for any <table class="sortable-table">.
//
// Markup contract:
//
//   <table class="results-table sortable-table"
//          data-sort-initial="last-seen:desc"      (optional) sort on load
//          data-sort-tiebreak="username">          (optional) stable ordering
//     <thead><tr>
//       <th data-sort-key="last-seen" data-sort-type="text|number|date|duration">
//         <button class="sort-header" type="button">Last seen</button>
//       </th> …
//     <tbody><tr>
//       <td data-sort-value="<raw>">formatted</td> …
//
// A cell's sort value is the first of: `data-sort-value`, `data-iso` (the
// relative-time convention — one attribute serves both rendering and
// sorting), a contained <select>'s VALUE (a role dropdown's option labels are
// not what you sort by), then its text.
//
// This is the MACHINE value, and it is deliberately not what list-filter.js
// reads. You sort the Last Seen column by its ISO timestamp and filter it by
// the "2 hours ago" a reader can see; only the <select> case is common to
// both. The comment here used to claim the filter shared this rule outright,
// while the filter implemented one of these four cases — so the two files
// asserted a shared rule neither could have satisfied. They diverge on
// purpose; each says so now.
//
// `data-sort-key` names a column for `data-sort-initial` / `data-sort-tiebreak`
// so both survive conditionally-rendered columns, where an index would not.
// Clicking a header toggles asc/desc; the th carries `aria-sort` and the
// .sort-asc/.sort-desc classes the ↕/↑/↓ glyph hangs off (styles.css).
//
// Keyboard support is free: the affordance is a real <button>. This replaced
// five page-local implementations (UI audit S2) that had each grown their own
// value rules, tie-breaks and keyboard handling; the union of what they did
// lives here, and `apply()` is the piece none of them could share — a page
// that repaints its tbody from a poll calls it to restore the user's sort.
(function (global) {
    'use strict';

    var collator = new Intl.Collator(undefined, { sensitivity: 'base', numeric: true });

    // Per-table sort state, so a repaint can restore what the user chose.
    // Keyed by the table element itself (a WeakMap: a removed table's entry
    // goes with it).
    var state = new WeakMap();

    function headersOf(table) {
        return Array.prototype.slice.call(table.querySelectorAll('thead th'));
    }

    function cellValue(cell) {
        if (!cell) return '';
        var explicit = cell.getAttribute('data-sort-value');
        if (explicit !== null) return explicit;
        var iso = cell.getAttribute('data-iso');
        if (iso !== null) return iso;
        var select = cell.querySelector ? cell.querySelector('select') : null;
        if (select) return select.value || '';
        return (cell.textContent || '').trim();
    }

    // Numbers embedded in text ("12/15 passed" → 12; "1.4" → 1.4). A cell with
    // no number at all sorts as the smallest value rather than as 0, so blanks
    // never interleave with real data.
    function numericValue(raw) {
        if (raw === '' || raw === null || raw === undefined) return Number.NEGATIVE_INFINITY;
        var direct = Number(raw);
        if (Number.isFinite(direct)) return direct;
        var match = String(raw).match(/-?\d+(\.\d+)?/);
        return match ? Number(match[0]) : Number.NEGATIVE_INFINITY;
    }

    function dateValue(raw) {
        if (!raw) return Number.NEGATIVE_INFINITY;
        // An epoch integer is a legitimate sort value (some tables carry the
        // parsed timestamp rather than the ISO string).
        if (/^\d{4,}$/.test(String(raw).trim())) return Number(raw);
        var t = new Date(raw).getTime();
        return Number.isNaN(t) ? Number.NEGATIVE_INFINITY : t;
    }

    function compare(a, b, sortType) {
        if (sortType === 'number' || sortType === 'duration') {
            return numericValue(a) - numericValue(b);
        }
        if (sortType === 'date' || sortType === 'datetime') {
            return dateValue(a) - dateValue(b);
        }
        return collator.compare(String(a), String(b));
    }

    function indexOfKey(headers, key) {
        if (!key) return -1;
        for (var i = 0; i < headers.length; i += 1) {
            if (headers[i].getAttribute('data-sort-key') === key) return i;
        }
        return -1;
    }

    // Sort keys are read ONCE PER ROW, not once per comparison.
    //
    // cellValue() used to be called from inside the comparator, so a sort read
    // each row's cells ~2·log2(n) times over: measured at 17,050 cell reads and
    // the same number of querySelector calls for 1,000 rows (17x the 1,000 a
    // decorated sort needs), and 109,452 (21.9x) for 5,000. That is not a
    // click-time cost — data-sort-initial seeds the sort at load, so
    // table-poll.js re-runs this on every 5-second repaint of the roster and
    // users tables.
    //
    // Keys are deliberately NOT cached across sorts. A repaint replaces the
    // rows anyway (nothing to reuse), and the only case a cache would serve —
    // the user toggling direction on rows still in place — would hold a key
    // read before the page's own post-repaint decorations ran. One read per row
    // per sort is the honest version, and it is already the whole win.
    function sortBy(table, header, direction) {
        var tbody = table.querySelector('tbody');
        if (!tbody || !header) return;
        var headers = headersOf(table);
        var index = headers.indexOf(header);
        if (index < 0) return;

        var sortType = header.getAttribute('data-sort-type') || 'text';
        var tiebreakIndex = indexOfKey(headers, table.getAttribute('data-sort-tiebreak'));
        var useTiebreak = tiebreakIndex >= 0 && tiebreakIndex !== index;
        var rows = Array.prototype.slice.call(tbody.querySelectorAll('tr'));

        var decorated = rows.map(function (row) {
            return {
                row: row,
                key: cellValue(row.children[index]),
                tiebreak: useTiebreak ? String(cellValue(row.children[tiebreakIndex])) : ''
            };
        });

        decorated.sort(function (a, b) {
            var result = compare(a.key, b.key, sortType);
            if (result === 0 && useTiebreak) {
                result = collator.compare(a.tiebreak, b.tiebreak);
            }
            return direction === 'asc' ? result : -result;
        });

        // One insertion instead of n: appending each row moved it individually,
        // so a 5,000-row table did 5,000 separate DOM mutations per sort.
        // A fragment collects them and the tbody is touched once.
        if (typeof document !== 'undefined' && document.createDocumentFragment) {
            var fragment = document.createDocumentFragment();
            decorated.forEach(function (entry) { fragment.appendChild(entry.row); });
            tbody.appendChild(fragment);
        } else {
            decorated.forEach(function (entry) { tbody.appendChild(entry.row); });
        }

        headers.forEach(function (th) {
            th.classList.remove('sort-asc', 'sort-desc');
            if (th.querySelector('.sort-header')) th.setAttribute('aria-sort', 'none');
        });
        header.classList.add(direction === 'asc' ? 'sort-asc' : 'sort-desc');
        header.setAttribute('aria-sort', direction === 'asc' ? 'ascending' : 'descending');
        state.set(table, { header: header, direction: direction });
    }

    /// Re-apply the table's current sort — for pages that rebuild their rows
    /// from a background poll. A no-op on a table nobody has sorted yet.
    function apply(table) {
        if (!table) return;
        var current = state.get(table);
        if (current && current.header) sortBy(table, current.header, current.direction);
    }

    function enhance(table) {
        var headers = headersOf(table);
        headers.forEach(function (th) {
            var button = th.querySelector('.sort-header');
            if (!button) return;
            th.setAttribute('aria-sort', 'none');
            button.addEventListener('click', function () {
                var current = state.get(table);
                var direction = (current && current.header === th && current.direction === 'asc')
                    ? 'desc' : 'asc';
                sortBy(table, th, direction);
            });
        });

        // data-sort-initial="<key>:asc|desc" — the load-time sort, declared in
        // markup so a page needs no script of its own to open on "newest first".
        var initial = (table.getAttribute('data-sort-initial') || '').split(':');
        var initialIndex = indexOfKey(headers, initial[0]);
        if (initialIndex >= 0) {
            sortBy(table, headers[initialIndex], initial[1] === 'desc' ? 'desc' : 'asc');
        }
    }

    function init() {
        document.querySelectorAll('.sortable-table').forEach(enhance);
    }

    global.ChickadeeSortableTable = { apply: apply, cellValue: cellValue, compare: compare };

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
        module.exports = global.ChickadeeSortableTable;
    }
})(typeof self !== 'undefined' ? self : this);
