// Page wiring for the admin runner-detail page (admin-runner.leaf): keeps the
// offline badge honest as the page ages, and polls the runners endpoint every
// 5 seconds to refresh the header's live-status fields (version, hostname,
// last active) without a full page reload — mirroring what the main /admin
// page does.  The runner's ID rides on the page's data-runner-id attribute.
(function () {
    'use strict';

    var offlineBadge = document.getElementById('runner-offline-badge');
    var offlineStatus = document.getElementById('runner-offline-status');

    // The badge's initial state is server-rendered; this keeps it honest as
    // the page ages without a reload, using the shared staleness rule.  The
    // status block says what being offline MEANS and is only present when
    // something is wrong, so it tracks the same answer — left behind, it would
    // still be explaining an outage minutes after the runner came back.
    function updateOfflineBadge() {
        var laEl = document.getElementById('runner-last-active');
        var laIso = laEl ? laEl.getAttribute('data-iso') : null;
        var stale = window.ChickadeeRelativeTime.isStale(laIso);
        if (offlineBadge) offlineBadge.hidden = !stale;
        if (offlineStatus) offlineStatus.hidden = !stale;
    }
    window.ChickadeeRelativeTime.applyRelativeTimes();
    updateOfflineBadge();

    var RUNNER_ID = (document.querySelector('[data-runner-id]') || {})
        .getAttribute ? document.querySelector('[data-runner-id]').getAttribute('data-runner-id') : '';

    setInterval(function () {
        if (document.hidden) return;
        window.ChickadeeRelativeTime.applyRelativeTimes();
        updateOfflineBadge();
        if (!RUNNER_ID) return;
        fetch('/admin/runners', { headers: { 'Accept': 'application/json', 'X-Background-Refresh': '1' }, cache: 'no-store' })
            .then(function (r) { return r.ok ? r.json() : null; })
            .then(function (rows) {
                if (!Array.isArray(rows)) return;
                var runner = rows.find(function (w) { return w.workerID === RUNNER_ID; });
                if (!runner) return;
                var vEl  = document.getElementById('runner-version');
                var hEl  = document.getElementById('runner-hostname');
                var laEl = document.getElementById('runner-last-active');
                if (vEl)  vEl.textContent = runner.runnerVersion || 'Unknown version';
                if (hEl)  hEl.textContent = runner.hostname      || 'Unknown host';
                if (laEl && runner.lastActive) {
                    laEl.setAttribute('data-iso', runner.lastActive);
                    laEl.textContent = window.ChickadeeRelativeTime.formatRelative(runner.lastActive);
                    laEl.title = new Date(runner.lastActive).toLocaleString();
                }
            })
            .catch(function () {});
    }, 5000);
})();
