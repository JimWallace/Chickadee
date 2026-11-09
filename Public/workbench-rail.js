// @ts-check
// Public/workbench-rail.js
//
// The workbench rail's test suite (notebook views NB6, frame 18c). It fetches
// the suite outline (`#wb-shell[data-suite-url]`, docs/notebook-guide.md, "The
// instructor's suite outline") and draws it into `#wb-rail-suite`:
//
//   - "3 checks · 5 pts";
//   - one group per section: "TASK 2" · "3 pts", then its items, each with a
//     glyph for its result on the solution (amber when the starter passes it
//     too, NB8) and its name in mono;
//   - "NOT LINKED TO A CELL", then the items that link to no cell.
//
// A click on an item selects it: the editor reveals its cell and opens its
// card (`chickadee:select-item`). The rail draws again after a save, because
// a save re-validates, and it asks again while the validation is pending, so
// the pill moves off "Validating…" when the runner reports.
//
// It also hands the outline to the editor (`chickadee:set-suite`), which
// draws the test cards beside the cells (NB7), and answers the cards: Edit
// test opens the test in the suite sheet, Run again is Save & validate, Pin
// to a cell saves the pin (PUT /instructor/:id/suite-anchor), and a section
// action or Add check opens that section in the suite sheet.
//
// The app bar's pill (NB8) counts the issues: tests that fail on the
// solution, and tests worth points that pass on the starter. With issues, the
// pill is a button, and each click selects the next issue.

(function (/** @type {any} */ global) {
    'use strict';

    var WORDS = {
        pass: 'Passes on the solution',
        fail: 'Fails on the solution',
        starter: 'Passes on the starter too',
        none: 'Not validated yet',
    };

    /// The item's state: `fail` (any result on the solution that is not a
    /// pass), `starter` (passes on the solution and on the starter, for
    /// points), `pass` or `none`. Pure.
    function itemState(item) {
        var result = item && item.solution && item.solution.result;
        if (!result) return 'none';
        if (result !== 'pass') return 'fail';
        var free = item.starter && item.starter.result === 'pass' && item.points > 0;
        return free ? 'starter' : 'pass';
    }

    /// The glyph beside a state. Pure.
    function glyph(state) {
        return state === 'pass' ? '✓' : state === 'fail' ? '✗' : state === 'starter' ? '!' : '○';
    }

    var count = function (n, one, many) { return n + ' ' + (n === 1 ? one : many); };

    /// What the app bar's pill and the note beside it say for the outline's
    /// `validation`, or null to keep the server's wording (no runner, not
    /// validated, failed with no outline issue). The pill is short; the note
    /// says what it counts. `issues` lists the item ids to step through. Pure.
    function pillState(validation) {
        if (!validation) return null;
        var issues = validation.issues || [];
        var starterNote = validation.starterError
            ? 'Starter didn’t run: ' + clip(validation.starterError)
            : '';
        if (validation.status === 'pending') return { text: 'Validating…', note: '', tone: '', issues: [] };
        if (issues.length) {
            var failing = issues.filter(function (i) { return i.kind === 'failsOnSolution'; }).length;
            var free = issues.length - failing;
            var parts = [];
            if (failing) parts.push(count(failing, 'fails', 'fail') + ' on the solution');
            if (free) parts.push(count(free, 'passes', 'pass') + ' on the starter');
            return {
                text: '! ' + count(issues.length, 'issue', 'issues'),
                note: starterNote || parts.join(' · '),
                tone: failing ? 'err' : 'warn',
                issues: issues.map(function (i) { return i.itemID; }),
            };
        }
        if (validation.status !== 'passed') return null;
        var starterRan = validation.starterRunAt && !validation.starterError;
        return {
            text: '✓ Validated',
            note: starterRan ? 'Every test passes on the solution; none earns points on the starter' : starterNote,
            tone: 'ok',
            issues: [],
        };
    }

    /// The chip's wording and tone for the states `pillState` leaves to the
    /// server: failed with no outline issue, no runner, and not validated.
    /// It mirrors `pillText` and `pillClass` in
    /// `Sources/APIServer/Views/WorkbenchAppBar.swift`. The page renders that
    /// wording once, and a poll that sees the status move must redraw it.
    /// workbench-poll.test.mjs checks that this and `pillState` agree with
    /// the Swift. Pure.
    function chipState(validation) {
        var status = validation && validation.status;
        if (status === 'failed') return { text: '✗ Validation failed', tone: 'err' };
        if (status === 'no-runner') return { text: 'No runner', tone: 'err' };
        return { text: 'Not validated', tone: '' };
    }

    // How long the rail keeps asking for a result. A runner claims a
    // validation in seconds when one is free, so the first half-minute asks
    // often; a queue behind student work can take minutes, so it then asks
    // less often, and it stops after ten minutes. A save starts it again.
    var POLL_FAST_MS = 2000;
    var POLL_SLOW_MS = 5000;
    var POLL_FAST_FOR_MS = 30000;
    var POLL_LIMIT_MS = 10 * 60 * 1000;
    // After the solution run, the starter run (NB8) still has to land. With
    // no notebook there is no starter run, so this wait is short, and only a
    // save starts it: a page load does not wait for a starter run.
    var STARTER_POLLS = 12;

    /// True when the solution run has a result and the starter run has not
    /// caught up with it. Pure.
    function starterBehind(validation) {
        if (!validation || !validation.solutionRunAt) return false;
        if (validation.status !== 'passed' && validation.status !== 'failed') return false;
        if (!validation.starterRunAt) return true;
        return Date.parse(validation.starterRunAt) < Date.parse(validation.solutionRunAt);
    }

    /// The milliseconds until the rail asks again, or null to stop. `elapsed`
    /// is the time since the save; `starterPolls` counts the polls made while
    /// waiting for the starter run alone. Pure.
    function pollDelay(validation, elapsed, starterPolls) {
        if (!validation || elapsed >= POLL_LIMIT_MS) return null;
        if (validation.status === 'pending') return elapsed < POLL_FAST_FOR_MS ? POLL_FAST_MS : POLL_SLOW_MS;
        if (starterBehind(validation) && starterPolls < STARTER_POLLS) return POLL_SLOW_MS;
        return null;
    }

    /// A reason cut to one short phrase: its first 60 characters. Pure.
    function clip(text) {
        var line = String(text);
        return line.length > 60 ? line.slice(0, 59) + '…' : line;
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
        itemState: itemState, glyph: glyph, totalsText: totalsText, pillState: pillState, clip: clip,
        chipState: chipState, starterBehind: starterBehind, pollDelay: pollDelay,
        sectionCaption: sectionCaption, revealTarget: revealTarget, findItem: findItem, cssEscape: cssEscape,
    };

    if (typeof document !== 'undefined' && typeof window !== 'undefined') {
        var el = function (tag, className, text) {
            return ChickadeeUI.el(tag, className ? { 'class': className } : null, text);
        };

        var execute = function (command, args) {
            var run = window.chickadeeEditorCommand;
            return typeof run === 'function' ? run(command, args) : Promise.resolve(false);
        };

        var outline = null;
        var sentToEditor = false;

        // A preview of a student's notebook (NB6b) shows what the student
        // sees, so it gets no test cards. Its editor frame names the
        // preview's guide.
        var isPreview = function () {
            var frame = document.getElementById('jl-frame');
            var url = frame && frame.getAttribute('data-guide-url');
            return !!url && url.indexOf('/preview-guide.json') !== -1;
        };

        var sendSuite = function () {
            if (!outline || isPreview()) return;
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

        // The pill: the server's chip, or the issues button that steps
        // through the issues, and the note that says what it counts.
        var issueIDs = [];
        var nextIssue = 0;
        var drawPill = function () {
            var chip = document.getElementById('wb-validation');
            var button = document.getElementById('wb-issues');
            var note = document.getElementById('wb-validation-note');
            var validation = outline && outline.validation;
            if (!chip || !button || !validation) return;
            // The states the outline cannot improve keep the server's
            // wording, redrawn here because a poll can see the status move.
            var state = pillState(validation);
            if (!state) {
                var server = chipState(validation);
                state = { text: server.text, note: '', tone: server.tone, issues: [] };
            }
            issueIDs = state.issues;
            nextIssue = 0;
            button.hidden = !issueIDs.length;
            chip.hidden = !!issueIDs.length;
            if (issueIDs.length) {
                button.textContent = state.text;
                button.setAttribute('data-tone', state.tone);
                button.setAttribute('aria-label', state.text.slice(2) + ': select the next');
            } else {
                chip.textContent = state.text;
                chip.classList.toggle('chip-ok', state.tone === 'ok');
                chip.classList.toggle('chip-err', state.tone === 'err');
            }
            if (note) {
                note.textContent = state.note;
                note.hidden = !state.note;
            }
        };

        var stepIssue = function () {
            if (!issueIDs.length) return;
            var id = issueIDs[nextIssue % issueIDs.length];
            nextIssue += 1;
            markSelected(id);
            void execute('chickadee:select-item', { itemID: id });
        };

        var draw = function (fresh) {
            outline = fresh;
            drawPill();
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

        // A save queues a validation that a runner grades later, so one
        // fetch after the save sees only "pending". While the outline says
        // pending, or the starter run has not caught up, the rail asks again
        // (`pollDelay`). One timer at a time: each fetch replaces it.
        var pollTimer = null;
        var pollElapsed = 0;
        var starterPolls = 0;
        // Each fetch takes a number. A response to an older fetch than the
        // newest is dropped, so a slow poll cannot draw over a save.
        var fetchSeq = 0;
        var canPoll = typeof setTimeout === 'function' && typeof clearTimeout === 'function';

        var schedulePoll = function (validation) {
            if (!canPoll) return;
            if (pollTimer !== null) clearTimeout(pollTimer);
            pollTimer = null;
            var delay = pollDelay(validation, pollElapsed, starterPolls);
            if (delay === null) return;
            if (validation.status !== 'pending') starterPolls += 1;
            pollTimer = setTimeout(function () {
                pollTimer = null;
                pollElapsed += delay;
                void fetchOutline('poll');
            }, delay);
        };

        /// `cause` is `load`, `save` or `poll`.
        var fetchOutline = function (cause) {
            var shell = document.getElementById('wb-shell');
            var url = shell && shell.getAttribute('data-suite-url');
            if (!url) return Promise.resolve(null);
            var fromPoll = cause === 'poll';
            if (!fromPoll) {
                pollElapsed = 0;
                starterPolls = cause === 'save' ? 0 : STARTER_POLLS;
            }
            var seq = ++fetchSeq;
            var keepPolling = function () {
                // A poll that failed asks again, up to the limit: one dropped
                // request must not leave the pill on "Validating…".
                if (seq === fetchSeq) schedulePoll(outline && outline.validation);
                return null;
            };
            return fetch(url, { credentials: 'same-origin', headers: { Accept: 'application/json' } })
                .then(function (res) { return res.ok ? res.json() : null; })
                .then(function (fresh) {
                    if (seq !== fetchSeq) return null;
                    if (fromPoll && !fresh) return keepPolling();
                    // A poll that finds nothing new leaves the rail and the
                    // editor's cards alone.
                    var changed = !fromPoll || JSON.stringify(fresh) !== JSON.stringify(outline);
                    if (changed) {
                        draw(fresh);
                        sendSuite();
                    }
                    schedulePoll(fresh && fresh.validation);
                    return fresh;
                })
                .catch(function () { return fromPoll ? keepPolling() : null; });
        };

        var refresh = function () { return fetchOutline('save'); };

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
                var input = /** @type {HTMLInputElement | null} */ (block.querySelector('.section-name-input'));
                if (input) input.focus();
            }
        };

        var pin = function (itemID, anchor) {
            var shell = document.getElementById('wb-shell');
            var assignmentID = shell && shell.getAttribute('data-assignment-id');
            if (!assignmentID) return Promise.resolve(false);
            return fetch('/instructor/' + encodeURIComponent(assignmentID) + '/suite-anchor', {
                method: 'PUT',
                credentials: 'same-origin',
                headers: {
                    'Content-Type': 'application/json',
                    'x-csrf-token': ChickadeeUI.getCsrfToken(),
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

        var issuesButton = document.getElementById('wb-issues');
        if (issuesButton) issuesButton.addEventListener('click', stepIssue);

        global.ChickadeeWorkbenchRail = { refresh: refresh };
        void fetchOutline('load');
    }

    // Node export for the .mjs unit tests (Tests/BrowserRunnerJSTests).
    if (typeof module === 'object' && module.exports) {
        module.exports = api;
    }
})(typeof self !== 'undefined' ? self : this);
