// Public/jl-cell-perf-patch.js
//
// Coalesces Notebook 7's per-output forced reflows — the measured cause of the
// multi-second main-thread freezes the freeze watchdog reports as
// `page_unresponsive` (Aug 2026, HLTH 230; reproduced and profiled by
// Tools/editor-smoke-test/freeze-trace-check.mjs; full writeup in
// docs/browser-freeze-investigation.md). Two upstream listeners run once per
// IOPub output message and each forces a synchronous style+layout flush of a
// document whose layout the just-inserted output invalidated:
//
//   1. `CodeCell.updatePromptOverlayIcon` (@jupyterlab/cells) reads
//      `overlay.clientHeight`; it is connected to BOTH `outputs.changed` and
//      `outputs.stateChanged`.
//   2. The `:scroll-output` plugin (@jupyter-notebook/notebook-extension)
//      reads `outputArea.node.scrollHeight` per cell per output change to
//      auto-collapse outputs taller than ~130 lines.
//
// A data-lab "run all" (rendered DataFrame tables, figures) makes that
// N outputs × full-document reflow: ~1.7s blocked at 3x CPU throttle on CI
// hardware, the ≥8s freeze class on a mid-range laptop. Current upstream main
// has the same implementations, so there is no newer bundle to inherit a fix
// from.
//
// Both jobs are pure presentation, so the fix is per-frame cadence instead of
// per-message: the overlay-icon method is wrapped to run the ORIGINAL at most
// once per animation frame per cell, and — with the upstream `:scroll-output`
// plugin disabled via `disabledExtensions` (jupyter-lite.json), since its
// per-message handler would both re-pay the reflow and fight this class
// toggle — the same per-frame callback re-applies the auto-collapse rule with
// upstream's exact semantics (user-set `scrolled` metadata wins; threshold
// 1.3 × fontSize × 100). The browser performs one layout per rendered frame
// anyway, making the marginal cost ~zero, and both affordances still update
// within one frame of the last output. The patch is applied to the CodeCell
// PROTOTYPE, discovered by walking a live code cell's prototype chain — NOT
// by editing the vendored bundle, whose content-hashed filename is served
// immutable for a year (an in-place byte patch would never reach returning
// students; the #574 class).
//
// Fail-safe by construction: every step is guarded, and if the editor's
// structure ever changes so a code cell (or the method) cannot be found, the
// retry loop caps out and the editor runs exactly as unpatched. Injected into
// the notebooks editor document (cache-busted, beside the diagnostics
// collector) by scripts/patch-jupyterlite-diagnostics.py; asserted by
// scripts/verify-jupyterlite.sh.

(function () {
    'use strict';

    var MAX_ATTEMPTS = 120;   // ~2 min of 1s retries, then give up quietly
    var attempts = 0;
    var applied = false;

    // Walk a live code cell's prototype chain to the prototype that OWNS
    // updatePromptOverlayIcon (the upstream CodeCell prototype). Returns null
    // until the notebook has rendered a code cell — the retry loop's job.
    function findCodeCellPrototype(win) {
        try {
            var app = win.jupyterapp;
            var panel = app && app.shell && app.shell.currentWidget;
            var widgets = panel && panel.content && panel.content.widgets;
            if (!widgets || !widgets.length) return null;
            for (var i = 0; i < widgets.length; i++) {
                var cell = widgets[i];
                if (!cell || !cell.model || cell.model.type !== 'code') continue;
                var proto = cell;
                while ((proto = Object.getPrototypeOf(proto))) {
                    if (Object.prototype.hasOwnProperty.call(proto, 'updatePromptOverlayIcon')) {
                        return proto;
                    }
                }
                // A code cell without the method: the upstream shape changed —
                // stop probing and leave the editor untouched.
                return null;
            }
            return null;
        } catch (_) { return null; }
    }

    // The auto-collapse rule of the disabled `:scroll-output` plugin, applied
    // at per-frame cadence. Mirrors upstream exactly: a user-set `scrolled`
    // metadata value always wins, and an output area taller than
    // 1.3 × fontSize × 100 (~130 lines at the default 14px) gets the scrolled
    // class — toggled in both directions, so a cleared output un-collapses.
    var SCROLLED_CLASS = 'jp-mod-outputsScrolled';
    function autoScrollCheck(cell) {
        try {
            if (!cell || !cell.outputArea || !cell.model) return;
            if (typeof cell.model.getMetadata === 'function' &&
                cell.model.getMetadata('scrolled') !== undefined) return;
            var node = cell.outputArea.node;
            if (!node || typeof cell.toggleClass !== 'function') return;
            var fontSize = parseFloat((node.style.fontSize || '').replace('px', ''));
            cell.toggleClass(SCROLLED_CLASS, node.scrollHeight > 1.3 * (fontSize || 14) * 100);
        } catch (_) { /* presentation only — never propagate */ }
    }

    // Wrap `original` so that any number of same-frame calls on one cell run
    // it once, on the next animation frame — followed by the auto-collapse
    // check, which rides the same frame's single layout pass. Per-instance
    // flag, so concurrent cells coalesce independently.
    function coalesce(original, raf) {
        var wrapped = function () {
            var self = this;
            if (self._ckOverlayIconQueued) return;
            self._ckOverlayIconQueued = true;
            raf(function () {
                self._ckOverlayIconQueued = false;
                try {
                    if (self.isDisposed) return;
                    original.call(self);
                    autoScrollCheck(self);
                } catch (_) { /* presentation only — never propagate */ }
            });
        };
        wrapped.__ckCoalesced = true;
        return wrapped;
    }

    function tryPatch(win, raf) {
        if (applied) return true;
        var proto = findCodeCellPrototype(win);
        if (!proto) return false;
        var original = proto.updatePromptOverlayIcon;
        if (typeof original !== 'function') return false;
        if (original.__ckCoalesced) { applied = true; return true; }
        proto.updatePromptOverlayIcon = coalesce(original, raf);
        applied = true;
        // One initial auto-collapse pass over the cells that already exist:
        // a reopened notebook restores saved outputs without any output-change
        // event, and upstream's plugin covered that case at widgetAdded.
        try {
            var widgets = win.jupyterapp.shell.currentWidget.content.widgets;
            raf(function () {
                try {
                    for (var i = 0; i < widgets.length; i++) {
                        if (widgets[i] && widgets[i].model && widgets[i].model.type === 'code') {
                            autoScrollCheck(widgets[i]);
                        }
                    }
                } catch (_) { /* presentation only */ }
            });
        } catch (_) { /* ignore */ }
        // Marker for the freeze-trace harness / manual debugging only.
        try { win.__ckCellPerfPatch = 'applied'; } catch (_) { /* ignore */ }
        return true;
    }

    function loop() {
        try {
            if (tryPatch(window, function (fn) { window.requestAnimationFrame(fn); })) return;
        } catch (_) { /* never throw into the editor */ }
        attempts += 1;
        if (attempts >= MAX_ATTEMPTS) return;
        setTimeout(loop, 1000);
    }

    try {
        if (typeof window !== 'undefined' && typeof window.requestAnimationFrame === 'function') {
            loop();
        }
    } catch (_) { /* never throw into the editor */ }

    // Test seam (Node vm): exercise the pure pieces without a browser.
    try {
        var hooks = (typeof globalThis !== 'undefined') && globalThis.__CK_CELL_PERF_PATCH_TEST_HOOKS__;
        if (hooks) {
            hooks.exports = {
                findCodeCellPrototype: findCodeCellPrototype,
                coalesce: coalesce,
                tryPatch: tryPatch,
                autoScrollCheck: autoScrollCheck,
            };
        }
    } catch (_) { /* ignore */ }
})();
