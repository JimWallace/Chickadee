// Public/workbench.js
//
// The assignment workbench: the instructor edit page on the left, the notebook
// editor on the right, a draggable splitter between them.
//
// **One document** since #1266.  Both halves are rendered inline by
// `workbench.leaf` (`_assignment-edit-body` and `_notebook-body`, each bound to
// its own sub-context), so this file owns layout and coordination, not
// composition.  The cross-frame protocol it used to carry — postMessage, origin
// checks, an activity forwarder — is gone with the frames.
//
// Three things are load-bearing and easy to get wrong:
//
//   * **Pane floors.** The notebook body hides its own editor below 640px and
//     shows "open on a larger screen".  A too-narrow notebook pane would
//     therefore render that notice instead of the editor — so the splitter
//     clamps the notebook pane at 720px and the edit pane at 380px, and below a
//     viewport that can hold both the layout drops to one pane at a time.
//
//   * **One notebook open, always.** Four (file, view) combinations exist, and
//     a live document per combination would mean a Pyodide kernel per
//     combination; bounding that needs an eviction policy, a lot of machinery
//     for a secondary interaction.  So switching costs a kernel boot — and
//     since it does, switching is an ordinary navigation to this same route
//     with different arguments rather than an in-place swap.
//
//   * **Nothing here may navigate casually.** The edit form and a live kernel
//     share this document.  Every write goes through `inplace-forms.js` and the
//     refresh is a DOM swap of the edit half only (`refreshEditSurface`), never
//     a reload — a reload costs a 10-30s kernel boot and any unsaved cells,
//     which is the failure this page was merged to prevent.  The one deliberate
//     navigation, switching notebooks, is guarded by `beforeunload` when the
//     form is dirty.

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

    /// The only URL shape this page is ever allowed to send itself to: a
    /// same-origin absolute path to this same workbench route.
    ///
    /// **Kept, not dropped, after the #1266 merge.** The sink moved rather than
    /// disappearing — it used to be an iframe `src`, it is now
    /// `location.assign`, and a `javascript:` URL is script execution in this
    /// origin either way. The destinations still arrive as DOM text (a
    /// data-attribute the server rendered), which is exactly the CodeQL
    /// DOM-text-as-sink shape this guard was added for. Today the server builds
    /// that map from its own identifiers so nothing hostile can reach it, but
    /// nothing in *this* file enforces that, and the distance between "is not
    /// attacker-controlled" and "cannot be" is the whole bug class.
    /// Anchored at both ends, scheme-relative `//host` excluded by the second
    /// character check.
    var SAFE_PANE_URL = /^\/instructor\/[A-Za-z0-9_.-]+\/workbench\?[A-Za-z0-9_=&%.-]*$/;

    function safePaneURL(url) {
        return (typeof url === 'string' && SAFE_PANE_URL.test(url)) ? url : null;
    }

    /// Resolve which notebook URL a (file, view) selection should load.
    ///
    /// Falls back to the rendered view when the requested reading does not
    /// exist for that file — the server only publishes a `template` entry for a
    /// notebook that actually carries placeholders, so switching to Solution
    /// while viewing the Assignment's template lands exactly there. Returning
    /// the fallback (rather than nothing) is what keeps a tab click from being
    /// silently ignored.
    ///
    /// Pure, so the fallback is testable without a DOM.
    /// A destination that does not match `SAFE_PANE_URL` is treated as absent,
    /// not as a pane with a bad URL — so a malformed entry falls through to the
    /// rendered view or to nothing, and never reaches an iframe.
    function resolvePane(urls, file, view) {
        var exact = safePaneURL(urls[file + ':' + view]);
        if (exact) return { key: file + ':' + view, file: file, view: view, url: exact };
        var fallback = safePaneURL(urls[file + ':personalized']);
        if (fallback) {
            return { key: file + ':personalized', file: file, view: 'personalized', url: fallback };
        }
        return null;
    }

    // Exported for the unit tests, which exercise the arithmetic and the
    // policy without a DOM.
    var api = {
        clampLeftWidth: clampLeftWidth,
        resolvePane: resolvePane
    };
    if (typeof window !== 'undefined') window.ChickadeeWorkbench = api;
    if (typeof module !== 'undefined' && module.exports) module.exports = api;

    if (typeof document === 'undefined') return;
    var shell = document.getElementById('wb-shell');
    if (!shell) return;

    var body = shell.querySelector('.wb-body');
    var splitter = document.getElementById('wb-splitter');
    var staleChip = document.getElementById('wb-stale-chip');
    var singleEditBtn = document.getElementById('wb-single-edit');
    var assignmentID = shell.getAttribute('data-assignment-id') || '';
    var storageKey = 'chickadee-workbench-split:' + assignmentID;

    var viewButtons = Array.prototype.slice.call(shell.querySelectorAll('.wb-view'));
    var viewSwitch = document.getElementById('wb-viewswitch');

    // Every destination the notebook half can be sent to.  There is one
    // notebook open at a time, so there is one kernel — switching costs a boot,
    // and nothing here has to manage a pool.
    // Carried on a data-attribute rather than a <script> island: it is a small
    // map the shell reads once, and the style guard ratchets inline script
    // down, not up.
    var paneURLs = {};
    try {
        paneURLs = JSON.parse(shell.getAttribute('data-wb-pane-urls') || '{}');
    } catch (_) {
        paneURLs = {};
    }

    var activeFile = 'assignment';
    var activeView = 'personalized';

    function hasTemplate(file) {
        if (!viewSwitch) return false;
        return viewSwitch.getAttribute('data-' + file + '-has-template') === '1';
    }

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
            var next = null;
            if (e.key === 'ArrowLeft') next = width - KEY_STEP_PX;
            else if (e.key === 'ArrowRight') next = width + KEY_STEP_PX;
            else if (e.key === 'Home') next = EDIT_MIN;
            else if (e.key === 'End') next = total - SPLITTER_PX - NOTEBOOK_MIN;
            if (next === null) return;
            e.preventDefault();
            persist(applyLeftWidth(next));
        });

        // A window resize can invalidate a stored width — re-clamp against the
        // new viewport rather than leaving a pane under its floor.
        window.addEventListener('resize', function () {
            applyLeftWidth(currentLeftWidth());
        });

        restore();
    }

    // ── Notebook selection: which file, and which reading of it ────────────

    /// Switch which notebook the right half holds.
    ///
    /// A **full navigation**, deliberately. Before the merge this repointed an
    /// iframe; in one document there is no inner frame to repoint, and either
    /// way the Pyodide kernel restarts — it is bound to the notebook that is
    /// open. Since the cost is unavoidable, the honest form is an ordinary
    /// navigation to this route with different arguments, which also brings the
    /// edit half back consistent with what the notebook now shows.
    ///
    /// Guarded by `beforeunload` when the edit form is dirty (see below), so
    /// unsaved metadata is not silently lost on the way out.
    function selectPane(file, view) {
        var pane = resolvePane(paneURLs, file, view);
        if (!pane) return;
        // Already here — a click on the reading you are already looking at
        // must not cost a kernel boot.
        if (pane.file === activeFile && pane.view === activeView) return;
        // Re-validated at the sink rather than trusting that resolvePane
        // already did it: this is the line where a `javascript:` URL would
        // become script execution in this origin, so the check belongs where
        // the damage would happen, not one call up.
        var nextURL = safePaneURL(pane.url);
        if (nextURL) window.location.assign(nextURL);
    }

    viewButtons.forEach(function (btn) {
        btn.addEventListener('click', function () {
            selectPane(activeFile, btn.getAttribute('data-wb-view'));
        });
    });

    // The template already loaded the assignment's rendered view, so only the
    // view control needs syncing — show it when this notebook has a template
    // worth switching to.
    if (viewSwitch) viewSwitch.hidden = !hasTemplate(activeFile);

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

    // ── Cross-half notes ──────────────────────────────────────────────────
    //
    // Was a `message` listener with an origin check, back when the halves were
    // separate documents.  One document means one event bus: `notifyWorkbench`
    // in chickadee-ui.js dispatches `chickadee:workbench` here directly, and
    // there is no boundary left for a third party to forge across.
    //
    // Idle-logout needs nothing now either — the watchdog and the keystrokes
    // are in the same document, so `idle-logout.js` sees them without a
    // forwarder.

    window.addEventListener('chickadee:workbench', function (event) {
        var type = event && event.detail && event.detail.type;

        if (type === 'inputs-changed') {
            // Personalization changed, so what the notebook is showing is now a
            // rendering of stale values.  Deliberately advisory: re-rendering
            // restarts the kernel and drops the author's live state, so the
            // author decides when to pay that.
            if (staleChip) {
                staleChip.textContent = 'Inputs changed — reload the notebook to see new values';
                staleChip.hidden = false;
            }
            return;
        }

        if (type === 'notebook-saved') {
            // The save changed the assignment's files and validation status,
            // both of which the edit half renders.  Refresh that half in place
            // — a page reload here would take the kernel with it.
            if (typeof window.chickadeeRefreshEditSurface === 'function') {
                window.chickadeeRefreshEditSurface();
            }
        }
    });

    // The Files table's Edit buttons choose which notebook is open.  They are
    // ordinary links to the workbench URL, so they work with no JS at all; this
    // only routes them through `selectPane` for the dirty-form guard.
    document.addEventListener('click', function (e) {
        var el = e.target.closest && e.target.closest('[data-wb-file]');
        if (!el || !el.getAttribute('data-wb-file')) return;
        e.preventDefault();
        selectPane(el.getAttribute('data-wb-file') === 'solution' ? 'solution' : 'assignment', activeView);
    });

    // ── Save ──────────────────────────────────────────────────────────────
    //
    // One button for what used to be two: it saves the notebook that is open
    // and the assignment's details, then re-validates.
    //
    // It deliberately does NOT close the assignment.  The workbench is a
    // live-edit surface — `PUT /suite`, `PUT /families` and
    // `POST /notebook/save` all write without touching visibility — and
    // closing on save would mean fixing a typo pulls a lab out from under the
    // students sitting in it.  The standalone `/edit` page keeps
    // close-on-save; the difference rides on the `liveEdit` field only the
    // embedded form sends.

    var saveBtn = document.getElementById('wb-save');
    var saveStatus = document.getElementById('wb-save-status');

    /// Save the open notebook, if there is one to save.
    ///
    /// `chickadeeSaveToAssignment` is the POST to /notebook/save. Deliberately
    /// NOT `chickadeeSaveNotebook`, which despite the name only flushes cells
    /// to JupyterLite's local storage and would report a save that never
    /// reached the server. Absent (no notebook on this assignment yet) counts
    /// as success — nothing to save is not a failure.
    function saveNotebookHalf() {
        if (typeof window.chickadeeSaveToAssignment !== 'function') {
            return Promise.resolve(true);
        }
        return Promise.resolve()
            .then(function () { return window.chickadeeSaveToAssignment(); })
            .then(function (ok) { return ok !== false; })
            .catch(function () { return false; });
    }

    /// Save the edit half's form through the same in-place path a click on its
    /// own submit button takes, so the two cannot diverge.
    ///
    /// Waits for the real outcome. An earlier version replied optimistically
    /// and then submitted natively — because the pane was about to navigate
    /// away and a later reply would never arrive — which reported success on a
    /// 500. Nothing navigates now, so the honest answer is available.
    function saveEditHalf() {
        var form = document.querySelector('form[action$="/edit/save"]');
        if (!form) return Promise.resolve(true);
        if (typeof window.chickadeeSubmitInPlace !== 'function') return Promise.resolve(false);
        return window.chickadeeSubmitInPlace(form).then(function (ok) { return ok !== false; });
    }

    if (saveBtn) {
        saveBtn.addEventListener('click', function () {
            saveBtn.disabled = true;
            if (saveStatus) saveStatus.textContent = 'Saving…';
            // Both halves are saved concurrently and both outcomes are waited
            // for, so the button always comes back and a failure in either is
            // reported rather than swallowed.
            Promise.all([saveNotebookHalf(), saveEditHalf()]).then(function (results) {
                var ok = results[0] !== false && results[1] !== false;
                saveBtn.disabled = false;
                if (saveStatus) {
                    saveStatus.textContent = ok ? 'Saved' : 'Save failed — see the form for details';
                }
                if (ok) formDirty = false;
            });
        });
    }

    // ── Unsaved-work guard ────────────────────────────────────────────────
    //
    // Switching notebooks is a navigation now, so metadata typed into the edit
    // half and not yet saved would leave with the page. Track dirtiness from
    // the form's own input events and let the browser ask.

    var formDirty = false;
    document.addEventListener('input', function (e) {
        if (e.target && e.target.closest && e.target.closest('form[action$="/edit/save"]')) {
            formDirty = true;
        }
    });
    window.addEventListener('beforeunload', function (e) {
        if (!formDirty) return;
        e.preventDefault();
        // Modern browsers show their own wording; returnValue is the legacy
        // opt-in that still gates the prompt in some of them.
        e.returnValue = '';
    });
}());
