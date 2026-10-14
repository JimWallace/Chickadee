// Live preview for the account page's bird picker
// (docs/student-wardrobe.md, docs/avatar-species.md).
//
// The form carries `data-avatar-picker`, a selector for the avatar to preview.
// Each backdrop or ring radio carries the palette token it stands for in
// `data-av-token`, and a ring radio the ring symbol it draws in `data-av-ring`.
// A colourway radio (name "cap") carries the six tone tokens in `data-av-cap`,
// `data-av-wing`, `data-av-body`, `data-av-bib`, `data-av-beak` and
// `data-av-mark`, and the two layers a species changes in `data-av-plumage`
// and `data-av-tuft`. So this file holds no palette, no option list and no
// species. On a change it sets the per-student custom properties the avatar
// already reads (the one kind of style write the UI rules allow from script)
// and points the avatar's ring, plumage and tuft layers at the checked
// symbols. The backdrop and the cap also go on the form, so the ring samples
// follow them. Nothing is saved until the form is submitted.
(function () {
    'use strict';

    /** The six tones of a colourway, in the order the avatar names them. */
    var TONES = ['cap', 'wing', 'body', 'bib', 'beak', 'mark'];

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

    /** The value to give each tone property of the checked colourway, as
     *  `var(<token>)`, keyed by tone. `checkedAttribute(name)` returns the
     *  checked colourway radio's `data-av-<name>`, or null when none is
     *  checked; a missing or non-token value leaves that tone alone. */
    function previewTones(checkedAttribute) {
        var tones = {};
        TONES.forEach(function (tone) {
            var token = checkedAttribute(tone);
            tones[tone] = token && token.indexOf('--') === 0 ? 'var(' + token + ')' : null;
        });
        return tones;
    }

    /** The plumage and tuft symbol references of the checked colourway, or
     *  null each. Only a same-page reference to a plumage symbol, or to a tuft
     *  or crest symbol, is passed through. */
    function previewLayers(checkedAttribute) {
        var plumage = checkedAttribute('plumage');
        var tuft = checkedAttribute('tuft');
        return {
            plumage: plumage && plumage.indexOf('#av-plumage-') === 0 ? plumage : null,
            tuft: tuft && (tuft.indexOf('#av-tuft-') === 0 || tuft.indexOf('#av-crest-') === 0) ? tuft : null
        };
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
        function checkedColourway(name) {
            var input = form.querySelector('input[name="cap"]:checked');
            return input ? input.getAttribute('data-av-' + name) : null;
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
            var tones = previewTones(checkedColourway);
            TONES.forEach(function (tone) {
                if (tones[tone]) preview.style.setProperty('--av-' + tone, tones[tone]);
            });
            // The two-tone ring sample draws the cap colour.
            if (tones.cap && form.style) form.style.setProperty('--av-cap', tones.cap);
            var layers = previewLayers(checkedColourway);
            if (layers.plumage) pointLayer('use[href^="#av-plumage-"]', layers.plumage);
            if (layers.tuft) pointLayer('use[href^="#av-tuft-"], use[href^="#av-crest-"]', layers.tuft);
        });
    }

    function init() {
        var form = document.querySelector('form[data-avatar-picker]');
        if (!form) return;
        var preview = document.querySelector(form.getAttribute('data-avatar-picker'));
        if (preview) attach(form, preview);
    }

    if (typeof module !== 'undefined' && module.exports) {
        module.exports = {
            previewValues: previewValues, previewRing: previewRing, previewTones: previewTones,
            previewLayers: previewLayers, attach: attach
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
