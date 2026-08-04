// Public/workbench.js
//
// The assignment workbench shell: the instructor edit page in a left pane, the
// notebook editor in a right pane, a draggable splitter between them, and a tab
// strip that switches the right pane between the starter notebook and the
// reference solution.
//
// The shell owns no assignment content — each pane is an iframe onto a page
// that already existed.  What lives here is the composition: pane sizing, which
// notebook is loaded, and the messages the panes send each other.
//
// Three things are load-bearing and easy to get wrong:
//
//   * **Pane floors.** The notebook page hides its own editor below 640px and
//     shows "open on a larger screen".  A too-narrow notebook pane would
//     therefore render that notice instead of the editor — so the splitter
//     clamps the notebook pane at 720px and the edit pane at 380px, and below a
//     viewport that can hold both the layout drops to one pane at a time.
//
//   * **One notebook document, always.** The Files table and the view switch
//     change the single iframe's src; they are destinations, not panes. An
//     iframe per
//     (file, view) would mean a Pyodide kernel per combination — up to four —
//     and bounding that needs an eviction policy, which is a lot of machinery
//     for a secondary interaction. The workbench exists to put the edit page
//     and *a* notebook on screen together, and that holds with one. The cost is
//     honest and accepted: switching notebooks re-boots the kernel.
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

    /// The only URL shape this shell is ever allowed to point a notebook frame
    /// at: a same-origin absolute path to the embedded notebook page.
    ///
    /// The destinations arrive as DOM text (a data-attribute the server
    /// rendered), and the sink is an iframe `src` — a `javascript:` URL there
    /// is script execution in this page's origin. Today the server builds that
    /// map from its own `setup_…` identifiers so nothing hostile can reach it,
    /// but nothing in *this* file enforced that, and the distance between "is
    /// not attacker-controlled" and "cannot be" is the whole bug class.
    /// Anchored at both ends, scheme-relative `//host` excluded by the second
    /// character check.
    var SAFE_PANE_URL = /^\/testsetups\/[A-Za-z0-9_.-]+\/notebook\?[A-Za-z0-9_=&%.-]*$/;

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
    var editFrame = document.getElementById('wb-edit-frame');
    var staleChip = document.getElementById('wb-stale-chip');
    var singleEditBtn = document.getElementById('wb-single-edit');
    var assignmentID = shell.getAttribute('data-assignment-id') || '';
    var storageKey = 'chickadee-workbench-split:' + assignmentID;

    // Which notebook is open is a label here, not a control: the choosing
    // happens in the left pane's Files table, which already lists the files.
    var openFileLabel = document.getElementById('wb-openfile');
    var viewButtons = Array.prototype.slice.call(shell.querySelectorAll('.wb-view'));
    var viewSwitch = document.getElementById('wb-viewswitch');

    // The single notebook document, and every destination it can be sent to.
    // There is one iframe, so there is one kernel — switching notebooks costs a
    // boot, and nothing here has to manage a pool.
    var notebookFrame = document.getElementById('wb-notebook');
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

    function selectPane(file, view) {
        var pane = resolvePane(paneURLs, file, view);
        if (!pane || !notebookFrame) return;
        activeFile = pane.file;
        activeView = pane.view;

        if (openFileLabel) {
            openFileLabel.textContent = pane.file === 'solution' ? 'Solution' : 'Assignment';
        }
        viewButtons.forEach(function (btn) {
            btn.setAttribute(
                'aria-pressed',
                btn.getAttribute('data-wb-view') === pane.view ? 'true' : 'false');
        });
        // The control only makes sense where the two readings differ.
        if (viewSwitch) viewSwitch.hidden = !hasTemplate(pane.file);

        notebookFrame.setAttribute('data-wb-file', pane.file);
        notebookFrame.setAttribute('data-wb-view', pane.view);
        // Re-validated at the sink rather than trusting that resolvePane already
        // did it: this is the line where a `javascript:` URL would become script
        // execution in this origin, so the check belongs where the damage would
        // happen, not one call up.
        //
        // Also guarded on inequality: re-setting src to the value it already
        // holds is a reload in some browsers, which would throw away a kernel
        // that is already booting just because the author clicked the tab they
        // are already on.
        var nextURL = safePaneURL(pane.url);
        if (nextURL && notebookFrame.getAttribute('src') !== nextURL) {
            notebookFrame.setAttribute('src', nextURL);
        }

        // Whatever made the chip appear applied to the notebook the author was
        // looking at; a fresh load is current by construction.
        if (staleChip) staleChip.hidden = true;
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
            return;
        }

        if (data.type === 'open-notebook') {
            // The left pane's Files table is the only place that chooses which
            // notebook is open.  `data.file` selects a destination from a
            // server-rendered table, never a URL, so an unrecognised value
            // resolves to nothing rather than navigating anywhere.
            selectPane(data.file === 'solution' ? 'solution' : 'assignment', activeView);
            return;
        }

        if (data.type === 'save-result') {
            pendingSaves -= 1;
            if (!data.ok) saveFailed = true;
            if (pendingSaves <= 0) finishSave();
        }
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
    var pendingSaves = 0;
    var saveFailed = false;

    function finishSave() {
        pendingSaves = 0;
        if (saveBtn) saveBtn.disabled = false;
        if (saveStatus) {
            saveStatus.textContent = saveFailed ? 'Save failed — see the pane for details' : 'Saved';
        }
    }

    if (saveBtn) {
        saveBtn.addEventListener('click', function () {
            saveFailed = false;
            saveBtn.disabled = true;
            if (saveStatus) saveStatus.textContent = 'Saving…';
            // Both panes are asked, and each replies. A pane with nothing to
            // save still replies, so the button always comes back — silence
            // would leave it disabled forever.
            pendingSaves = 0;
            [notebookFrame, editFrame].forEach(function (frame) {
                if (!frame || !frame.contentWindow) return;
                pendingSaves += 1;
                try {
                    frame.contentWindow.postMessage(
                        { source: 'chickadee', type: 'save' }, window.location.origin);
                } catch (_) {
                    pendingSaves -= 1;
                    saveFailed = true;
                }
            });
            if (pendingSaves <= 0) finishSave();
        });
    }
}());
