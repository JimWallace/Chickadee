// The Present-mode podium bounces when the board first shows and when the top
// three change, not on every refresh (#2591).
//
// The polled region (`#present-results`, table-poll.js) replaces its contents
// whenever anything on the board changes, which would replay the CSS bounce
// on every update. The podium carries `data-podium-key`, the three handles in
// order. After each swap, table-poll.js fires `chickadee:table-repaint` on the
// region, in the same task as the swap and so before the browser paints; a
// podium whose key matches the one before is then marked `podium--settled`,
// which turns the bounce off before it starts. A board whose podium leaves
// and later comes back bounces again, as on first show. The file toggles a
// class only; the motion is in the stylesheet.
(function () {
    'use strict';

    var SETTLED = 'podium--settled';

    /** The podium in `region`, or null when the board has none. */
    function podiumIn(region) {
        return region.querySelector('.podium[data-podium-key]');
    }

    /** Marks the podium in `region` settled when its key is `previousKey`,
     *  and returns the key now shown (null with no podium). A first podium,
     *  with no key before it, is left to bounce. */
    function settle(region, previousKey) {
        var podium = podiumIn(region);
        if (!podium) return null;
        var key = podium.getAttribute('data-podium-key');
        if (previousKey !== null && key === previousKey) podium.classList.add(SETTLED);
        return key;
    }

    /** Settles the podium in `region` after each of its refreshes. */
    function attach(region) {
        var podium = podiumIn(region);
        var key = podium ? podium.getAttribute('data-podium-key') : null;
        region.addEventListener('chickadee:table-repaint', function () { key = settle(region, key); });
    }

    function init() {
        var region = document.getElementById('present-results');
        if (region) attach(region);
    }

    if (typeof module !== 'undefined' && module.exports) {
        module.exports = { settle: settle, attach: attach, SETTLED: SETTLED };
    }
    if (typeof document !== 'undefined') {
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', init);
        } else {
            init();
        }
    }
})();
