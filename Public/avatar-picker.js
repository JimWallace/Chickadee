// Live preview for the account page's Chickadee picker
// (docs/student-wardrobe.md).
//
// The form carries `data-avatar-picker`, a selector for the avatar to preview.
// Each radio carries the palette token it stands for in `data-av-token`, and
// a ring radio the ring symbol it draws in `data-av-ring`, so this file holds
// no palette and no option list. On a change it sets the two per-student
// custom properties the avatar already reads, --av-backdrop and --av-border
// (the one kind of style write the UI rules allow from script), and points the
// avatar's ring layer — the use element marked `data-av-ring` — at the checked
// ring. The backdrop also goes on the form, so the ring samples follow it.
// Nothing is saved until the form is submitted.
(function () {
    'use strict';

    /** The value to give each avatar custom property, as `var(<token>)`.
     *  `checkedToken(group)` returns the checked radio's token, or null when
     *  nothing in the group is checked; that group's value is then null and
     *  the property is left alone. A value that is not a custom-property token
     *  is never passed through. */
    function previewValues(checkedToken) {
        function value(group) {
            var token = checkedToken(group);
            return token && token.indexOf('--') === 0 ? 'var(' + token + ')' : null;
        }
        return { backdrop: value('backdrop'), border: value('border') };
    }

    /** The ring symbol reference for the checked ring, or null. Only a
     *  same-page reference to a ring symbol is passed through. */
    function previewRing(checkedRing) {
        var ring = checkedRing();
        return ring && ring.indexOf('#av-ring-') === 0 ? ring : null;
    }

    /** Wires `form` to update `preview` on every change. */
    function attach(form, preview) {
        function checkedToken(group) {
            var input = form.querySelector('input[name="' + group + '"]:checked');
            return input ? input.getAttribute('data-av-token') : null;
        }
        function checkedRing() {
            var input = form.querySelector('input[name="border"]:checked');
            return input ? input.getAttribute('data-av-ring') : null;
        }
        form.addEventListener('change', function () {
            var values = previewValues(checkedToken);
            if (values.backdrop) {
                preview.style.setProperty('--av-backdrop', values.backdrop);
                // The ring samples inherit the backdrop from the form.
                if (form.style) form.style.setProperty('--av-backdrop', values.backdrop);
            }
            if (values.border) preview.style.setProperty('--av-border', values.border);
            var ring = previewRing(checkedRing);
            if (ring) {
                var ringLayer = preview.querySelector('use[data-av-ring]');
                if (ringLayer) ringLayer.setAttribute('href', ring);
            }
        });
    }

    function init() {
        var form = document.querySelector('form[data-avatar-picker]');
        if (!form) return;
        var preview = document.querySelector(form.getAttribute('data-avatar-picker'));
        if (preview) attach(form, preview);
    }

    if (typeof module !== 'undefined' && module.exports) {
        module.exports = { previewValues: previewValues, previewRing: previewRing, attach: attach };
    }
    if (typeof document !== 'undefined') {
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', init);
        } else {
            init();
        }
    }
})();
