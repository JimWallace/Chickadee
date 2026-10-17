// Public/notebook-graded.js
//
// The graded toast on the notebook page (notebook views NB5, frame 18f).
//
//   - Browser-graded: notebook.js calls `ChickadeeGraded.graded(id)` when
//     the browser runner has submitted the results.
//   - Worker-graded: notebook.js calls `ChickadeeGraded.watch(submissionID)`
//     and stays on the page. This polls `/api/v1/submissions/:id`, as app.js
//     does, from 1s and backing off to 10s, and stops after 5 minutes.
//   - Either way the guide is fetched again (notebook-guide.js), so the
//     headers, checks lines and outline update in place, with no reload and no
//     kernel restart. Then the toast says the grade.
//   - A page opened while its latest attempt is still grading watches it with
//     no toast, so the statuses become current.
//
// When the guide cannot say the grade, or the poll gives up, the toast still
// links to the results page. The toast never closes by itself. At 100% three stars and one hop show;
// the full celebration stays on the results page, so this file never writes
// `ck-celebrated:<submissionID>`. Without the editor extension notebook.js
// keeps its inline results panel and its old flow, and this does nothing.

(function (global) {
    'use strict';

    var FIRST_DELAY_MS = 1000;
    var MAX_DELAY_MS = 10000;
    var GIVE_UP_MS = 5 * 60 * 1000;

    /// The next poll delay: half as long again, at most 10s. Pure.
    function nextDelay(delay) {
        return Math.min(MAX_DELAY_MS, Math.round(delay * 1.5));
    }

    /// True once the runner has finished with a submission. Pure.
    function isDone(status) {
        return typeof status === 'string' && status !== 'pending' && status !== 'assigned';
    }

    /// The submission id in an attempt URL ("/submissions/abc"), or null. Pure.
    function submissionID(url) {
        var match = /\/submissions\/([^/?#]+)/.exec(url || '');
        return match ? match[1] : null;
    }

    /// The public checks of the guide that passed, and those with a result. Pure.
    function checkCounts(guide) {
        var passed = 0;
        var total = 0;
        (guide.tasks || []).forEach(function (task) {
            (task.checks || []).forEach(function (check) {
                if (!check.result) return;
                total += 1;
                if (check.result === 'pass') passed += 1;
            });
        });
        return { passed: passed, total: total };
    }

    /// The toast's text for a graded guide, or null while it is grading. Pure.
    function toastText(guide) {
        var attempt = guide && guide.attempt;
        if (!attempt || attempt.pending) return null;
        var counts = checkCounts(guide);
        var summary = '';
        if (counts.total > 1 && counts.passed === counts.total) {
            summary = 'All ' + counts.total + ' checks passed.';
        } else if (counts.total > 0) {
            summary = counts.passed + ' of ' + counts.total + (counts.total === 1 ? ' check' : ' checks') + ' passed.';
        }
        return {
            caption: 'Attempt ' + attempt.number + ' graded',
            grade: attempt.percent == null ? '' : attempt.percent + '%',
            summary: summary,
            url: attempt.url,
            perfect: attempt.percent === 100,
        };
    }

    var api = {
        nextDelay: nextDelay, isDone: isDone, submissionID: submissionID,
        checkCounts: checkCounts, toastText: toastText,
    };

    if (typeof document !== 'undefined' && typeof window !== 'undefined') {
        var timer = null;
        var firstGuide = true;
        var byId = function (id) { return document.getElementById(id); };
        var part = function (name) {
            var toast = byId('nb-graded');
            return toast ? toast.querySelector('.js-nb-graded-' + name) : null;
        };
        var guideModule = function () { return global.ChickadeeNotebookGuide; };

        var hide = function () {
            var toast = byId('nb-graded');
            if (!toast) return;
            toast.hidden = true;
            toast.classList.remove('is-perfect');
        };

        // A frame later: a status region that was hidden is in the
        // accessibility tree only once it shows, so the text that a screen
        // reader announces must change after that.
        var later = function (fn) {
            return typeof global.requestAnimationFrame === 'function' ? global.requestAnimationFrame(fn) : setTimeout(fn, 0);
        };

        var show = function (text) {
            var toast = byId('nb-graded');
            if (!toast) return;
            toast.classList.toggle('is-perfect', text.perfect);
            ['caption', 'grade', 'summary'].forEach(function (name) { part(name).textContent = ''; });
            toast.hidden = false;
            var link = byId('nb-graded-results');
            if (link) link.href = text.url;
            later(function () {
                part('caption').textContent = text.caption;
                part('grade').textContent = text.grade;
                part('summary').textContent = text.summary;
            });
        };

        /// When the guide cannot say the grade (it did not load, or the poll
        /// gave up), the toast still links to the results.
        var showFallback = function (id, stillGrading) {
            if (!id) return;
            show({
                caption: stillGrading ? 'Still grading' : 'Attempt graded',
                grade: '',
                summary: stillGrading ? 'The results page shows the grade when it is ready.' : 'The results page shows the grade.',
                url: '/submissions/' + encodeURIComponent(id),
                perfect: false,
            });
        };

        var refresh = function (announce, id) {
            var guide = guideModule();
            if (!guide) return Promise.resolve(null);
            return guide.refresh().then(function (fetched) {
                if (!announce) return fetched;
                var text = toastText(fetched);
                if (text) {
                    show(text);
                } else {
                    showFallback(id, false);
                }
                return fetched;
            });
        };

        var stop = function () {
            if (timer) clearTimeout(timer);
            timer = null;
        };

        var watch = function (id, announce) {
            stop();
            var loud = announce !== false;
            var started = Date.now();
            var delay = FIRST_DELAY_MS;
            var schedule = function () {
                if (Date.now() - started >= GIVE_UP_MS) {
                    timer = null;
                    if (loud) showFallback(id, true);
                    return;
                }
                timer = setTimeout(tick, delay);
                delay = nextDelay(delay);
            };
            var tick = function () {
                fetch('/api/v1/submissions/' + encodeURIComponent(id), {
                    credentials: 'same-origin', headers: { Accept: 'application/json' },
                })
                    .then(function (res) { return res.ok ? res.json() : null; })
                    .then(function (data) {
                        if (data && isDone(data.status)) {
                            timer = null;
                            void refresh(loud, id);
                        } else {
                            schedule();
                        }
                    })
                    .catch(schedule);
            };
            schedule();
        };

        var close = byId('nb-graded-close');
        if (close) {
            close.addEventListener('click', function () {
                hide();
                var submit = byId('nb-submit');
                if (submit) submit.focus();
            });
        }

        // A page opened while its latest attempt grades: watch it quietly.
        window.addEventListener('chickadee:guide', function (e) {
            var guide = e && e.detail;
            if (!firstGuide || !guide) return;
            firstGuide = false;
            var id = guide.attempt && guide.attempt.pending ? submissionID(guide.attempt.url) : null;
            if (id) watch(id, false);
        });

        global.ChickadeeGraded = {
            /// True when the editor extension draws the guide, so the toast
            /// replaces the inline results panel and the page stays open.
            active: function () {
                var guide = guideModule();
                return !!(byId('nb-graded') && guide && guide.inEditor());
            },
            graded: function (id) { stop(); hide(); return refresh(true, id); },
            watch: function (id) { hide(); watch(id, true); },
            hide: hide,
        };
    }

    // Node export for the .mjs unit tests (Tests/BrowserRunnerJSTests).
    if (typeof module === 'object' && module.exports) {
        module.exports = api;
    }
})(typeof self !== 'undefined' ? self : this);
