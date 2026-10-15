// Live preview for the account page's bird picker
// (docs/student-wardrobe.md, docs/avatar-species.md).
//
// The form carries `data-avatar-picker`, a selector for the avatar to preview.
// Each backdrop or ring radio carries the palette token it stands for in
// `data-av-token`, and a ring radio the ring symbol it draws in `data-av-ring`.
// A face radio (name "expression") carries the expression symbol it draws in
// `data-av-expression`. So this file holds no palette, no option list and no
// face list. On a change it sets the per-student custom properties the avatar
// already reads (the one kind of style write the UI rules allow from script)
// and points the avatar's ring and face layers at the checked symbols. The
// backdrop also goes on the form, so the ring samples follow it. Nothing is
// saved until the form is submitted.
//
// `trackChanges` keeps Save disabled and "Undo changes" hidden until a choice
// changes. Undo resets the form to the saved choices and redraws the preview.
// Without this script, Save is always enabled.
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

    /** The expression symbol reference for the checked face, or null. Only
     *  a same-page reference to an expression symbol is passed through. */
    function previewFace(checkedFace) {
        var face = checkedFace();
        return face && face.indexOf('#av-expression-') === 0 ? face : null;
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
        function checkedFace() {
            var input = form.querySelector('input[name="expression"]:checked');
            return input ? input.getAttribute('data-av-expression') : null;
        }
        function pointLayer(selector, ref) {
            var layer = preview.querySelector(selector);
            if (layer) layer.setAttribute('href', ref);
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
            if (ring) pointLayer('use[data-av-ring]', ring);
            var face = previewFace(checkedFace);
            if (face) pointLayer('use[href^="#av-expression-"]', face);
        });
    }

    /** Enables Save and shows Undo only while a choice differs from the
     *  saved one. A reset fires no change event, so one is sent after it to
     *  redraw the preview from the restored choices. */
    function trackChanges(form) {
        var save = form.querySelector('button[type="submit"]');
        var undo = form.querySelector('button[type="reset"]');
        function setChanged(changed) {
            if (save) save.disabled = !changed;
            if (undo) undo.hidden = !changed;
        }
        setChanged(false);
        form.addEventListener('change', function () { setChanged(true); });
        form.addEventListener('reset', function () {
            setTimeout(function () {
                form.dispatchEvent(new Event('change'));
                setChanged(false);
            }, 0);
        });
    }

    function init() {
        var form = document.querySelector('form[data-avatar-picker]');
        if (!form) return;
        var preview = document.querySelector(form.getAttribute('data-avatar-picker'));
        if (preview) attach(form, preview);
        trackChanges(form);
    }

    if (typeof module !== 'undefined' && module.exports) {
        module.exports = {
            previewValues: previewValues, previewRing: previewRing, previewFace: previewFace,
            attach: attach, trackChanges: trackChanges
        };
    }
    if (typeof document !== 'undefined') {
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', init);
        } else {
            init();
        }
    }
})();
