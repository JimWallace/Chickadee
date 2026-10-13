// Public/class-composite-core.js
//
// The decisions behind the class-composite view (class-composite.js,
// docs/class-composite.md): how big the canvas is, which frame of which slot
// the shared clock shows, where a slot's pixels land, how the four
// compositors combine contributions into RGBA, and how a JSON snapshot
// merges into what the page already holds. Nothing here touches the DOM, so
// the rules run under node (class-composite-core.test.mjs) and the wiring
// keeps only element lookups, the poll and the animation loop.
(function () {
    'use strict';

    var CHANNELS = { gray8: 1, rgb8: 3 };

    /// The spec the page carries in data attributes, as numbers.
    /// `dataset` is an element's dataset or a plain object of strings.
    function specFromDataset(dataset) {
        function int(name, fallback) {
            var value = parseInt(dataset[name], 10);
            return isNaN(value) ? fallback : value;
        }
        var columns = int('compositeCols', 0);
        var rows = int('compositeRows', 0);
        return {
            compositor: dataset.compositeCompositor || 'tile',
            columns: columns,
            rows: rows,
            count: int('compositeCount', columns * rows),
            width: int('compositeW', 1),
            height: int('compositeH', 1),
            frames: int('compositeFrames', 1),
            format: dataset.compositeFormat === 'rgb8' ? 'rgb8' : 'gray8',
            frameRate: Math.max(1, int('compositeFrameRate', 12))
        };
    }

    /// True when the layout places slots on a grid in one canvas.
    function usesGrid(spec) {
        return spec.compositor === 'tile' || spec.compositor === 'gallery';
    }

    /// The canvas size in contribution pixels.
    function canvasSize(spec) {
        if (usesGrid(spec)) {
            return { width: spec.columns * spec.width, height: spec.rows * spec.height };
        }
        return { width: spec.width, height: spec.height };
    }

    /// The number of ticks in one pass of the shared clock. A sequence plays
    /// every slot's frames in slot order; the others play one contribution's
    /// frames, all slots together.
    function loopLength(spec) {
        return spec.compositor === 'sequence' ? spec.count * spec.frames : spec.frames;
    }

    /// True when the view moves: more than one frame, or a sequence.
    function isAnimated(spec) {
        return loopLength(spec) > 1;
    }

    /// Which slot (a sequence only) and which frame the clock shows at `tick`.
    function frameAt(spec, tick) {
        var length = loopLength(spec);
        var t = ((tick % length) + length) % length;
        if (spec.compositor === 'sequence') {
            return { slot: Math.floor(t / spec.frames), frame: t % spec.frames };
        }
        return { slot: null, frame: t };
    }

    /// The top-left canvas pixel of a slot in a grid layout.
    function slotOrigin(spec, slot) {
        return { x: (slot % spec.columns) * spec.width, y: Math.floor(slot / spec.columns) * spec.height };
    }

    /// Standard base64 to bytes. `atob` exists in every browser and in node.
    function decodeBase64(text) {
        var binary = atob(text);
        var bytes = new Uint8Array(binary.length);
        for (var i = 0; i < binary.length; i++) { bytes[i] = binary.charCodeAt(i); }
        return bytes;
    }

    /// One frame of a contribution as RGBA, `width × height × 4` bytes.
    function frameRGBA(spec, bytes, frame) {
        var channels = CHANNELS[spec.format];
        var pixels = spec.width * spec.height;
        var out = new Uint8ClampedArray(pixels * 4);
        var start = frame * pixels * channels;
        for (var p = 0; p < pixels; p++) {
            var at = start + p * channels;
            out[p * 4] = bytes[at];
            out[p * 4 + 1] = bytes[at + (channels === 3 ? 1 : 0)];
            out[p * 4 + 2] = bytes[at + (channels === 3 ? 2 : 0)];
            out[p * 4 + 3] = 255;
        }
        return out;
    }

    /// The whole canvas at `tick`, as RGBA. `pixelsBySlot` maps a slot to its
    /// decoded bytes; a slot with none stays transparent, so the grid outline
    /// shows through.
    function composeRGBA(spec, pixelsBySlot, tick) {
        var size = canvasSize(spec);
        var out = new Uint8ClampedArray(size.width * size.height * 4);
        var at = frameAt(spec, tick);
        if (spec.compositor === 'sequence') {
            var bytes = pixelsBySlot[at.slot];
            if (bytes) { out.set(frameRGBA(spec, bytes, at.frame)); }
            return out;
        }
        if (spec.compositor === 'sum') {
            return sumRGBA(spec, pixelsBySlot, at.frame, out);
        }
        Object.keys(pixelsBySlot).forEach(function (key) {
            var slot = Number(key);
            var frame = frameRGBA(spec, pixelsBySlot[key], at.frame);
            var origin = slotOrigin(spec, slot);
            for (var y = 0; y < spec.height; y++) {
                var row = frame.subarray(y * spec.width * 4, (y + 1) * spec.width * 4);
                out.set(row, ((origin.y + y) * size.width + origin.x) * 4);
            }
        });
        return out;
    }

    /// Every contribution added pixel by pixel, scaled so the brightest
    /// sample is 255: one backprojected angle each.
    function sumRGBA(spec, pixelsBySlot, frame, out) {
        var keys = Object.keys(pixelsBySlot);
        if (keys.length === 0) { return out; }
        var sums = new Float64Array(spec.width * spec.height * 3);
        keys.forEach(function (key) {
            var rgba = frameRGBA(spec, pixelsBySlot[key], frame);
            for (var p = 0; p < spec.width * spec.height; p++) {
                sums[p * 3] += rgba[p * 4];
                sums[p * 3 + 1] += rgba[p * 4 + 1];
                sums[p * 3 + 2] += rgba[p * 4 + 2];
            }
        });
        var max = 0;
        for (var i = 0; i < sums.length; i++) { if (sums[i] > max) { max = sums[i]; } }
        var scale = max > 0 ? 255 / max : 0;
        for (var q = 0; q < spec.width * spec.height; q++) {
            out[q * 4] = Math.round(sums[q * 3] * scale);
            out[q * 4 + 1] = Math.round(sums[q * 3 + 1] * scale);
            out[q * 4 + 2] = Math.round(sums[q * 3 + 2] * scale);
            out[q * 4 + 3] = 255;
        }
        return out;
    }

    /// Merges a snapshot into the page's state: `{ cursor, complete, total,
    /// slots: { [slot]: { state, rendering, owner } }, pixels: { [slot]: data } }`.
    /// A snapshot lists every slot that is not empty, so a slot it leaves out
    /// is empty again; pixels arrive only for slots that changed.
    function mergeSnapshot(state, snapshot) {
        var slots = {};
        var pixels = {};
        (snapshot.slots || []).forEach(function (s) {
            slots[s.slot] = { state: s.state, rendering: !!s.rendering, owner: s.owner || '' };
            if (s.state !== 'empty' && state.pixels[s.slot]) { pixels[s.slot] = state.pixels[s.slot]; }
        });
        (snapshot.pixels || []).forEach(function (p) {
            if (slots[p.slot] && slots[p.slot].state !== 'empty') { pixels[p.slot] = p.data; }
        });
        return {
            cursor: snapshot.cursor || state.cursor,
            complete: snapshot.complete || 0,
            total: snapshot.total || state.total,
            slots: slots,
            pixels: pixels
        };
    }

    /// The empty state before the first poll.
    function emptyState(total) {
        return { cursor: '', complete: 0, total: total, slots: {}, pixels: {} };
    }

    /// The classes a slot's cell carries. The stylesheet draws them.
    function slotClasses(slotState) {
        var classes = ['composite-slot'];
        var state = slotState ? slotState.state : 'empty';
        classes.push('composite-slot--' + state);
        if (slotState && slotState.rendering) { classes.push('composite-slot--rendering'); }
        return classes;
    }

    /// The cell's tooltip on the staff page: the holder's handle and state.
    function slotTitle(slot, slotState) {
        var label = 'Slot ' + slot;
        if (!slotState) { return label + ': empty'; }
        var words = { passed: 'passed', failed: 'did not pass', empty: 'empty' };
        var text = label + (slotState.owner ? ' · ' + slotState.owner : '') + ': ' + words[slotState.state];
        return slotState.rendering ? text + ', grading' : text;
    }

    /// "31 of 48 tiles complete".
    function progressText(spec, complete, total) {
        var noun = { tile: 'tiles', gallery: 'panels', sequence: 'frames', sum: 'angles' }[spec.compositor] || 'slots';
        return complete + ' of ' + total + ' ' + noun + ' complete';
    }

    var api = {
        specFromDataset: specFromDataset,
        usesGrid: usesGrid,
        canvasSize: canvasSize,
        loopLength: loopLength,
        isAnimated: isAnimated,
        frameAt: frameAt,
        slotOrigin: slotOrigin,
        decodeBase64: decodeBase64,
        frameRGBA: frameRGBA,
        composeRGBA: composeRGBA,
        mergeSnapshot: mergeSnapshot,
        emptyState: emptyState,
        slotClasses: slotClasses,
        slotTitle: slotTitle,
        progressText: progressText
    };

    var root = typeof window !== 'undefined' ? window : globalThis;
    root.ChickadeeCompositeCore = api;
    // Node export for the .mjs unit tests.
    if (typeof module === 'object' && module.exports) {
        module.exports = api;
    }
}());
