// Public/workbench-rail.js
//
// The workbench rail's test suite (notebook views NB6, frame 18c). It fetches
// the suite outline (`#wb-shell[data-suite-url]`, docs/notebook-guide.md, "The
// instructor's suite outline") and draws it into `#wb-rail-suite`:
//
//   - "3 checks · 5 pts";
//   - one group per section: "TASK 2" · "3 pts", then its items, each with a
//     glyph for its result on the solution and its name in mono;
//   - "NOT LINKED TO A CELL", then the items that link to no cell.
//
// A click on an item reveals its cell in the editor (`chickadee:reveal`). The
// rail draws again after a save, because a save re-validates. It writes
// nothing.

(function (global) {
    'use strict';

    var WORDS = { pass: 'Passes on the solution', fail: 'Fails on the solution', none: 'Not validated yet' };

    /// The item's state on the solution: `pass`, `fail` (any result that is
    /// not a pass) or `none`. Pure.
    function itemState(item) {
        var result = item && item.solution && item.solution.result;
        if (!result) return 'none';
        return result === 'pass' ? 'pass' : 'fail';
    }

    /// The glyph beside a state. Pure.
    function glyph(state) {
        return state === 'pass' ? '✓' : state === 'fail' ? '✗' : '○';
    }

    /// "3 checks · 5 pts". Pure.
    function totalsText(totals) {
        var checks = (totals && totals.checks) || 0;
        var points = (totals && totals.points) || 0;
        return checks + (checks === 1 ? ' check' : ' checks') + ' · ' + points + (points === 1 ? ' pt' : ' pts');
    }

    /// What a section's head says: its label, else its title, else "Other
    /// checks". Pure.
    function sectionCaption(section) {
        return section.label || section.title || 'Other checks';
    }

    /// What `chickadee:reveal` gets for an item, or null. Pure.
    function revealTarget(item) {
        var anchor = item && item.anchor;
        if (!anchor || !anchor.name) return null;
        return anchor.kind === 'section' ? { section: anchor.name } : { name: anchor.name };
    }

    var api = {
        itemState: itemState, glyph: glyph, totalsText: totalsText,
        sectionCaption: sectionCaption, revealTarget: revealTarget,
    };

    if (typeof document !== 'undefined' && typeof window !== 'undefined') {
        var el = function (tag, className, text) {
            var node = document.createElement(tag);
            if (className) node.className = className;
            if (text != null) node.textContent = text;
            return node;
        };

        var execute = function (command, args) {
            var run = window.chickadeeEditorCommand;
            return typeof run === 'function' ? run(command, args) : Promise.resolve(false);
        };

        var itemRow = function (item) {
            var state = itemState(item);
            var li = el('li');
            var row = el('button', 'outline-row');
            row.type = 'button';
            row.setAttribute('data-status', state);
            row.setAttribute('data-item-id', item.id);
            var mark = el('span', 'outline-glyph', glyph(state));
            mark.setAttribute('aria-hidden', 'true');
            row.appendChild(mark);
            row.appendChild(el('code', 'outline-name', item.name));
            row.appendChild(el('span', 'visually-hidden', ', ' + WORDS[state]));
            var target = revealTarget(item);
            if (target) {
                row.addEventListener('click', function () { void execute('chickadee:reveal', target); });
            } else {
                row.disabled = true;
            }
            li.appendChild(row);
            return li;
        };

        var group = function (caption, meta, items) {
            var box = el('div', 'rail-group');
            var head = el('div', 'rail-group-head');
            head.appendChild(el('h3', 'outline-caption', caption));
            if (meta) head.appendChild(el('span', 'card-meta', meta));
            box.appendChild(head);
            var list = el('ul', 'rail-links');
            items.forEach(function (item) { list.appendChild(itemRow(item)); });
            box.appendChild(list);
            return box;
        };

        var draw = function (outline) {
            var suite = document.getElementById('wb-rail-suite');
            var totals = document.getElementById('wb-rail-totals');
            if (!suite || !outline) return;
            if (totals) totals.textContent = totalsText(outline.totals);
            suite.textContent = '';
            (outline.sections || []).forEach(function (section) {
                if (!section.items.length && section.id == null) return;
                var points = section.points + (section.points === 1 ? ' pt' : ' pts');
                suite.appendChild(group(sectionCaption(section), points, section.items));
            });
            if ((outline.unlinked || []).length) {
                suite.appendChild(group('Not linked to a cell', null, outline.unlinked));
            }
        };

        var refresh = function () {
            var shell = document.getElementById('wb-shell');
            var url = shell && shell.getAttribute('data-suite-url');
            if (!url) return Promise.resolve(null);
            return fetch(url, { credentials: 'same-origin', headers: { Accept: 'application/json' } })
                .then(function (res) { return res.ok ? res.json() : null; })
                .then(function (outline) { draw(outline); return outline; })
                .catch(function () { return null; });
        };

        // A save re-validates, and a suite edit changes the items.
        window.addEventListener('chickadee:workbench', function () { void refresh(); });

        global.ChickadeeWorkbenchRail = { refresh: refresh };
        void refresh();
    }

    // Node export for the .mjs unit tests (Tests/BrowserRunnerJSTests).
    if (typeof module === 'object' && module.exports) {
        module.exports = api;
    }
})(typeof self !== 'undefined' ? self : this);
