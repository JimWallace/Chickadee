// A click on the account page's large bird makes it chirp (#2589).
//
// The hero carries `data-bird-chirp`. A click on its bird points the face
// layer at the chirp face for a moment, then back at the face it wore. The
// chirp is a moment of play, not a choice: nothing is saved, and the picker's
// own face preview is what the bird returns to. The file sets a symbol
// reference only, never a style.
(function () {
    'use strict';

    var CHIRP = '#av-expression-chirp';
    var CHIRP_MS = 700;

    /** Wires `hero` so a click on its bird chirps. `later(fn, ms)` schedules
     *  the return to the worn face; it is `setTimeout` on the page. A click
     *  during a chirp does nothing, so the face it returns to is the worn
     *  one. Returns false when the hero has no bird to wire. */
    function attach(hero, later) {
        var bird = hero.querySelector('.avatar');
        if (!bird) return false;
        var chirping = false;
        bird.addEventListener('click', function () {
            var face = bird.querySelector('use[href^="#av-expression-"]');
            if (!face || chirping) return;
            var worn = face.getAttribute('href');
            chirping = true;
            face.setAttribute('href', CHIRP);
            later(function () {
                face.setAttribute('href', worn);
                chirping = false;
            }, CHIRP_MS);
        });
        return true;
    }

    function init() {
        document.querySelectorAll('[data-bird-chirp]').forEach(function (hero) {
            attach(hero, setTimeout);
        });
    }

    if (typeof module !== 'undefined' && module.exports) {
        module.exports = { attach: attach, CHIRP: CHIRP };
    }
    if (typeof document !== 'undefined') {
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', init);
        } else {
            init();
        }
    }
})();
