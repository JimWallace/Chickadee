// Shared relative-time rendering for `.js-relative-time[data-iso]` nodes.
//
// Replaces six copy-pasted (and drifted) per-template implementations
// (June 2026 audit). Applies on load, then keeps ticking; pages that re-render
// rows from a poll call `ChickadeeRelativeTime.applyRelativeTimes(scopeEl)`
// afterwards to catch the new nodes immediately.
//
// THE TICK IS THE POINT. This used to apply exactly once per page load, so a
// timestamp was live only where something else happened to repaint it — the
// three tables `table-poll.js` refreshes every five seconds. Everywhere else
// (the runner dashboard, MCP agents, alerts, the activity log) "2 minutes ago"
// meant "2 minutes before you opened this tab", for as long as the tab stayed
// open. A component that does its job on the pages where a neighbour drives it
// and silently stops on the rest is the same defect the list filter had with
// its empty state, and it wants the same answer: the component owns it.
//
// The cadence follows the freshest timestamp on the page, because that is what
// decides when the text next changes: seconds-old stamps need a 15s tick,
// minutes-old ones a minute, and a page whose newest stamp is hours old can
// tick every five without ever showing a stale string. Ticking stops while the
// tab is hidden and catches up on the way back, so a tab left open overnight
// re-renders on focus rather than after one more interval.
//
// Text is written only when it changes, so a quiet page costs a formatter call
// per node and no DOM mutation at all.
(function (global) {
    'use strict';

    var relativeFormatter = new Intl.RelativeTimeFormat(undefined, { numeric: 'auto' });

    function formatRelative(isoString) {
        var date = new Date(isoString);
        if (Number.isNaN(date.getTime())) return isoString;

        var seconds = Math.round((date.getTime() - Date.now()) / 1000);
        var abs = Math.abs(seconds);

        if (abs < 60) return relativeFormatter.format(seconds, 'second');
        var minutes = Math.round(seconds / 60);
        if (Math.abs(minutes) < 60) return relativeFormatter.format(minutes, 'minute');
        var hours = Math.round(minutes / 60);
        if (Math.abs(hours) < 24) return relativeFormatter.format(hours, 'hour');
        var days = Math.round(hours / 24);
        if (Math.abs(days) < 7) return relativeFormatter.format(days, 'day');
        var weeks = Math.round(days / 7);
        if (Math.abs(weeks) < 5) return relativeFormatter.format(weeks, 'week');
        var months = Math.round(days / 30);
        if (Math.abs(months) < 12) return relativeFormatter.format(months, 'month');
        var years = Math.round(days / 365);
        return relativeFormatter.format(years, 'year');
    }

    // How long until the freshest stamp's TEXT could change. Under a minute the
    // string moves every few seconds; past an hour it moves once an hour. These
    // are the same thresholds formatRelative switches on, so the tick can never
    // be slower than the text it renders.
    var TICK_SECONDS = 15;
    var TICK_MINUTES = 60;
    var TICK_SLOW = 300;

    function tickSecondsFor(youngestAgeSeconds) {
        if (youngestAgeSeconds === null) return null;      // nothing to tick
        if (youngestAgeSeconds < 60) return TICK_SECONDS;
        if (youngestAgeSeconds < 3600) return TICK_MINUTES;
        return TICK_SLOW;
    }

    /// Render every `.js-relative-time[data-iso]` under `root`, and report the
    /// age in seconds of the freshest one (null if there are none) so the
    /// caller can pace itself.
    function applyRelativeTimes(root) {
        var scope = root || document;
        var nodes = scope.querySelectorAll('.js-relative-time[data-iso]');
        var youngest = null;
        var now = Date.now();
        nodes.forEach(function (el) {
            var iso = el.getAttribute('data-iso');
            if (!iso) return;
            var date = new Date(iso);
            var time = date.getTime();
            if (Number.isNaN(time)) return;
            var age = Math.abs(now - time) / 1000;
            if (youngest === null || age < youngest) youngest = age;
            // Write only on change: a page of hour-old stamps re-renders its
            // strings every tick and mutates nothing.
            var text = formatRelative(iso);
            if (el.textContent !== text) el.textContent = text;
            var title = date.toLocaleString();
            if (el.title !== title) el.title = title;
        });
        return youngest;
    }

    // "Has this thing gone quiet?" — the client half of the server's
    // RunnerStaleness rule (5 minutes without a check-in reads as offline).
    // Lived as two copy-pasted `Date.now() - t > 5 * 60 * 1000` expressions in
    // page scripts; both are gone, and the server now decides the initial
    // state so first paint and later ticks agree.
    var STALE_AFTER_MS = 5 * 60 * 1000;

    function isStale(isoString, thresholdMs) {
        if (!isoString) return false;
        var t = new Date(isoString).getTime();
        if (Number.isNaN(t)) return false;
        return (Date.now() - t) > (thresholdMs || STALE_AFTER_MS);
    }

    // ── The tick ─────────────────────────────────────────────────────────────
    //
    // One timer for the whole page, re-armed after each pass at the cadence the
    // freshest stamp needs. setTimeout rather than setInterval so the cadence
    // can change as the page ages, and so a slow pass can never stack.
    var timer = null;

    function clearTimer() {
        if (timer === null) return;
        clearTimeout(timer);
        timer = null;
    }

    function tick() {
        timer = null;
        if (typeof document !== 'undefined' && document.hidden) return;  // resumes on visibilitychange
        var youngest = applyRelativeTimes(document);
        var seconds = tickSecondsFor(youngest);
        if (seconds === null) return;   // no timestamps on this page
        timer = setTimeout(tick, seconds * 1000);
    }

    /// Render now and re-arm. Safe to call repeatedly — a page that adds
    /// timestamp nodes (a poll repaint) calls applyRelativeTimes for the
    /// immediate paint; this is what keeps the cadence honest afterwards.
    function start() {
        clearTimer();
        tick();
    }

    global.ChickadeeRelativeTime = {
        formatRelative: formatRelative,
        applyRelativeTimes: applyRelativeTimes,
        isStale: isStale,
        tickSecondsFor: tickSecondsFor,
        start: start,
        stop: clearTimer
    };

    if (typeof document !== 'undefined') {
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', start);
        } else {
            start();
        }
        // A tab restored after an hour must not show its load-time strings
        // until one more interval elapses.
        document.addEventListener('visibilitychange', function () {
            if (document.hidden) clearTimer();
            else start();
        });
    }

    // Node export for the .mjs unit tests (Tests/BrowserRunnerJSTests);
    // browsers take the global above. Its absence is part of why this file
    // went untested while every other shared component had a suite.
    if (typeof module === 'object' && module.exports) {
        module.exports = global.ChickadeeRelativeTime;
    }
})(typeof self !== 'undefined' ? self : this);
