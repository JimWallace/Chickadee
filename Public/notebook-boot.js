// Public/notebook-boot.js
//
// The loading panel over the notebook editor while it starts (NB1, design
// frame 18e). `NotebookBootPanel` renders `#nb-boot` over `#jl-frame` with the
// first step active. This script moves it through its three steps and fades it
// out when the kernel is idle:
//
//   Load the editor               done at app_ready
//   Download and start {Language} active from kernel_starting, done at kernel_idle
//   Open your notebook            active at kernel_idle, then the panel fades
//
// The phases are the `kernel-diag` messages that jl-kernel-diagnostics.js
// posts from inside the editor iframe. notebook.js forwards the same messages
// to the diagnostics pipeline; this script only reads them.
//
// The existing notices win. The failure panel replaces this panel
// (notebook-preflight.js `showFailure` hides it), and the slow-boot and
// low-memory notices sit above it in the page. A boot that stalls
// (`boot_stalled`, 75s) dismisses the panel, so the page shows the editor as
// it did before this panel existed.
//
// It looks up `#nb-boot` on every message rather than holding it: the
// workbench swaps the notebook half for a fresh panel when it opens another
// notebook, and the fresh panel starts at the first step.

(function (global) {
    'use strict';

    var STEPS = ['editor', 'kernel', 'notebook'];
    var PHASE_ORDER = ['boot_start', 'app_ready', 'kernel_starting', 'kernel_idle'];
    var FADE_MS = 200;

    /// The state of each step while the panel shows `phase`. Pure.
    function stepStates(phase) {
        switch (phase) {
        case 'app_ready':
            return { editor: 'done', kernel: 'pending', notebook: 'pending' };
        case 'kernel_starting':
            return { editor: 'done', kernel: 'active', notebook: 'pending' };
        case 'kernel_idle':
            return { editor: 'done', kernel: 'done', notebook: 'active' };
        default:
            return { editor: 'active', kernel: 'pending', notebook: 'pending' };
        }
    }

    /// The phase the panel shows after `incoming`, when it shows `current`.
    /// A phase never moves the panel back, with one exception: `boot_start`
    /// comes from a new editor document (a recovery reload), so the steps start
    /// again. An unknown phase changes nothing. Pure.
    function nextPhase(current, incoming) {
        var rank = PHASE_ORDER.indexOf(incoming);
        if (rank === -1) return current;
        if (incoming === 'boot_start') return incoming;
        if (PHASE_ORDER.indexOf(current) >= rank) return current;
        return incoming;
    }

    var api = { stepStates: stepStates, nextPhase: nextPhase };

    if (typeof document !== 'undefined' && typeof window !== 'undefined') {
        var fadeTimer = null;

        var panel = function () { return document.getElementById('nb-boot'); };

        var setKernelChip = function (state) {
            var chip = document.getElementById('nb-kernel-chip');
            if (!chip) return;
            chip.setAttribute('data-state', state);
            var text = chip.querySelector('.js-nb-kernel-state');
            if (text) text.textContent = state;
        };

        // Write the step states, and announce each step once, when it becomes
        // the active one.
        var render = function (el, phase) {
            var states = stepStates(phase);
            el.setAttribute('data-phase', phase);
            STEPS.forEach(function (name) {
                var step = el.querySelector('[data-boot-step="' + name + '"]');
                if (!step) return;
                var before = step.getAttribute('data-state');
                step.setAttribute('data-state', states[name]);
                if (states[name] === 'active' && before !== 'active') {
                    var live = el.querySelector('.js-nb-boot-live');
                    if (live) live.textContent = step.textContent.trim();
                }
            });
        };

        var show = function (phase) {
            var el = panel();
            if (!el) return;
            if (fadeTimer) {
                clearTimeout(fadeTimer);
                fadeTimer = null;
            }
            el.classList.remove('nb-boot-leaving');
            el.hidden = false;
            render(el, phase);
            setKernelChip('starting');
            var chip = document.getElementById('nb-kernel-chip');
            if (chip) chip.hidden = false;
        };

        // A stalled boot: the page shows the editor as it is, and the chip
        // would claim a state that no longer holds, so it goes too.
        var dismiss = function () {
            var el = panel();
            if (el) el.hidden = true;
            var chip = document.getElementById('nb-kernel-chip');
            if (chip) chip.hidden = true;
        };

        // The kernel is idle: the last step is active while the panel fades.
        var finish = function () {
            setKernelChip('ready');
            var el = panel();
            if (!el || el.hidden || fadeTimer) return;
            render(el, 'kernel_idle');
            el.classList.add('nb-boot-leaving');
            fadeTimer = setTimeout(function () {
                fadeTimer = null;
                el.hidden = true;
                el.classList.remove('nb-boot-leaving');
            }, FADE_MS);
        };

        var onMessage = function (e) {
            try {
                if (!e || e.origin !== window.location.origin) return;
                var d = e.data;
                if (!d || d.ck !== 'kernel-diag') return;
                if (d.kind === 'kernel_error' && d.source === 'boot_stalled') {
                    dismiss();
                    return;
                }
                if (d.kind !== 'kernel_phase') return;
                var el = panel();
                if (!el) return;
                if (d.source === 'boot_start') {
                    // A new editor document. On the first load the panel already
                    // shows this step; after a recovery reload it shows it again.
                    if (el.hidden || el.getAttribute('data-phase') !== 'boot_start') show('boot_start');
                    return;
                }
                if (el.hidden) return;
                var phase = nextPhase(el.getAttribute('data-phase'), d.source);
                if (phase === 'kernel_idle') {
                    finish();
                } else {
                    render(el, phase);
                }
            } catch (_) { /* the panel must never break the page */ }
        };

        window.addEventListener('message', onMessage);

        api.finish = finish;
        api.dismiss = dismiss;
        global.ChickadeeNotebookBoot = api;
    }

    // Node export for the .mjs unit tests (Tests/BrowserRunnerJSTests).
    if (typeof module === 'object' && module.exports) {
        module.exports = api;
    }
})(typeof self !== 'undefined' ? self : this);
