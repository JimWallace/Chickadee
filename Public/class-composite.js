// Public/class-composite.js
//
// Wires the class-composite view (docs/class-composite.md, slice 5). Every
// `.js-class-composite` element is one stage: a canvas, one cell for each
// slot, optional playback controls and a progress line. The decisions are in
// class-composite-core.js; this file keeps the element lookups, the poll and
// the animation clock.
//
// A stage with `data-composite-url` polls the JSON snapshot every five
// seconds, with an ETag, and draws what it holds. A stage with
// `data-composite-pixels` draws that one contribution and never polls: the
// student's own tile on the result page.
//
// The stylesheet draws the slot states. This file only sets each cell's
// classes (`ChickadeeCompositeCore.slotClasses`) and, on the staff page, its
// title.
(function () {
    'use strict';

    var Core = window.ChickadeeCompositeCore;
    var POLL_MS = 5000;

    function initStage(stage) {
        var spec = Core.specFromDataset(stage.dataset);
        var canvas = stage.querySelector('.js-composite-canvas');
        if (!canvas) { return; }
        var size = Core.canvasSize(spec);
        canvas.width = size.width;
        canvas.height = size.height;
        var context = canvas.getContext('2d');

        var cells = [];
        var cellHost = stage.querySelector('.js-composite-slots');
        if (cellHost) {
            for (var i = 0; i < spec.count; i++) {
                var cell = document.createElement('div');
                cell.className = Core.slotClasses(null).join(' ');
                cellHost.appendChild(cell);
                cells.push(cell);
            }
        }
        var progress = stage.querySelector('.js-composite-progress');
        var playButton = stage.querySelector('.js-composite-play');
        var slider = stage.querySelector('.js-composite-frame');
        var showsOwners = stage.dataset.compositeOwners === 'true';

        var state = Core.emptyState(spec.count);
        var bytesBySlot = {};
        var tick = 0;
        var playing = Core.isAnimated(spec);

        function draw() {
            var image = context.createImageData(size.width, size.height);
            image.data.set(Core.composeRGBA(spec, bytesBySlot, tick));
            context.putImageData(image, 0, 0);
            if (slider) { slider.value = String(tick); }
        }

        function apply(next, changedSlots) {
            state = next;
            var decoded = {};
            Object.keys(state.pixels).forEach(function (slot) {
                decoded[slot] =
                    changedSlots.indexOf(Number(slot)) === -1 && bytesBySlot[slot]
                        ? bytesBySlot[slot]
                        : Core.decodeBase64(state.pixels[slot]);
            });
            bytesBySlot = decoded;
            cells.forEach(function (cell, slot) {
                var slotState = state.slots[slot] || null;
                var classes = Core.slotClasses(slotState);
                if (changedSlots.indexOf(slot) !== -1) { classes.push('composite-slot--arrived'); }
                cell.className = classes.join(' ');
                if (showsOwners) { cell.title = Core.slotTitle(slot, slotState); }
            });
            if (progress) { progress.textContent = Core.progressText(spec, state.complete, state.total); }
            draw();
        }

        var url = stage.dataset.compositeUrl;
        var etag = '';
        function poll() {
            var separator = url.indexOf('?') === -1 ? '?' : '&';
            var request = url + (state.cursor ? separator + 'since=' + encodeURIComponent(state.cursor) : '');
            var headers = etag ? { 'If-None-Match': etag } : {};
            fetch(request, { credentials: 'same-origin', headers: headers })
                .then(function (response) {
                    if (response.status === 304 || !response.ok) { return null; }
                    etag = response.headers.get('ETag') || '';
                    return response.json();
                })
                .then(function (snapshot) {
                    if (!snapshot) { return; }
                    var changed = (snapshot.pixels || []).map(function (p) { return p.slot; });
                    apply(Core.mergeSnapshot(state, snapshot), changed);
                })
                .catch(function () { /* The next poll tries again. */ })
                .then(function () { window.setTimeout(poll, POLL_MS); });
        }

        if (url) {
            poll();
        } else if (stage.dataset.compositePixels) {
            apply(
                Core.mergeSnapshot(state, {
                    complete: 0,
                    total: 1,
                    slots: [{ slot: 0, state: stage.dataset.compositeState || 'passed', rendering: false }],
                    pixels: [{ slot: 0, data: stage.dataset.compositePixels }]
                }),
                []);
        }

        if (playButton) {
            playButton.addEventListener('click', function () {
                playing = !playing;
                playButton.textContent = playing ? 'Pause' : 'Play';
                playButton.setAttribute('aria-pressed', playing ? 'false' : 'true');
            });
        }
        if (slider) {
            slider.max = String(Core.loopLength(spec) - 1);
            slider.addEventListener('input', function () {
                tick = parseInt(slider.value, 10) || 0;
                draw();
            });
        }
        if (Core.isAnimated(spec)) {
            window.setInterval(function () {
                if (!playing) { return; }
                tick = (tick + 1) % Core.loopLength(spec);
                draw();
            }, 1000 / spec.frameRate);
        }
        draw();
    }

    document.querySelectorAll('.js-class-composite').forEach(initStage);
}());
