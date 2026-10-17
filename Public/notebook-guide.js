// Public/notebook-guide.js
//
// The student guide on the notebook page (notebook views NB4, frame 18a).
//
//   - Fetches the guide (`#jl-frame[data-guide-url]`, docs/notebook-guide.md)
//     and hands it to the Chickadee extension (`chickadee:set-guide`), which
//     draws the task headers and checks lines inside the editor.
//   - Draws the outline in `#nb-outline`: the attempt card, one row per
//     task, then one row per reflection (`docs/ai-assisted-feedback.md`; its
//     state comes from the extension). Below 1100px
//     the stylesheet lays the same nodes out as a row of chips under the
//     toolbar.
//   - Follows the extension: `ck:tasks` updates each row's status (the
//     extension works out "still the starter code"), and `ck:active-cell`
//     marks the task under the cursor. A row click reveals the task's cell.
//
// It reads results that already exist and runs nothing. Without the
// extension the outline still shows the server's statuses.
// `window.ChickadeeNotebookGuide.refresh()` fetches the guide again, and
// `inEditor()` says whether the extension draws it (notebook-graded.js, NB5).

(function (global) {
    'use strict';

    var GLYPHS = { pass: '✓', fail: '✗', starter: '!', fresh: '○', written: '✓', empty: '○' };
    var WORDS = {
        pass: 'Passed', fail: 'Checks failed', starter: 'Still the starter code', fresh: 'Not submitted yet',
        written: 'Written', empty: 'Empty',
    };

    /// The glyph beside a status. Pure.
    function glyph(status) {
        return GLYPHS[status] || '○';
    }

    /// The status in words, for a screen reader: the glyph is hidden. Pure.
    function statusWord(status) {
        return WORDS[status] || '';
    }

    /// The attempt card's three lines, or the "not submitted" text. Pure.
    function attemptCard(attempt) {
        if (!attempt) {
            return { title: 'Not submitted yet', detail: 'Each task lists what will be checked.', link: null, short: 'Not submitted yet' };
        }
        if (attempt.pending) {
            return { title: 'Attempt ' + attempt.number, detail: 'Being graded…', link: null, short: 'Attempt ' + attempt.number + ' · grading' };
        }
        var possible = attempt.pointsPossible;
        var points = attempt.points == null ? null : Math.round(attempt.points * 10) / 10;
        return {
            title: 'Attempt ' + attempt.number,
            percent: attempt.percent == null ? null : attempt.percent + '%',
            detail: points == null || possible == null ? '' : points + ' of ' + possible + ' points',
            link: { href: attempt.url, text: 'See attempt ' + attempt.number + ' results' },
            short: 'Attempt ' + attempt.number + (attempt.percent == null ? '' : ' · ' + attempt.percent + '%'),
        };
    }

    /// "2. Average heart rate" for a wide row, "Task 2" for a chip. Pure.
    function rowLabels(task, index) {
        return {
            wide: (index + 1) + '. ' + task.name,
            short: task.label || 'Task ' + (index + 1),
        };
    }

    /// What `chickadee:reveal` gets for a task: its heading, else its first
    /// anchor. Pure.
    function revealTarget(task) {
        if (task.heading) return { section: task.heading };
        var anchor = (task.anchors || [])[0];
        if (!anchor) return null;
        return anchor.kind === 'section' ? { section: anchor.name } : { name: anchor.name };
    }

    var api = { glyph: glyph, statusWord: statusWord, attemptCard: attemptCard, rowLabels: rowLabels, revealTarget: revealTarget };

    if (typeof document !== 'undefined' && typeof window !== 'undefined') {
        var guide = null;
        var sentToEditor = false;
        var extensionUp = false;
        var statuses = {};
        var reflectionStatuses = {};
        var activeSection = null;

        var frame = function () { return document.getElementById('jl-frame'); };
        var outline = function () { return document.getElementById('nb-outline'); };
        var guideURL = function () { var f = frame(); return f ? f.getAttribute('data-guide-url') : ''; };

        var execute = function (command, args) {
            var run = window.chickadeeEditorCommand;
            return typeof run === 'function' ? run(command, args) : Promise.resolve(false);
        };

        var el = function (tag, className, text) {
            var node = document.createElement(tag);
            if (className) node.className = className;
            if (text != null) node.textContent = text;
            return node;
        };

        var draw = function () {
            var nav = outline();
            if (!nav || !guide) return;
            nav.textContent = '';
            var card = attemptCard(guide.attempt);
            var attempt = el('div', 'outline-attempt');
            attempt.appendChild(el('span', 'outline-wide outline-caption', card.title));
            if (card.percent) {
                var figure = el('span', 'outline-wide outline-figure', card.percent);
                attempt.appendChild(figure);
            }
            if (card.detail) attempt.appendChild(el('span', 'outline-wide outline-meta', card.detail));
            if (card.link) {
                var link = el('a', 'outline-wide', card.link.text);
                link.href = card.link.href;
                attempt.appendChild(link);
            }
            attempt.appendChild(el('span', 'outline-short', card.short));
            nav.appendChild(attempt);

            // A caption, not a heading: the nav's own label already says "Tasks".
            nav.appendChild(el('div', 'outline-caption outline-wide', 'Tasks'));
            var list = el('ul', 'outline-tasks');
            guide.tasks.forEach(function (task, index) {
                var status = statuses[index] !== undefined ? statuses[index] : task.status;
                var labels = rowLabels(task, index);
                var item = el('li');
                var row = el('button', 'outline-row');
                row.type = 'button';
                row.setAttribute('data-status', status || 'none');
                row.setAttribute('data-section', task.sectionID || '');
                var mark = el('span', 'outline-glyph', glyph(status));
                mark.setAttribute('aria-hidden', 'true');
                row.appendChild(mark);
                row.appendChild(el('span', 'outline-wide outline-name', labels.wide));
                row.appendChild(el('span', 'outline-short', labels.short));
                row.appendChild(el('span', 'outline-wide outline-meta', task.points + (task.points === 1 ? ' pt' : ' pts')));
                if (statusWord(status)) row.appendChild(el('span', 'visually-hidden', ', ' + statusWord(status)));
                row.addEventListener('click', function () {
                    var target = revealTarget(task);
                    if (target) void execute('chickadee:reveal', target);
                });
                item.appendChild(row);
                list.appendChild(item);
            });
            (guide.reflections || []).forEach(function (reflection) {
                var status = reflectionStatuses[reflection.tag] || 'empty';
                var item = el('li');
                var row = el('button', 'outline-row');
                row.type = 'button';
                row.setAttribute('data-status', status);
                var mark = el('span', 'outline-glyph', glyph(status));
                mark.setAttribute('aria-hidden', 'true');
                row.appendChild(mark);
                row.appendChild(el('span', 'outline-name', reflection.label));
                row.appendChild(el('span', 'visually-hidden', ', ' + statusWord(status)));
                row.addEventListener('click', function () {
                    void execute('chickadee:reveal', { tag: reflection.tag });
                });
                item.appendChild(row);
                list.appendChild(item);
            });
            nav.appendChild(list);
            nav.hidden = false;
            markActive(activeSection);
        };

        var markActive = function (sectionID) {
            activeSection = sectionID;
            var nav = outline();
            if (!nav) return;
            nav.querySelectorAll('.outline-row').forEach(function (row) {
                if (sectionID != null && row.getAttribute('data-section') === sectionID) {
                    row.setAttribute('aria-current', 'step');
                } else {
                    row.removeAttribute('aria-current');
                }
            });
        };

        var sendToEditor = function () {
            if (!guide) return;
            sentToEditor = true;
            void execute('chickadee:set-guide', { guide: guide });
        };

        var refresh = function () {
            var url = guideURL();
            // A swapped-in notebook with no guide (the workbench, after a
            // preview) must not get the last one again on its next boot.
            if (!url) {
                guide = null;
                return Promise.resolve(null);
            }
            return fetch(url, { credentials: 'same-origin', headers: { Accept: 'application/json' } })
                .then(function (res) { return res.ok ? res.json() : null; })
                .then(function (fetched) {
                    if (!fetched || !Array.isArray(fetched.tasks)) return null;
                    guide = fetched;
                    statuses = {};
                    draw();
                    sendToEditor();
                    // notebook-graded.js watches an attempt that still grades.
                    if (typeof window.dispatchEvent === 'function' && typeof CustomEvent === 'function') {
                        window.dispatchEvent(new CustomEvent('chickadee:guide', { detail: guide }));
                    }
                    return guide;
                })
                .catch(function () { return null; });
        };

        window.addEventListener('message', function (e) {
            try {
                if (!e || e.origin !== window.location.origin) return;
                var d = e.data;
                if (!d || typeof d.ck !== 'string') return;
                if (d.ck === 'kernel-diag' && d.kind === 'kernel_phase' && d.source === 'boot_start') {
                    sentToEditor = false;
                    extensionUp = false;
                } else if (d.ck === 'ck:kernel') {
                    // The extension is up in this editor document.
                    extensionUp = true;
                    if (!sentToEditor) sendToEditor();
                } else if (d.ck === 'ck:tasks' && Array.isArray(d.tasks)) {
                    // In the guide's task order: a task has no sectionID
                    // when its checks are in no section.
                    d.tasks.forEach(function (t, i) { statuses[i] = t.status; });
                    (d.reflections || []).forEach(function (r) { reflectionStatuses[r.tag] = r.status; });
                    draw();
                } else if (d.ck === 'ck:active-cell') {
                    markActive(d.task == null ? null : d.task);
                }
            } catch (_) { /* the outline must never break the page */ }
        });

        if (guideURL()) void refresh();
        global.ChickadeeNotebookGuide = {
            refresh: refresh,
            /// True once the extension is up in the editor and has the guide.
            inEditor: function () { return extensionUp; },
        };
    }

    // Node export for the .mjs unit tests (Tests/BrowserRunnerJSTests).
    if (typeof module === 'object' && module.exports) {
        module.exports = api;
    }
})(typeof self !== 'undefined' ? self : this);
