// Submissions stat card (assignment-submissions.leaf): cycle the pre-rendered
// 24h/7d/30d sparklines on click/Enter/Space. Each window's bars are
// server-rendered (the 24h view is the only one visible without JS); this
// just swaps which one shows and updates the window chip + headline count to
// match.  Extracted from the template's inline script block so it is linted
// and testable.
(function () {
    'use strict';

    var card = document.querySelector('[data-subm-trend]');
    if (!card) return;
    var sparks = Array.prototype.slice.call(card.querySelectorAll('.js-subm-trend-spark'));
    if (sparks.length < 2) return;
    var chip = card.querySelector('[data-subm-chip]');
    var valueEl = card.querySelector('[data-subm-value]');
    var index = 0;
    function show(next) {
        index = (next + sparks.length) % sparks.length;
        for (var i = 0; i < sparks.length; i++) { sparks[i].hidden = (i !== index); }
        var active = sparks[index];
        if (chip) chip.textContent = active.getAttribute('data-subm-window') || '';
        if (valueEl) valueEl.textContent = active.getAttribute('data-subm-headline') || '';
    }
    card.addEventListener('click', function () { show(index + 1); });
    card.addEventListener('keydown', function (event) {
        if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            show(index + 1);
        }
    });
    show(0);
})();
