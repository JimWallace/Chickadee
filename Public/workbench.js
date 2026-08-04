// Public/workbench.js
//
// The assignment workbench shell: the instructor edit page in a left pane, the
// notebook editor in a right pane, a draggable splitter between them, and a tab
// strip that switches the right pane between the starter notebook and the
// reference solution.
//
// The shell owns no assignment content — every pane is an iframe onto a page
// that already existed.  What lives here is the composition: pane sizing, which
// notebook is mounted, and the messages the panes send each other.
//
// Three things are load-bearing and easy to get wrong:
//
//   * **Pane floors.** The notebook page hides its own editor below 640px and
//     shows "open on a larger screen".  A too-narrow notebook pane would
//     therefore render that notice instead of the editor — so the splitter
//     clamps the notebook pane at 720px and the edit pane at 380px, and below a
//     viewport that can hold both the layout drops to one pane at a time.
//
//   * **Kernel count.** The solution iframe stays at about:blank until its tab
//     is first selected, then stays mounted, so switching is instant after one
//     boot.  On a device that reports low memory it is unmounted on switch
//     instead — one kernel at a time, at the cost of a reboot per switch.
//
//   * **Idle logout.** The watchdog runs in this document, but every keystroke
//     lands in a pane.  `embedded-activity.js` forwards activity up; this file
//     re-raises it as `chickadee:activity`, which idle-logout.js listens for.
//     Without that an author gets signed out mid-edit.

(function () {
    'use strict';

    // Minimum widths, in px.  NOTEBOOK_MIN sits deliberately clear of the
    // notebook page's own 640px small-screen cutoff.
    var NOTEBOOK_MIN = 720;
    var EDIT_MIN = 380;
    // Splitter column width (.5rem) — kept in sync with .wb-splitter in
    // workbench.leaf.  Only used for arithmetic, never for styling.
    var SPLITTER_PX = 8;
    // Below this the split is not honest: 720 + 380 + splitter.  Matches the
    // media query in workbench.leaf.
    var SINGLE_PANE_MAX = 1140;
    var KEY_STEP_PX = 24;

    /// Clamp a desired left-pane width so neither pane drops below its floor.
    /// Pure arithmetic, exported for test: this is the rule that keeps the
    /// notebook pane from rendering "open on a larger screen".
    ///
    /// When the viewport cannot satisfy both floors at once the edit pane
    /// yields — the notebook is the pane with the hard rendering cliff, so it
    /// is the one that must keep its width.
    function clampLeftWidth(desiredPx, totalPx) {
        var maxLeft = totalPx - SPLITTER_PX - NOTEBOOK_MIN;
        if (maxLeft < EDIT_MIN) return Math.max(0, maxLeft);
        if (desiredPx < EDIT_MIN) return EDIT_MIN;
        if (desiredPx > maxLeft) return maxLeft;
        return desiredPx;
    }

    /// Whether this device should hold two Pyodide kernels at once.
    /// `navigator.deviceMemory` is GB rounded to a power of two and is absent
    /// on Firefox/Safari — absent means "no evidence of a problem", so we keep
    /// both mounted, matching notebook-preflight.js's own conservative read.
    function allowsTwoKernels(nav) {
        var dm = (nav && typeof nav.deviceMemory === 'number') ? nav.deviceMemory : null;
        if (dm === null) return true;
        return dm > 4;
    }

    /// Toggle the edit pane between collapsed and its last expanded width.
    ///
    /// Kept as a pure transition on an explicit state object because the bug
    /// this shape prevents is a real one: collapsing while already collapsed
    /// must not overwrite the remembered width with 0, or the pane can never be
    /// restored and the author is left with no way back to the editor short of
    /// dragging the splitter out from the edge.
    ///
    /// `state` is `{ collapsed, width, restoreWidth }`; the return is the same
    /// shape.
    function toggleCollapse(state) {
        if (state.collapsed) {
            return { collapsed: false, width: state.restoreWidth, restoreWidth: state.restoreWidth };
        }
        return { collapsed: true, width: 0, restoreWidth: state.width };
    }

    // Exported for the unit tests, which exercise the arithmetic and the
    // policy without a DOM.
    var api = {
        clampLeftWidth: clampLeftWidth,
        allowsTwoKernels: allowsTwoKernels,
        toggleCollapse: toggleCollapse
    };
    if (typeof window !== 'undefined') window.ChickadeeWorkbench = api;
    if (typeof module !== 'undefined' && module.exports) module.exports = api;

    if (typeof document === 'undefined') return;
    var shell = document.getElementById('wb-shell');
    if (!shell) return;

    var body = shell.querySelector('.wb-body');
    var splitter = document.getElementById('wb-splitter');
    var editFrame = document.getElementById('wb-edit-frame');
    var staleChip = document.getElementById('wb-stale-chip');
    var singleEditBtn = document.getElementById('wb-single-edit');
    var assignmentID = shell.getAttribute('data-assignment-id') || '';
    var storageKey = 'chickadee-workbench-split:' + assignmentID;

    var tabs = Array.prototype.slice.call(shell.querySelectorAll('.wb-tab'));
    var panes = {};
    tabs.forEach(function (tab) {
        var name = tab.getAttribute('data-wb-pane');
        panes[name] = document.getElementById(tab.getAttribute('aria-controls'));
    });
    var activePane = 'assignment';

    // ── Splitter ──────────────────────────────────────────────────────────

    function applyLeftWidth(px) {
        var total = body ? body.clientWidth : 0;
        if (!total) return;
        var clamped = clampLeftWidth(px, total);
        shell.style.setProperty('--wb-left-width', clamped + 'px');
        if (splitter) {
            splitter.setAttribute('aria-valuenow', String(Math.round((clamped / total) * 100)));
        }
        return clamped;
    }

    function currentLeftWidth() {
        var pane = shell.querySelector('.wb-pane-edit');
        return pane ? pane.getBoundingClientRect().width : EDIT_MIN;
    }

    function persist(px) {
        try { window.localStorage.setItem(storageKey, String(Math.round(px))); } catch (_) { /* private mode */ }
    }

    function restore() {
        var saved = null;
        try { saved = window.localStorage.getItem(storageKey); } catch (_) { /* private mode */ }
        var px = saved ? parseInt(saved, 10) : NaN;
        if (!isNaN(px) && px > 0) applyLeftWidth(px);
    }

    // ── Collapse ──────────────────────────────────────────────────────────

    var collapseState = { collapsed: false, width: 0, restoreWidth: 0 };

    function applyCollapse() {
        shell.setAttribute('data-wb-collapsed', collapseState.collapsed ? 'edit' : '');
        if (collapseBtn) {
            collapseBtn.setAttribute('aria-expanded', collapseState.collapsed ? 'false' : 'true');
            collapseBtn.textContent = collapseState.collapsed ? 'Show editor' : 'Hide editor';
        }
        if (collapseState.collapsed) {
            shell.style.setProperty('--wb-left-width', '0px');
            if (splitter) splitter.setAttribute('aria-valuenow', '0');
        } else {
            applyLeftWidth(collapseState.restoreWidth || EDIT_MIN);
        }
    }

    function doToggleCollapse() {
        collapseState.width = collapseState.collapsed ? collapseState.width : currentLeftWidth();
        collapseState = toggleCollapse(collapseState);
        applyCollapse();
        if (!collapseState.collapsed) persist(currentLeftWidth());
    }

    var collapseBtn = document.getElementById('wb-collapse-edit');
    if (collapseBtn) collapseBtn.addEventListener('click', doToggleCollapse);

    if (splitter && body) {
        var dragging = false;

        splitter.addEventListener('pointerdown', function (e) {
            dragging = true;
            try { splitter.setPointerCapture(e.pointerId); } catch (_) { /* not supported */ }
            e.preventDefault();
        });

        splitter.addEventListener('pointermove', function (e) {
            if (!dragging) return;
            applyLeftWidth(e.clientX - body.getBoundingClientRect().left);
        });

        function endDrag() {
            if (!dragging) return;
            dragging = false;
            persist(currentLeftWidth());
        }
        splitter.addEventListener('pointerup', endDrag);
        splitter.addEventListener('pointercancel', endDrag);

        // Keyboard: the splitter is a real control, not a mouse-only affordance.
        splitter.addEventListener('keydown', function (e) {
            var width = currentLeftWidth();
            var total = body.clientWidth;
            if (e.key === 'Enter' || e.key === ' ') {
                e.preventDefault();
                doToggleCollapse();
                return;
            }
            var next = null;
            if (e.key === 'ArrowLeft') next = width - KEY_STEP_PX;
            else if (e.key === 'ArrowRight') next = width + KEY_STEP_PX;
            else if (e.key === 'Home') next = EDIT_MIN;
            else if (e.key === 'End') next = total - SPLITTER_PX - NOTEBOOK_MIN;
            if (next === null) return;
            e.preventDefault();
            // Any explicit sizing means the pane is no longer collapsed.
            collapseState.collapsed = false;
            shell.setAttribute('data-wb-collapsed', '');
            persist(applyLeftWidth(next));
        });

        // A window resize can invalidate a stored width — re-clamp against the
        // new viewport rather than leaving a pane under its floor.
        window.addEventListener('resize', function () {
            applyLeftWidth(currentLeftWidth());
        });

        restore();
    }

    // ── Notebook tabs ─────────────────────────────────────────────────────

    function mount(pane) {
        var frame = panes[pane];
        if (!frame) return;
        var wanted = frame.getAttribute('data-wb-src');
        if (wanted && frame.getAttribute('src') !== wanted) frame.setAttribute('src', wanted);
    }

    function unmount(pane) {
        var frame = panes[pane];
        if (frame) frame.setAttribute('src', 'about:blank');
    }

    function selectPane(name) {
        if (!panes[name]) return;
        var previous = activePane;
        activePane = name;

        tabs.forEach(function (tab) {
            var isActive = tab.getAttribute('data-wb-pane') === name;
            tab.setAttribute('aria-selected', isActive ? 'true' : 'false');
            // Roving tabindex: one stop for the whole strip.
            tab.setAttribute('tabindex', isActive ? '0' : '-1');
        });
        Object.keys(panes).forEach(function (key) {
            if (panes[key]) panes[key].hidden = (key !== name);
        });

        mount(name);
        // Reclaim the hidden pane's kernel only where memory is tight; the
        // default is to keep it warm so the next switch costs nothing.
        if (previous !== name && !allowsTwoKernels(navigator)) unmount(previous);

        // Whatever made the chip appear applied to the notebook the author was
        // looking at; a fresh mount is current by construction.
        if (staleChip) staleChip.hidden = true;
    }

    tabs.forEach(function (tab, index) {
        tab.addEventListener('click', function () {
            selectPane(tab.getAttribute('data-wb-pane'));
        });
        tab.addEventListener('keydown', function (e) {
            var delta = e.key === 'ArrowRight' ? 1 : (e.key === 'ArrowLeft' ? -1 : 0);
            if (!delta) return;
            e.preventDefault();
            var next = tabs[(index + delta + tabs.length) % tabs.length];
            next.focus();
            selectPane(next.getAttribute('data-wb-pane'));
        });
    });

    // ── Single-pane fallback (narrow desktop windows) ──────────────────────

    function syncSinglePane() {
        var single = window.innerWidth <= SINGLE_PANE_MAX;
        if (singleEditBtn) singleEditBtn.hidden = !single;
        if (!single) shell.setAttribute('data-wb-single', 'notebook');
    }
    if (singleEditBtn) {
        singleEditBtn.addEventListener('click', function () {
            var showingEdit = shell.getAttribute('data-wb-single') === 'edit';
            shell.setAttribute('data-wb-single', showingEdit ? 'notebook' : 'edit');
            singleEditBtn.textContent = showingEdit ? 'Editor' : 'Notebook';
        });
    }
    window.addEventListener('resize', syncSinglePane);
    syncSinglePane();

    // ── Pane messaging ────────────────────────────────────────────────────

    window.addEventListener('message', function (event) {
        // Same-origin only.  These messages move session-liveness and reload
        // signals; a framed third party must not be able to forge them.
        if (event.origin !== window.location.origin) return;
        var data = event.data;
        if (!data || data.source !== 'chickadee') return;

        if (data.type === 'activity') {
            // Re-raise for idle-logout.js, which is listening on this window.
            try { window.dispatchEvent(new CustomEvent('chickadee:activity')); } catch (_) { /* ignore */ }
            return;
        }

        if (data.type === 'notebook-saved') {
            // The save changed the assignment's files and validation status,
            // both of which the left pane renders.  Reloading it is safe — it
            // holds no kernel and no unsaved state that is not already POSTed.
            if (editFrame) editFrame.contentWindow.location.reload();
            return;
        }

        if (data.type === 'inputs-changed') {
            // Personalization changed, so what the notebook is showing is now a
            // rendering of stale values.  Deliberately advisory: reloading the
            // pane restarts the kernel and drops the author's live state, so
            // the author decides when to pay that.
            if (staleChip) {
                staleChip.textContent = 'Inputs changed — reload the notebook to see new values';
                staleChip.hidden = false;
            }
        }
    });
}());
