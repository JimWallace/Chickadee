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
// A click on an item selects it: the editor reveals its cell and opens its
// card (`chickadee:select-item`). The rail draws again after a save, because
// a save re-validates.
//
// It also hands the outline to the editor (`chickadee:set-suite`), which
// draws the test cards beside the cells (NB7), and answers the cards: Edit
// test opens the test in the suite sheet, Run again is Save & validate, Pin
// to a cell saves the pin (PUT /instructor/:id/suite-anchor), and a section
// action or Add check opens that section in the suite sheet.

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

    /// The item with `id`, in a section or among the unlinked. Pure.
    function findItem(outline, id) {
        var all = [];
        (outline.sections || []).forEach(function (section) { all = all.concat(section.items || []); });
        all = all.concat(outline.unlinked || []);
        for (var i = 0; i < all.length; i++) if (all[i].id === id) return all[i];
        return null;
    }

    /// An attribute value safe inside a quoted CSS selector. Pure.
    function cssEscape(value) {
        return String(value).replace(/["\\]/g, '\\$&');
    }

    var api = {
        itemState: itemState, glyph: glyph, totalsText: totalsText,
        sectionCaption: sectionCaption, revealTarget: revealTarget, findItem: findItem, cssEscape: cssEscape,
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

        var outline = null;
        var sentToEditor = false;

        var sendSuite = function () {
            if (!outline) return;
            sentToEditor = true;
            void execute('chickadee:set-suite', { suite: outline });
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
            if (revealTarget(item)) {
                row.addEventListener('click', function () {
                    markSelected(item.id);
                    void execute('chickadee:select-item', { itemID: item.id });
                });
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

        var draw = function (fresh) {
            outline = fresh;
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
                .then(function (fresh) {
                    draw(fresh);
                    sendSuite();
                    return fresh;
                })
                .catch(function () { return null; });
        };

        // A save re-validates, and a suite edit changes the items.
        window.addEventListener('chickadee:workbench', function () { void refresh(); });

        var markSelected = function (itemID) {
            var suite = document.getElementById('wb-rail-suite');
            if (!suite) return;
            Array.prototype.forEach.call(suite.querySelectorAll('.outline-row'), function (row) {
                if (itemID && row.getAttribute('data-item-id') === itemID) row.setAttribute('aria-current', 'true');
                else row.removeAttribute('aria-current');
            });
        };

        var status = function (text) {
            var node = document.getElementById('wb-save-status');
            if (node) node.textContent = text;
        };

        var openSuiteSheet = function () {
            var workbench = window.ChickadeeWorkbench;
            if (workbench && typeof workbench.openSheet === 'function') workbench.openSheet('suite');
        };

        var clickIn = function (scope, selector) {
            var node = scope && scope.querySelector(selector);
            if (node) node.click();
            return !!node;
        };

        /// Edit test: the item's own edit button in the suite table.
        var editTest = function (itemID) {
            var item = outline && findItem(outline, itemID);
            if (!item) return;
            openSuiteSheet();
            var sheet = document.getElementById('wb-sheet');
            var found = item.kind === 'script'
                ? clickIn(sheet, '.js-suite-edit-btn[data-filename="' + cssEscape(item.id) + '"]')
                : clickIn(sheet, 'tr[data-' + (item.kind === 'family' ? 'family' : 'check') + '-id="'
                    + cssEscape(item.generatorID || '') + '"] button[class*="edit-btn"]');
            if (!found) status('Open the suite table to edit this test');
        };

        /// A section's rename, delete or add check, in the suite table.
        var sectionAction = function (sectionID, action) {
            openSuiteSheet();
            var block = document.querySelector(
                '#wb-sheet .section-block[data-section-id="' + cssEscape(sectionID || '') + '"]');
            if (!block) {
                status('Open the suite table to change this section');
                return;
            }
            block.scrollIntoView({ block: 'start' });
            if (action === 'add-check') {
                clickIn(block, '.js-section-add-test-btn');
                return;
            }
            // Rename and Delete are both in the section's edit row. Delete asks
            // before it acts, as it does in the suite table.
            clickIn(block, '.js-section-edit-toggle');
            if (action === 'delete') clickIn(block, '.js-section-delete-btn');
            else {
                var input = block.querySelector('.section-name-input');
                if (input) input.focus();
            }
        };

        var pin = function (itemID, anchor) {
            var shell = document.getElementById('wb-shell');
            var meta = document.querySelector('meta[name="csrf-token"]');
            var assignmentID = shell && shell.getAttribute('data-assignment-id');
            if (!assignmentID) return Promise.resolve(false);
            return fetch('/instructor/' + encodeURIComponent(assignmentID) + '/suite-anchor', {
                method: 'PUT',
                credentials: 'same-origin',
                headers: {
                    'Content-Type': 'application/json',
                    'x-csrf-token': meta ? meta.getAttribute('content') : '',
                },
                body: JSON.stringify({ script: itemID, anchor: anchor }),
            }).then(function (res) {
                status(res.ok ? 'Pinned to ' + anchor : 'Could not pin the test');
                return refresh();
            }).catch(function () { status('Could not pin the test'); });
        };

        window.addEventListener('message', function (e) {
            if (!e || e.origin !== window.location.origin) return;
            var d = e.data;
            if (!d || typeof d.ck !== 'string') return;
            if (d.ck === 'kernel-diag' && d.kind === 'kernel_phase' && d.source === 'boot_start') {
                sentToEditor = false;
            } else if (d.ck === 'ck:kernel') {
                // The extension is up in this editor document.
                if (!sentToEditor) sendSuite();
            } else if (d.ck === 'ck:edit-test' && typeof d.itemID === 'string') {
                editTest(d.itemID);
            } else if (d.ck === 'ck:run-again') {
                var save = document.getElementById('wb-save');
                if (save) save.click();
            } else if (d.ck === 'ck:pin' && typeof d.itemID === 'string' && typeof d.anchor === 'string') {
                void pin(d.itemID, d.anchor);
            } else if (d.ck === 'ck:pin-refused') {
                status('That cell defines no name to pin to');
            } else if (d.ck === 'ck:section-action' && typeof d.action === 'string') {
                sectionAction(d.sectionID, d.action);
            } else if (d.ck === 'ck:item-selected') {
                markSelected(typeof d.itemID === 'string' ? d.itemID : null);
            } else if (d.ck === 'ck:add-check') {
                sectionAction(d.sectionID, 'add-check');
            }
        });

        global.ChickadeeWorkbenchRail = { refresh: refresh };
        void refresh();
    }

    // Node export for the .mjs unit tests (Tests/BrowserRunnerJSTests).
    if (typeof module === 'object' && module.exports) {
        module.exports = api;
    }
})(typeof self !== 'undefined' ? self : this);
