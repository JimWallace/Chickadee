// @ts-check
// Public/quantum-cats-egg.js
//
// The hidden way into Quantum Cats (Public/games/README.md) and its ring
// (docs/student-wardrobe.md, "Found items"). BaseLayout loads it on every
// signed-in page that has site chrome.
//
//   - It listens for the Konami code: up up down down left right left right
//     B A. Keys typed into a field, a select or an editor do not count, nor
//     do keys held with Ctrl, Alt or Meta.
//   - On the code, it opens the game in a new tab, at once, inside the key
//     handler, which a browser treats as a user action, so no popup blocker
//     stops it.
//   - It then posts `POST /account/wardrobe/found` to grant the ring. When
//     that request stored the ring, it shows the Earned toast that the layout
//     renders hidden (`#quantum-cats-found`, EarnedToast.swift): the
//     student's bird in the new ring, with Wear it and Not now. Wear it is
//     the toast's own form to the account page's save route. Course staff
//     get no toast, since they wear the staff ring. A failed post changes
//     nothing: the next try grants the ring.
//
// It makes no styling decision: it only removes `hidden`, and the toast's
// ring draws in by CSS. The sequence logic has no DOM, so it runs under node
// (quantum-cats-egg.test.mjs).
(function () {
    'use strict';

    /// `KeyboardEvent.key` values, in order. Letters are compared in lower case.
    var SEQUENCE = [
        'ArrowUp', 'ArrowUp', 'ArrowDown', 'ArrowDown',
        'ArrowLeft', 'ArrowRight', 'ArrowLeft', 'ArrowRight', 'b', 'a'
    ];
    var GAME_URL = '/games/quantum-cats/index.html';
    var FOUND_URL = '/account/wardrobe/found';
    var ITEM = 'border.quantumcats';
    var TOAST_ID = 'quantum-cats-found';

    function normalize(key) {
        return typeof key === 'string' && key.length === 1 ? key.toLowerCase() : key;
    }

    /// The last keys typed, with `key` added, kept to the length of the
    /// sequence. Returns a new array.
    function push(recent, key) {
        var next = recent.concat([normalize(key)]);
        return next.length > SEQUENCE.length ? next.slice(next.length - SEQUENCE.length) : next;
    }

    /// Whether `recent` ends with the whole sequence.
    function matches(recent) {
        if (recent.length < SEQUENCE.length) return false;
        var offset = recent.length - SEQUENCE.length;
        for (var i = 0; i < SEQUENCE.length; i++) {
            if (recent[offset + i] !== SEQUENCE[i]) return false;
        }
        return true;
    }

    /// Whether a key event should be ignored: a modifier is held, or the
    /// student is typing into a field, a select or an editable element.
    function ignores(event) {
        if (event.ctrlKey || event.altKey || event.metaKey) return true;
        var target = event.target;
        if (!target || typeof target.closest !== 'function') return false;
        if (target.isContentEditable) return true;
        return target.closest('input, textarea, select, [contenteditable], .cm-editor, .CodeMirror') !== null;
    }

    var api = {
        SEQUENCE: SEQUENCE, GAME_URL: GAME_URL, FOUND_URL: FOUND_URL, ITEM: ITEM,
        push: push, matches: matches, ignores: ignores
    };
    var root = typeof window !== 'undefined' ? window : globalThis;
    root.ChickadeeQuantumCatsEgg = api;
    // Node export for the .mjs unit tests.
    if (typeof module === 'object' && module.exports) {
        module.exports = api;
    }

    if (typeof document === 'undefined' || typeof window === 'undefined') return;

    function showToast() {
        var toast = document.getElementById(TOAST_ID);
        if (!toast || !toast.hidden) return;
        toast.hidden = false;
        // A live region that appears is not read, so the text goes in now.
        var live = toast.querySelector('.js-earned-live');
        if (live) live.textContent = toast.getAttribute('data-announce') || '';
    }

    function wireToast() {
        var toast = document.getElementById(TOAST_ID);
        if (!toast) return;
        var notNow = toast.querySelector('.js-earned-close');
        if (notNow) notNow.addEventListener('click', function () { toast.hidden = true; });
        document.addEventListener('keydown', function (event) {
            if (event.key === 'Escape' && !toast.hidden) toast.hidden = true;
        });
    }

    function found() {
        var tab = window.open(GAME_URL, '_blank');
        if (tab) tab.opener = null;
        var ui = window.ChickadeeUI;
        if (!ui || typeof ui.fetchJSON !== 'function') return;
        ui.fetchJSON(FOUND_URL, { method: 'POST', body: { item: ITEM } })
            .then(function (reply) {
                if (reply && reply.granted) showToast();
            })
            .catch(function () {});
    }

    wireToast();
    var recent = [];
    document.addEventListener('keydown', function (event) {
        if (ignores(event)) {
            recent = [];
            return;
        }
        recent = push(recent, event.key);
        if (matches(recent)) {
            recent = [];
            found();
        }
    });
}());
