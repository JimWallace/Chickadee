// Public/earned-toast.js
//
// The Earned toast on the result page (docs/result-celebration.md, J2;
// EarnedToast.swift). The server renders it hidden, only on the load that
// granted the item. This file shows it, announces it, and wires its buttons.
//
//   - When the celebration plays (celebrate.js has put `.is-celebrating` on
//     `#submission-root`), the toast shows 450 ms after the celebration's
//     pop (`chickadee:celebrate-pop`). Otherwise it shows at once.
//   - Wear it posts the toast's form to `POST /account/avatar`, asking for
//     JSON, and then points the page bird's layers at the new item, as the
//     account page's live preview does (avatar-picker.js). If the save fails,
//     the form submits as usual, and the account page says why.
//   - Not now and Escape close it. It never closes by itself, and nothing
//     takes focus.
//
// It makes no styling decision. The slide-in, the ring's draw-in and the
// face's crossfade are CSS animations, which stop under reduced motion. For
// a new face it adds the bird's current face as a second layer, so the two
// can crossfade, and toggles the classes that styles.css animates.
(function () {
    'use strict';

    /// After the celebration's pop, in ms, the toast slides in.
    var AFTER_POP_MS = 450;
    /// The latest the toast waits for a pop that does not come, in ms.
    var POP_TIMEOUT_MS = 6000;

    var FACE_LAYER = 'use[href^="#av-expression-"]';

    /** What Wear it changes on the page bird, from the form's `data-wear-*`
     *  attributes. Only a same-page ring or face symbol and a custom-property
     *  token pass through; anything else is null. */
    function wearing(form) {
        function read(name, prefix) {
            var value = form.getAttribute(name);
            return value && value.indexOf(prefix) === 0 ? value : null;
        }
        return {
            ring: read('data-wear-ring', '#av-ring-'),
            token: read('data-wear-token', '--'),
            face: read('data-wear-face', '#av-expression-')
        };
    }

    /** Puts `values` (from `wearing`) on `bird`, the page bird's svg. */
    function wear(bird, values) {
        if (values.token) { bird.style.setProperty('--av-border', 'var(' + values.token + ')'); }
        if (values.ring) {
            var ring = bird.querySelector('use[data-av-ring]');
            if (ring) { ring.setAttribute('href', values.ring); }
        }
        if (values.face) {
            var face = bird.querySelector(FACE_LAYER);
            if (face) { face.setAttribute('href', values.face); }
        }
    }

    /** Adds the face `oldRef` over the new face of `bird`, the toast's bird,
     *  and marks the two layers for the crossfade. Returns the old layer, or
     *  null when there is nothing to fade from. */
    function crossfade(bird, oldRef) {
        var face = bird.querySelector(FACE_LAYER);
        if (!face || !oldRef || oldRef.indexOf('#av-expression-') !== 0 || face.getAttribute('href') === oldRef) {
            return null;
        }
        var old = face.cloneNode(false);
        old.setAttribute('href', oldRef);
        old.setAttribute('class', 'earned-face-old');
        face.setAttribute('class', 'earned-face-new');
        face.parentNode.insertBefore(old, face.nextSibling);
        return old;
    }

    function init() {
        var toast = document.getElementById('earned-toast');
        if (!toast) { return; }
        var root = document.getElementById('submission-root');
        var pageBird = document.querySelector('.submission-bird .avatar');
        var form = toast.querySelector('.js-earned-wear');
        var live = toast.querySelector('.js-earned-live');
        var reduced = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
        var shown = false;

        function show() {
            if (shown) { return; }
            shown = true;
            if (!reduced && !toast.classList.contains('is-ring') && pageBird) {
                var current = pageBird.querySelector(FACE_LAYER);
                var old = crossfade(toast.querySelector('.avatar'), current && current.getAttribute('href'));
                if (old) { old.addEventListener('animationend', function () { old.remove(); }); }
            }
            toast.hidden = false;
            if (live) { live.textContent = toast.dataset.announce || ''; }
        }
        function close() { toast.hidden = true; }

        if (root && root.classList.contains('is-celebrating')) {
            var timer = setTimeout(show, POP_TIMEOUT_MS);
            document.addEventListener('chickadee:celebrate-pop', function () {
                clearTimeout(timer);
                setTimeout(show, AFTER_POP_MS);
            }, { once: true });
        } else {
            show();
        }

        var notNow = toast.querySelector('.js-earned-close');
        if (notNow) { notNow.addEventListener('click', close); }
        document.addEventListener('keydown', function (event) {
            if (event.key === 'Escape' && !toast.hidden) { close(); }
        });

        if (!form) { return; }
        form.addEventListener('submit', function (event) {
            event.preventDefault();
            var submit = form.querySelector('[type="submit"]');
            if (submit) { submit.disabled = true; }
            fetch(form.action, {
                method: 'POST',
                headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'Accept': 'application/json' },
                body: new URLSearchParams(new FormData(form)),
                credentials: 'same-origin'
            }).then(function (response) {
                if (!response.ok) { form.submit(); return; }
                if (pageBird) { wear(pageBird, wearing(form)); }
                close();
            }).catch(function () { form.submit(); });
        });
    }

    if (typeof module !== 'undefined' && module.exports) {
        module.exports = { wearing: wearing, wear: wear, crossfade: crossfade };
    }
    if (typeof document !== 'undefined') {
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', init);
        } else {
            init();
        }
    }
}());
