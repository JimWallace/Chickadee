// Shared relative-time rendering for `.js-relative-time[data-iso]` nodes.
//
// Replaces six copy-pasted (and drifted) per-template implementations
// (June 2026 audit). Applies once on load automatically; pages that
// re-render rows from a poll call
// `ChickadeeRelativeTime.applyRelativeTimes(scopeEl)` afterwards.
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

    function applyRelativeTimes(root) {
        var scope = root || document;
        var nodes = scope.querySelectorAll('.js-relative-time[data-iso]');
        nodes.forEach(function (el) {
            var iso = el.getAttribute('data-iso');
            if (!iso) return;
            var date = new Date(iso);
            if (Number.isNaN(date.getTime())) return;
            el.textContent = formatRelative(iso);
            el.title = date.toLocaleString();
        });
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

    global.ChickadeeRelativeTime = {
        formatRelative: formatRelative,
        applyRelativeTimes: applyRelativeTimes,
        isStale: isStale
    };

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', function () { applyRelativeTimes(document); });
    } else {
        applyRelativeTimes(document);
    }
})(typeof self !== 'undefined' ? self : this);
