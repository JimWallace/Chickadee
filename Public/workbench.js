// Public/workbench.js
//
// The assignment workbench (#1266, notebook views NB6): a full-width notebook
// with the test suite in a rail on its left (workbench-rail.js), an app bar
// above, and the assignment's settings in sheets that slide over the notebook.
//
// **One document.** `WorkbenchPage` renders the notebook (`NotebookBody`) and
// the settings (`AssignmentEditBody`, in the sheet) inline, so this file owns
// layout and coordination, not composition.
//
// Two things are load-bearing and easy to get wrong:
//
//   * **One notebook open, always.** Each (file, view) is a separate notebook
//     with its own kernel, so switching costs a kernel boot.
//
//   * **Nothing here navigates.** The settings forms and a live kernel share
//     this document, so a navigation (or a `location.reload()`) costs a 10-30s
//     kernel boot and any unsaved cells. Writes go through `inplace-forms.js`
//     and refresh the sheet by DOM swap (`refreshEditSurface`); switching
//     notebooks swaps the notebook (`refreshNotebookSurface`) and moves the
//     URL with `pushState`.

(function () {
    'use strict';

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

    // Exported for the unit tests, which exercise the policy without a DOM.
    var api = {
        resolvePane: resolvePane
    };
    if (typeof window !== 'undefined') window.ChickadeeWorkbench = api;
    if (typeof module !== 'undefined' && module.exports) module.exports = api;

    if (typeof document === 'undefined') return;
    var shell = document.getElementById('wb-shell');
    if (!shell) return;

    var staleChip = document.getElementById('wb-stale-chip');
    var viewButtons = Array.prototype.slice.call(shell.querySelectorAll('.wb-view'));

    // Every destination the notebook can be switched to.  There is one
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

    // Seeded from what the server actually rendered, not assumed: the page is
    // reachable at `?file=solution&view=template`, and starting from the
    // defaults would make the first switch compare against the wrong state and
    // silently no-op.
    var notebookBody = document.querySelector('.wb-notebook-body');
    var activeFile = (notebookBody && notebookBody.getAttribute('data-wb-file') === 'solution')
        ? 'solution' : 'assignment';
    var activeView = (notebookBody && notebookBody.getAttribute('data-wb-view') === 'template')
        ? 'template' : 'personalized';

    // ── Notebook selection: which file, and which reading of it ────────────

    /// Switch which notebook is open.
    ///
    /// Swaps the notebook in place; the sheet is not touched. The kernel
    /// restarts either way, because it belongs to the open notebook, but the
    /// sheet's scroll position, open editors and unsaved settings survive,
    /// where a navigation took them along.
    ///
    /// The URL still changes, via `pushState`, so the address bar names what is
    /// actually open, a reload lands in the same place, and Back returns to the
    /// previous notebook.
    function selectPane(file, view) {
        var pane = resolvePane(paneURLs, file, view);
        if (!pane) return;
        // Already here — a click on the reading you are already looking at
        // must not cost a kernel boot.
        if (pane.file === activeFile && pane.view === activeView) return;
        // Re-validated at the sink rather than trusting that resolvePane
        // already did it: this is where a `javascript:` URL would reach a
        // navigation, so the check belongs where the damage would happen.
        var nextURL = safePaneURL(pane.url);
        if (!nextURL) return;

        activeFile = pane.file;
        activeView = pane.view;
        if (staleChip) staleChip.hidden = true;

        ChickadeeSurfaceSwap.refreshNotebookSurface(nextURL).then(function (ok) {
            if (!ok) return;  // swapHalf already reloaded
            try {
                window.history.pushState({ file: pane.file, view: pane.view }, '', nextURL);
            } catch (_) { /* history unavailable — the pane is still correct */ }
            syncViewControls();
        });
    }

    /// Point the view switch at whatever is open now. Its markup is in the
    /// app bar, not in the swapped notebook, so it does not come back from
    /// the server with the notebook.
    function syncViewControls() {
        viewButtons.forEach(function (btn) {
            btn.setAttribute(
                'aria-pressed',
                btn.getAttribute('data-wb-target-file') === activeFile ? 'true' : 'false');
        });
    }

    // Back/forward must move between notebooks, not leave the page half-swapped
    // showing one file under the other's URL.
    window.addEventListener('popstate', function (e) {
        var st = e.state;
        if (!st || !st.file) { window.location.reload(); return; }
        var pane = resolvePane(paneURLs, st.file, st.view);
        var url = pane && safePaneURL(pane.url);
        if (!url) { window.location.reload(); return; }
        activeFile = st.file;
        activeView = st.view;
        ChickadeeSurfaceSwap.refreshNotebookSurface(url).then(syncViewControls);
    });

    // Solution · Starter: each opens its notebook as written, placeholders
    // and all (the template view, where the notebook has one).
    viewButtons.forEach(function (btn) {
        btn.addEventListener('click', function () {
            selectPane(btn.getAttribute('data-wb-target-file') === 'solution' ? 'solution' : 'assignment', 'template');
        });
    });

    // ── Sheets ────────────────────────────────────────────────────────────
    //
    // The settings (`AssignmentEditBody`, unchanged) sit in one panel that
    // slides over the notebook. `data-wb-sheet` names the block it shows. Focus
    // moves into the panel when it opens and back to the opener when it closes.

    var SHEET_TITLES = {
        details: 'Details', files: 'Files', inputs: 'Inputs', options: 'Student options',
        activity: 'Activity', achievements: 'Achievements', suite: 'Test suite'
    };
    var sheetOpener = null;

    function sheetPanel() { return document.getElementById('wb-sheet'); }

    function openSheet(name, opener) {
        var sheet = sheetPanel();
        if (!sheet || !SHEET_TITLES[name]) return;
        sheet.setAttribute('data-wb-sheet', name);
        sheet.setAttribute('aria-label', SHEET_TITLES[name]);
        sheet.hidden = false;
        sheetOpener = opener || null;
        // The Details block keeps its fields behind its own pencil.
        if (name === 'details') {
            var fields = document.getElementById('assign-header-edit');
            var toggle = document.getElementById('assign-edit-toggle');
            if (fields && toggle && fields.style.display === 'none') toggle.click();
        }
        var close = document.getElementById('wb-sheet-close');
        if (close) close.focus();
    }

    function closeSheet() {
        var sheet = sheetPanel();
        if (!sheet || sheet.hidden) return;
        sheet.hidden = true;
        if (sheetOpener && document.contains(sheetOpener)) sheetOpener.focus();
        sheetOpener = null;
    }

    // ── The rail under 1300px ─────────────────────────────────────────────

    var railToggle = document.getElementById('wb-rail-toggle');

    function setRailOpen(open) {
        shell.toggleAttribute('data-rail-open', open);
        if (railToggle) railToggle.setAttribute('aria-expanded', open ? 'true' : 'false');
    }

    if (railToggle) {
        railToggle.addEventListener('click', function () {
            setRailOpen(!shell.hasAttribute('data-rail-open'));
        });
    }

    // Delegated, because a save swaps the sheet's content.
    document.addEventListener('click', function (e) {
        var target = e.target;
        if (!target || !target.closest) return;
        var opener = target.closest('[data-wb-open-sheet]');
        if (opener) {
            e.preventDefault();
            setRailOpen(false);
            openSheet(opener.getAttribute('data-wb-open-sheet'), opener);
            return;
        }
        if (target.closest('#wb-sheet-close')) {
            closeSheet();
            return;
        }
        // An item in the overlaid rail moves the notebook; the overlay goes.
        if (target.closest('#wb-rail .outline-row')) setRailOpen(false);
    });

    document.addEventListener('keydown', function (e) {
        if (e.key !== 'Escape' || e.defaultPrevented) return;
        // A dialog over the sheet (the test editor) closes first.
        if (document.querySelector('dialog[open]')) return;
        if (shell.hasAttribute('data-rail-open')) {
            setRailOpen(false);
            if (railToggle) railToggle.focus();
            return;
        }
        closeSheet();
    });

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
                staleChip.textContent = 'Notebook out of date';
                staleChip.title = 'The inputs changed. Reopen the notebook to see the new values.';
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
                // A save re-validates: the rail's results change.
                if (window.ChickadeeWorkbenchRail) void window.ChickadeeWorkbenchRail.refresh();
            });
        });
    }

    // ── Unsaved-work guard ────────────────────────────────────────────────
    //
    // Switching notebooks no longer navigates, so this is no longer about the
    // switch — it is the ordinary case of closing the tab, following a link, or
    // hitting reload with metadata typed into the edit half and not yet saved.
    // Track dirtiness from the form's own input events and let the browser ask.

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
