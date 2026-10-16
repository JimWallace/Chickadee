// Public/celebrate.js
//
// The result-page celebration (docs/result-celebration.md, J1). The server
// chooses the state and renders it on the bird's group in the grade band:
// `data-celebrate` (first | improved | already), `data-grade-from`,
// `data-grade-to` and `data-announce`. This file reads them and decides
// nothing more. The timing and the particle motion are in celebrate-core.js.
//
// It plays once per submission in this browser
// (`localStorage["ck-celebrated:" + id]`, written when it starts), and never
// for a reader who asked for reduced motion: they see the final page and
// hear its one sentence in the live region.
//
// It makes no styling decision. It sets custom properties that styles.css
// reads, toggles classes, and draws particles in colours it reads from
// custom properties, so the palette stays in the stylesheet.
(function () {
    'use strict';

    var Core = window.ChickadeeCelebrateCore;
    var group = document.querySelector('.submission-bird[data-celebrate]');
    var root = document.getElementById('submission-root');
    if (!Core || !group || !root) { return; }

    var state = group.dataset.celebrate;
    var key = 'ck-celebrated:' + root.dataset.submissionId;
    var reduced = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;

    function alreadyPlayed() {
        try { return window.localStorage.getItem(key) !== null; } catch (_) { return false; }
    }
    function markPlayed() {
        try { window.localStorage.setItem(key, '1'); } catch (_) { /* plays again next load */ }
    }

    if (alreadyPlayed()) { return; }
    markPlayed();
    // A reader who asked for reduced motion sees the final page and hears
    // the same one sentence, once, with nothing moving.
    if (reduced) {
        var region = document.querySelector('.js-celebrate-live');
        if (region) { region.textContent = group.dataset.announce || ''; }
        return;
    }

    var bird = group.querySelector('.avatar');
    var grade = group.querySelector('.score-figure');
    var chip = group.querySelector('.js-grade-gain');
    var live = document.querySelector('.js-celebrate-live');
    var marks = Array.prototype.slice.call(document.querySelectorAll('.results-table .result-mark'));
    var plan = Core.plan(state);
    plan.from = parseInt(group.dataset.gradeFrom, 10) || 0;
    plan.to = parseInt(group.dataset.gradeTo, 10) || 0;
    var beats = Core.beats(marks.length, plan.cascade, plan.counts);
    var finalText = grade ? grade.textContent : '';

    /** A colour from a custom property on `element`, or null. */
    function colour(element, name) {
        var value = window.getComputedStyle(element).getPropertyValue(name).trim();
        return value || null;
    }
    var pageColours = document.documentElement;
    var feathers = ['--av-cap', '--av-wing', '--av-bib', '--av-mark', '--av-accent']
        .map(function (name) { return bird ? colour(bird, name) : null; })
        .concat([colour(pageColours, '--health-teal-light'), colour(pageColours, '--health-teal')])
        .filter(Boolean);
    var seedColour = colour(pageColours, '--celebrate-seed');
    var quillColour = colour(pageColours, '--celebrate-quill');
    var sparkColours = [colour(pageColours, '--celebrate-spark-gold'), colour(pageColours, '--health-teal')];

    // The starting state: every row's mark muted until its beat, as a
    // skipped mark reads, and the grade before its count. A mark that is
    // skipped already stays so.
    group.classList.add('is-celebrating');
    root.classList.add('is-celebrating');
    var muted = plan.cascade ? marks.filter(function (mark) {
        return !mark.classList.contains('result-mark-skipped');
    }) : [];
    muted.forEach(function (mark) { mark.classList.add('result-mark-skipped'); });
    if (plan.counts && grade) {
        // Hold the final width while the grade counts, so the tiles beside
        // it do not slide as "—" grows to "100%". This is measured layout
        // geometry, not a styling decision.
        grade.style.setProperty('--celebrate-grade-width', grade.getBoundingClientRect().width + 'px');
        grade.classList.add('score-figure-counting');
        grade.classList.remove('score-figure-perfect');
        grade.textContent = plan.from === 0 ? '—' : plan.from + '%';
    }
    if (chip) { chip.style.setProperty('--celebrate-chip-opacity', '0'); }

    var canvas = null;
    var ctx = null;
    var parts = [];
    var burstDone = false;

    function sizeCanvas() {
        if (!canvas) { return; }
        var ratio = window.devicePixelRatio || 1;
        canvas.width = Math.round(canvas.clientWidth * ratio);
        canvas.height = Math.round(canvas.clientHeight * ratio);
        ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
    }
    function ensureCanvas() {
        if (canvas) { return; }
        canvas = document.createElement('canvas');
        canvas.className = 'celebrate-canvas';
        canvas.setAttribute('aria-hidden', 'true');
        document.body.appendChild(canvas);
        ctx = canvas.getContext('2d');
        sizeCanvas();
        window.addEventListener('resize', sizeCanvas);
    }
    function centre(element) {
        var box = element.getBoundingClientRect();
        return { x: box.left + box.width / 2, y: box.top + box.height / 2, w: box.width, h: box.height };
    }
    function startParticles() {
        if (burstDone) { return; }
        burstDone = true;
        if (plan.burst > 0 && grade && feathers.length) {
            ensureCanvas();
            parts = parts.concat(Core.burst(plan.burst, centre(grade), feathers.length, Math.random));
        }
    }
    function startSparkle() {
        if (!grade || !bird) { return; }
        ensureCanvas();
        var g = centre(grade);
        var b = centre(bird);
        parts = parts.concat(Core.sparkle([
            { x: g.x, y: g.y, rx: g.w / 2 + 6, ry: g.h / 2 + 6, n: 7, a0: 0, span: Math.PI * 2, delay0: 0, delayStep: 70 },
            { x: b.x, y: b.y, rx: b.w / 2 + 4, ry: b.h / 2 + 4, n: 4, a0: -Math.PI, span: Math.PI * 2, delay0: 120, delayStep: 90 }
        ], Math.random));
    }

    function drawParticles() {
        if (!ctx) { return; }
        ctx.clearRect(0, 0, canvas.clientWidth, canvas.clientHeight);
        parts.forEach(function (p) {
            ctx.save();
            if (p.type === 'spark') {
                var u = Core.sparkProgress(p);
                if (u === null) { ctx.restore(); return; }
                var s = p.size * Math.sin(Math.PI * u);
                ctx.translate(p.x, p.y);
                ctx.rotate(u * 0.8);
                ctx.fillStyle = sparkColours[p.colour] || sparkColours[1];
                ctx.beginPath();
                for (var j = 0; j < 8; j++) {
                    var r = j % 2 ? s * 0.32 : s;
                    var an = j * Math.PI / 4;
                    ctx.lineTo(Math.sin(an) * r, -Math.cos(an) * r);
                }
                ctx.closePath();
                ctx.fill();
                ctx.restore();
                return;
            }
            ctx.globalAlpha = Core.opacity(p);
            ctx.translate(p.x, p.y);
            ctx.rotate(p.rot);
            ctx.fillStyle = p.colour < 0 ? seedColour : feathers[p.colour];
            if (p.type === 'feather') {
                ctx.beginPath();
                ctx.moveTo(0, -p.len / 2);
                ctx.quadraticCurveTo(p.wid, -p.len / 6, 0, p.len / 2 - 3);
                ctx.quadraticCurveTo(-p.wid, -p.len / 6, 0, -p.len / 2);
                ctx.fill();
                if (quillColour) {
                    ctx.strokeStyle = quillColour;
                    ctx.lineWidth = 1;
                    ctx.beginPath();
                    ctx.moveTo(0, -p.len / 2 + 2);
                    ctx.lineTo(0, p.len / 2 + 3);
                    ctx.stroke();
                }
            } else {
                ctx.beginPath();
                ctx.ellipse(0, 0, 2.6, 4, 0, 0, Math.PI * 2);
                ctx.fill();
            }
            ctx.restore();
        });
    }

    var announced = false;
    function applyFrame(t) {
        if (plan.cascade) {
            marks.forEach(function (mark, i) {
                var scale = Core.rowPop(t, beats, i);
                if (scale === null) { return; }
                if (muted.indexOf(mark) >= 0) { mark.classList.remove('result-mark-skipped'); }
                mark.style.setProperty('--celebrate-mark-scale', String(scale));
            });
        }
        var f = Core.frame(t, beats, plan);
        if (grade && plan.counts) {
            grade.textContent = f.popped ? finalText : f.gradeText;
            if (t >= beats.cStart) { grade.classList.remove('score-figure-counting'); }
        }
        if (grade) { grade.style.setProperty('--celebrate-grade-scale', String(f.gradeScale)); }
        if (f.popped && plan.isPerfect && grade) { grade.classList.add('score-figure-perfect'); }
        if (bird) { bird.style.setProperty('--celebrate-bird-y', f.birdY + 'px'); }
        if (chip && f.popped) {
            chip.style.setProperty('--celebrate-chip-opacity', String(f.chip.opacity));
            chip.style.setProperty('--celebrate-chip-y', f.chip.y + 'px');
            chip.style.setProperty('--celebrate-chip-scale', String(f.chip.scale));
        }
        if (f.popped && !announced) {
            announced = true;
            if (live) { live.textContent = group.dataset.announce || ''; }
            startParticles();
        }
    }

    function finish() {
        muted.forEach(function (mark) { mark.classList.remove('result-mark-skipped'); });
        marks.forEach(function (mark) { mark.style.removeProperty('--celebrate-mark-scale'); });
        if (grade) {
            grade.textContent = finalText;
            grade.classList.remove('score-figure-counting');
            grade.style.removeProperty('--celebrate-grade-scale');
            grade.style.removeProperty('--celebrate-grade-width');
            if (plan.isPerfect) { grade.classList.add('score-figure-perfect'); }
        }
        if (bird) { bird.style.removeProperty('--celebrate-bird-y'); }
        if (chip) {
            ['--celebrate-chip-opacity', '--celebrate-chip-y', '--celebrate-chip-scale']
                .forEach(function (name) { chip.style.removeProperty(name); });
        }
        if (live && !announced) { live.textContent = group.dataset.announce || ''; }
        group.classList.remove('is-celebrating');
        root.classList.remove('is-celebrating');
        if (canvas) {
            window.removeEventListener('resize', sizeCanvas);
            canvas.remove();
            canvas = null;
            ctx = null;
        }
    }

    var start = null;
    var last = null;
    var sparkled = false;
    function tick(now) {
        if (start === null) { start = now; last = now; }
        var t = now - start;
        // A hidden page pauses the clock: a long gap does not jump the
        // particles to their end.
        var dt = Math.min(now - last, 50);
        last = now;
        if (plan.sparkleOnly && !sparkled && t >= 200) {
            sparkled = true;
            startSparkle();
        }
        if (t <= beats.end) { applyFrame(t); }
        if (parts.length) {
            parts = Core.step(parts, dt, canvas ? canvas.clientHeight : window.innerHeight);
            drawParticles();
        }
        if (t > beats.end && !parts.length) {
            finish();
            return;
        }
        window.requestAnimationFrame(tick);
    }

    document.addEventListener('visibilitychange', function () {
        if (!document.hidden && start !== null) { last = performance.now(); }
    });
    window.requestAnimationFrame(tick);
}());
