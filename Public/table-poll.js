// Shared background refresh for a server-rendered table (UI audit S3).
//
//   <table class="results-table sortable-table" id="…"
//          data-poll-url="/instructor/students-data?fragment=rows"
//          data-poll-interval="5000">
//
// Every interval the table's <tbody> is replaced with freshly rendered rows
// fetched from `data-poll-url` — HTML the SERVER renders from the same Leaf
// partial the page itself used. Before this, three pages each rebuilt every
// row by concatenating HTML strings in an inline script, duplicating the
// markup (role <select>s, CSRF fields, icon SVGs, a whole register-student
// popover) in a second place that could drift from the template silently, and
// did.
//
// After a swap the shared row behaviours are re-applied in a fixed order —
// relative times, then sort, then filter — because each depends on the last:
// sorting a date column reads the timestamps, and filtering hides rows the
// sort has already ordered. Page-specific work (a count, a badge overlay)
// listens for the `chickadee:table-repaint` event rather than editing this
// file.
//
// Polling is suppressed while the tab is hidden, while focus is inside the
// table (a repaint would yank a half-open <select> away), while any <details>
// in the table is open (the pending-student registration panel is state the
// server cannot re-render), and while the table's filter box has focus.
// Requests carry `X-Background-Refresh: 1`, so a dashboard left open in a tab
// cannot keep a session alive — the one thing all three copies were supposed
// to do and one of them didn't.
//
// Each poll is CONDITIONAL: the rows carry an ETag and the next request sends
// it back, so an unchanged table answers 304 and nothing below runs at all.
// Before that, an idle roster replaced its own <tbody> twelve times a minute
// and rebuilt every derived behaviour from identical input.
(function (global) {
    'use strict';

    var DEFAULT_INTERVAL_MS = 5000;

    function filterInputFor(table) {
        if (!table.id) return null;
        return document.querySelector('input[data-list-filter="' + table.id + '"]');
    }

    function shouldSkip(table) {
        if (document.hidden) return true;
        if (table.contains(document.activeElement)) return true;
        // An open <details> is state the server does not know about: the
        // students table's pending-enrolment rows carry a registration panel,
        // and a repaint closes it mid-use. Focus alone did not cover this —
        // reading the panel, or clicking away to copy a value out of it, moves
        // focus off the table while the panel is still open and wanted.
        if (table.querySelector('details[open]')) return true;
        var filter = filterInputFor(table);
        return !!(filter && document.activeElement === filter);
    }

    // The ETag of the rows currently on screen, per table. A poll sends it back
    // as If-None-Match; a 304 means this tbody is already correct, so the whole
    // repaint — the innerHTML write, the relative-time pass, the re-sort, the
    // re-filter, the page's own decorations — is skipped rather than redone
    // with identical input. On an idle dashboard that is every poll.
    var etags = new WeakMap();

    function refresh(table) {
        var url = table.getAttribute('data-poll-url');
        var tbody = table.querySelector('tbody');
        if (!url || !tbody) return Promise.resolve(false);

        var headers = { 'Accept': 'text/html', 'X-Background-Refresh': '1' };
        var known = etags.get(table);
        if (known) headers['If-None-Match'] = known;

        return fetch(url, {
            headers: headers,
            // 'no-store' would forbid the conditional request this depends on;
            // 'no-cache' still revalidates on every poll, which is what a poll
            // is, but lets If-None-Match/304 do their job.
            cache: 'no-cache',
            credentials: 'same-origin'
        }).then(function (res) {
            // A redirect or an auth failure means the session ended server-side;
            // reload so the login page is what the user actually sees.
            if (res.redirected || res.status === 401 || res.status === 403) {
                window.location.reload();
                return null;
            }
            if (res.status === 304) return null;      // rows unchanged: nothing to do
            if (!res.ok) return null;
            var etag = res.headers && res.headers.get ? res.headers.get('ETag') : null;
            if (etag) etags.set(table, etag);
            return res.text();
        }).then(function (html) {
            if (html === null || html === undefined) return false;
            tbody.innerHTML = html;
            if (global.ChickadeeRelativeTime) {
                global.ChickadeeRelativeTime.applyRelativeTimes(tbody);
            }
            if (global.ChickadeeSortableTable) {
                global.ChickadeeSortableTable.apply(table);
            }
            if (global.ChickadeeListFilter) {
                global.ChickadeeListFilter.apply(filterInputFor(table));
            }
            table.dispatchEvent(new CustomEvent('chickadee:table-repaint', { bubbles: true }));
            return true;
        }).catch(function () {
            // Keep the rows already on screen: the next tick self-heals, and a
            // transient blip must not blank a roster someone is reading.
            return false;
        });
    }

    function start(table) {
        var interval = parseInt(table.getAttribute('data-poll-interval'), 10) || DEFAULT_INTERVAL_MS;
        setInterval(function () {
            if (shouldSkip(table)) return;
            refresh(table);
        }, interval);
    }

    function init() {
        document.querySelectorAll('table[data-poll-url]').forEach(start);
    }

    global.ChickadeeTablePoll = { refresh: refresh, shouldSkip: shouldSkip };

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
        module.exports = global.ChickadeeTablePoll;
    }
})(typeof self !== 'undefined' ? self : this);
