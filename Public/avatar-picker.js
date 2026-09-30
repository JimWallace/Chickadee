// Live preview for the account page's Chickadee picker
// (docs/student-wardrobe.md).
//
// The form carries `data-avatar-picker`, a selector for the avatar to preview.
// Each radio carries the palette token it stands for in `data-av-token`, so
// this file holds no palette and no option list. On a change it sets the two
// per-student custom properties the avatar already reads, --av-backdrop and
// --av-border: the one kind of style write the UI rules allow from script.
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

    /** Wires `form` to update `preview` on every change. */
    function attach(form, preview) {
        function checkedToken(group) {
            var input = form.querySelector('input[name="' + group + '"]:checked');
            return input ? input.getAttribute('data-av-token') : null;
        }
        form.addEventListener('change', function () {
            var values = previewValues(checkedToken);
            if (values.backdrop) preview.style.setProperty('--av-backdrop', values.backdrop);
            if (values.border) preview.style.setProperty('--av-border', values.border);
        });
    }

    function init() {
        var form = document.querySelector('form[data-avatar-picker]');
        if (!form) return;
        var preview = document.querySelector(form.getAttribute('data-avatar-picker'));
        if (preview) attach(form, preview);
    }

    if (typeof module !== 'undefined' && module.exports) {
        module.exports = { previewValues: previewValues, attach: attach };
    }
    if (typeof document !== 'undefined') {
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', init);
        } else {
            init();
        }
    }
})();
