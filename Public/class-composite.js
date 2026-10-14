// Public/class-composite.js
//
// Wires the class-composite view (docs/class-composite.md, slice 5). Every
// `.js-class-composite` element is one stage: a canvas, one cell for each
// slot, and the playback controls when the view moves. The decisions are in
// class-composite-core.js; this file keeps the element lookups and the
// animation clock.
//
// It does not poll. On the leaderboard page and in present mode the stage's
// frame carries `data-poll-swap="json"`, so `table-poll.js` polls the JSON
// snapshot with the shared rules and hands each changed body over as a
// `chickadee:poll-data` event. This file merges it, moves the frame's poll URL
// on to the new cursor, and draws. A stage with `data-composite-pixels` draws
// that one contribution and nothing polls it: the student's own tile on the
// result page.
//
// The stylesheet draws the slot states. This file only sets each cell's
// classes (`ChickadeeCompositeCore.slotClasses`) and, on the staff page, its
// title, which repeats the holder list on the page.
(function () {
    'use strict';

    var Core = window.ChickadeeCompositeCore;

    function initStage(stage) {
        var spec = Core.specFromDataset(stage.dataset);
        var frame = stage.querySelector('.js-composite-frame');
        var canvas = stage.querySelector('.js-composite-canvas');
        if (!frame || !canvas) { return; }
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
        var playButton = stage.querySelector('.js-composite-play');
        var scrub = stage.querySelector('.js-composite-scrub');
        var showsOwners = stage.dataset.compositeOwners === 'true';
        var baseURL = frame.getAttribute('data-poll-url');

        var state = Core.emptyState(spec.count);
        var bytesBySlot = {};
        var tick = 0;
        var playing = Core.isAnimated(spec);

        function draw() {
            var image = context.createImageData(size.width, size.height);
            image.data.set(Core.composeRGBA(spec, bytesBySlot, tick));
            context.putImageData(image, 0, 0);
            if (scrub) { scrub.value = String(tick); }
        }

        function apply(next) {
            // Only a slot whose pixels really changed flashes: the newest
            // slot's pixels come back on every changed poll.
            var arrived = Object.keys(next.pixels).filter(function (slot) {
                return next.pixels[slot] !== state.pixels[slot];
            }).map(Number);
            var decoded = {};
            Object.keys(next.pixels).forEach(function (slot) {
                decoded[slot] = arrived.indexOf(Number(slot)) === -1 && bytesBySlot[slot]
                    ? bytesBySlot[slot]
                    : Core.decodeBase64(next.pixels[slot]);
            });
            state = next;
            bytesBySlot = decoded;
            cells.forEach(function (cell, slot) {
                var slotState = state.slots[slot] || null;
                var classes = Core.slotClasses(slotState);
                if (arrived.indexOf(slot) !== -1) { classes.push('composite-slot--arrived'); }
                cell.className = classes.join(' ');
                if (showsOwners) { cell.title = Core.slotTitle(slot, slotState); }
            });
            draw();
        }

        if (baseURL) {
            frame.addEventListener('chickadee:poll-data', function (event) {
                apply(Core.mergeSnapshot(state, event.detail));
                if (state.cursor) {
                    var separator = baseURL.indexOf('?') === -1 ? '?' : '&';
                    frame.setAttribute('data-poll-url', baseURL + separator + 'since=' + encodeURIComponent(state.cursor));
                }
            });
        } else if (stage.dataset.compositePixels) {
            apply(Core.mergeSnapshot(state, {
                slots: [{ slot: 0, state: stage.dataset.compositeState || 'passed', rendering: false }],
                pixels: [{ slot: 0, data: stage.dataset.compositePixels }]
            }));
        }

        if (playButton) {
            playButton.addEventListener('click', function () {
                playing = !playing;
                playButton.textContent = playing ? 'Pause' : 'Play';
            });
        }
        if (scrub) {
            scrub.max = String(Core.loopLength(spec) - 1);
            scrub.addEventListener('input', function () {
                tick = parseInt(scrub.value, 10) || 0;
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
