// Public/celebrate-core.js
//
// The timing and the particle motion of the result-page celebration
// (celebrate.js, docs/result-celebration.md). Ported from the design
// handoff's reference implementation; the numbers are the design's, so keep
// them. Particle speeds are px per 60 fps frame, scaled by the real frame
// time. Nothing here touches the DOM or holds a colour, so the rules run under
// node (celebrate-core.test.mjs) and the wiring keeps the element lookups,
// the drawing and the animation loop.
(function () {
    'use strict';

    function clamp(x) { return Math.max(0, Math.min(1, x)); }
    function easeOut(u) { return 1 - Math.pow(1 - u, 3); }
    function easeInOut(u) { return u < 0.5 ? 4 * u * u * u : 1 - Math.pow(-2 * u + 2, 3) / 2; }
    /// 1 outside (0, 1); inside it rises to 1 + amp and falls back.
    function bump(u, amp) { return (u <= 0 || u >= 1) ? 1 : 1 + amp * Math.sin(Math.PI * u); }

    /// The longest the test cascade may take, in ms. A long suite shortens
    /// the stagger so the count-up still starts within about three seconds.
    var CASCADE_BUDGET = 2400;

    /// The beats of the sequence, in ms from the start, for `rows` test rows.
    /// `cascade` is false when the rows do not replay (the sparkle-only
    /// state); `counts` is false when the grade does not count up.
    function beats(rows, cascade, counts) {
        var stagger = rows > 0 ? Math.min(85, CASCADE_BUDGET / rows) : 85;
        var row = function (i) { return cascade ? 140 + i * stagger : 0; };
        var cStart = cascade && rows > 0 ? row(rows - 1) + 140 : 150;
        var cEnd = counts ? cStart + 650 : cStart;
        return { row: row, cStart: cStart, cEnd: cEnd, pop: cEnd, end: cEnd + 3300 };
    }

    /// What each state plays. `first` and `improved` replay the cascade and
    /// count up; `already` sparkles only.
    function plan(state) {
        return {
            cascade: state === 'first' || state === 'improved',
            counts: state === 'first' || state === 'improved',
            isPerfect: state === 'first' || state === 'already',
            improved: state === 'improved',
            sparkleOnly: state === 'already',
            burst: state === 'first' ? 70 : 0
        };
    }

    /// The values of the DOM pieces at `t` ms. `o` is `plan(state)` with
    /// `from` and `to`, the percents the count-up runs between.
    function frame(t, b, o) {
        var counting = t >= b.cStart;
        var score = !counting ? o.from
            : Math.round(o.from + (o.to - o.from) * easeOut(clamp((t - b.cStart) / ((b.cEnd - b.cStart) || 1))));
        var popU = (t - b.pop) / 340;
        var hu = (t - b.pop) / 560;
        var iu = (t - b.pop) / 320;
        var birdY = 0;
        if (o.isPerfect && !o.sparkleOnly && hu > 0 && hu < 1) { birdY = -8 * Math.abs(Math.sin(2 * Math.PI * hu)); }
        if (o.improved && iu > 0 && iu < 1) { birdY = -5 * Math.sin(Math.PI * iu); }
        var chipU = clamp((t - b.pop) / 450);
        return {
            gradeText: !counting && o.from === 0 ? '—' : score + '%',
            gradeScale: o.sparkleOnly ? 1 : bump(popU, o.isPerfect ? 0.16 : 0.07),
            popped: t >= b.pop,
            birdY: birdY,
            chip: { opacity: easeOut(chipU), y: (1 - easeOut(chipU)) * 10, scale: bump(chipU, 0.18) }
        };
    }

    /// The scale of row `i`'s mark at `t` ms: null before the row's beat
    /// (the row still reads "running"), then 0.7 to 1 with an overshoot.
    function rowPop(t, b, i) {
        if (t < b.row(i)) { return null; }
        var u = clamp((t - b.row(i)) / 240);
        return u < 1 ? 0.7 + 0.3 * easeOut(u) + 0.22 * Math.sin(Math.PI * u) : 1;
    }

    /// `n` feathers and seeds bursting up from `origin` {x, y, w}, the centre
    /// of the grade. A feather takes colour index `i % colourCount`; a seed
    /// takes no index (`colour: -1`), and the wiring gives it the seed
    /// colour. `random` is Math.random, or a seeded one in tests.
    function burst(n, origin, colourCount, random) {
        var parts = [];
        for (var i = 0; i < n; i++) {
            var a = -Math.PI / 2 + (random() - 0.5) * 2.6;
            var sp = 5 + random() * 9;
            var seed = random() < 0.2;
            var base = (random() - 0.5) * 2.4;
            parts.push({
                type: seed ? 'seed' : 'feather',
                x: origin.x + (random() - 0.5) * origin.w * 0.6, y: origin.y,
                vx: Math.cos(a) * sp, vy: Math.sin(a) * sp,
                rot: base, base: base, vr: (random() - 0.5) * 0.3, ph: random() * 6.28,
                len: 16 + random() * 12, wid: 5 + random() * 4,
                colour: seed ? -1 : i % colourCount, life: 0
            });
        }
        return parts;
    }

    /// Sparkle stars round each of `around` [{x, y, rx, ry, n, a0, span,
    /// delay0, delayStep}]: seven round the grade, four round the bird.
    /// Colour index alternates 0 and 1 (gold and teal in the wiring).
    function sparkle(around, random) {
        var parts = [];
        around.forEach(function (c) {
            for (var i = 0; i < c.n; i++) {
                var a = c.a0 + (i / c.n) * c.span + random() * 0.4;
                parts.push({
                    type: 'spark',
                    x: c.x + Math.cos(a) * (c.rx + random() * 12), y: c.y + Math.sin(a) * (c.ry + random() * 10),
                    size: 4 + random() * 5, delay: c.delay0 + i * c.delayStep, colour: i % 2, life: 0
                });
            }
        });
        return parts;
    }

    /// Advances `parts` by `dt` ms on a canvas `height` px tall, and returns
    /// the ones still alive. A spark lives 650 ms after its delay; a feather
    /// or seed lives 5.2 s, or until it falls below the canvas.
    function step(parts, dt, height) {
        var k = dt / 16.67;
        return parts.filter(function (p) {
            p.life += dt;
            if (p.type === 'spark') { return p.life - p.delay <= 650; }
            if (p.type === 'feather') {
                p.vx *= Math.pow(0.93, k);
                p.vy = Math.min(p.vy * Math.pow(0.93, k) + 0.2 * k, 1.5);
                p.ph += 0.055 * k;
                p.x += (p.vx + Math.sin(p.ph) * 1.1) * k;
                p.y += p.vy * k;
                p.rot = p.base + Math.sin(p.ph) * 0.75;
            } else {
                p.vx *= Math.pow(0.97, k);
                p.vy = Math.min(p.vy * Math.pow(0.97, k) + 0.32 * k, 5);
                p.x += p.vx * k;
                p.y += p.vy * k;
                p.rot += p.vr * k;
            }
            return p.y <= height + 40 && p.life <= 5200;
        });
    }

    /// A spark's progress (0 to 1), or null before its delay.
    function sparkProgress(p) {
        var u = (p.life - p.delay) / 650;
        return u <= 0 ? null : clamp(u);
    }

    /// A feather or seed's opacity: full, then fading over its last 1.2 s.
    function opacity(p) {
        return p.life > 4000 ? clamp(1 - (p.life - 4000) / 1200) : 1;
    }

    var api = {
        clamp: clamp, easeOut: easeOut, easeInOut: easeInOut, bump: bump,
        beats: beats, plan: plan, frame: frame, rowPop: rowPop,
        burst: burst, sparkle: sparkle, step: step, sparkProgress: sparkProgress, opacity: opacity
    };

    var root = typeof window !== 'undefined' ? window : globalThis;
    root.ChickadeeCelebrateCore = api;
    // Node export for the .mjs unit tests.
    if (typeof module === 'object' && module.exports) {
        module.exports = api;
    }
}());
