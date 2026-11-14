// @ts-check
// Page wiring for the admin runner-detail page (AdminRunnerPage): keeps the
// offline badge and the offline banner honest as the page ages.
//
// This file does not poll. The live part of the header (host, version, last
// active, the counts and the facts) is a region that `table-poll.js`
// refreshes from `/admin/runners/:id?fragment=status`, the one poller
// (docs/ui-design.md "Interaction idioms"). The heading badge and the banner
// are outside that region: the banner is a live region, and a swap on every
// poll would announce it again. So both follow the region here: on each
// repaint, and on a timer that reads the last-active stamp the region holds.
(function () {
    'use strict';

    // The badge's initial state is server-rendered; this keeps it honest as
    // the page ages without a reload, using the shared staleness rule.  The
    // status block says what being offline MEANS and is only present when
    // something is wrong, so it tracks the same answer — left behind, it would
    // still be explaining an outage minutes after the runner came back.
    //
    // Each element is looked up on every call: a repaint replaces the
    // last-active stamp with a new node.
    function updateOfflineBadge() {
        var laEl = document.getElementById('runner-last-active');
        var laIso = laEl ? laEl.getAttribute('data-iso') : null;
        var stale = window.ChickadeeRelativeTime.isStale(laIso);
        var offlineBadge = document.getElementById('runner-offline-badge');
        var offlineStatus = document.getElementById('runner-offline-status');
        if (offlineBadge) offlineBadge.hidden = !stale;
        if (offlineStatus) offlineStatus.hidden = !stale;
    }
    window.ChickadeeRelativeTime.applyRelativeTimes();
    updateOfflineBadge();

    var region = document.querySelector('.js-runner-status');
    if (region) region.addEventListener('chickadee:table-repaint', updateOfflineBadge);

    // A timer that does not poll: it re-reads what is already on the page.
    setInterval(function () {
        if (document.hidden) return;
        window.ChickadeeRelativeTime.applyRelativeTimes();
        updateOfflineBadge();
    }, 5000);
})();
