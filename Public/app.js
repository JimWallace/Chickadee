// CSRF tokens: use ChickadeeUI.getCsrfToken() (Public/chickadee-ui.js,
// loaded from base.leaf's <head>, so it is available everywhere).  The old
// bare-global alias that lived here was retired in the 0.5 cleanup once the
// last callers moved to the namespaced form.

// Drag-drop zone on the submission form
const dropZone   = document.getElementById('drop-zone');
const fileInput  = document.getElementById('file-input');
const fileNameEl = document.getElementById('drop-filename');

if (dropZone && fileInput) {
    dropZone.addEventListener('click', () => fileInput.click());
    dropZone.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' || e.key === ' ') {
            e.preventDefault();
            fileInput.click();
        }
    });

    dropZone.addEventListener('dragover', e => {
        e.preventDefault();
        dropZone.classList.add('drag-over');
    });

    dropZone.addEventListener('dragleave', () => {
        dropZone.classList.remove('drag-over');
    });

    dropZone.addEventListener('drop', e => {
        e.preventDefault();
        dropZone.classList.remove('drag-over');
        const file = e.dataTransfer.files[0];
        if (file) {
            const dt = new DataTransfer();
            dt.items.add(file);
            fileInput.files = dt.files;
            fileNameEl.textContent = file.name;
        }
    });

    fileInput.addEventListener('change', () => {
        fileNameEl.textContent = fileInput.files[0]?.name ?? '';
    });
}

// ── Site-wide credential-autofill suppression ──────────────────────────────
// Browsers heuristically offer username/password autofill on any text field —
// e.g. an admin filter named "actor" with placeholder "username" — which is
// noise on the many non-credential forms across the app. HTML has no global
// "default off" switch, so set autocomplete="off" at the form level for every
// form that hasn't opted in. Real credential forms (login, register, the admin
// worker-secret field) opt their inputs into autocomplete explicitly; an
// input-level autocomplete overrides this form-level default per the HTML spec,
// so they keep working. We also skip any form that already carries a password
// field or an annotated control, out of caution.
(function suppressSpuriousAutofill() {
    const forms = document.querySelectorAll('form:not([autocomplete])');
    forms.forEach((form) => {
        if (form.querySelector('input[type="password"], [autocomplete]')) return;
        form.setAttribute('autocomplete', 'off');
    });
})();

// Results page: poll until the submission reaches its final state.
//
// Statuses that require polling:
//   pending / assigned  — runner hasn't started yet
const root = document.getElementById('submission-root');
if (root) {
    const isPending = root.dataset.pending === 'true';

    if (isPending) {
        const submissionID = root.dataset.submissionId;
        const poll = setInterval(async () => {
            try {
                const res = await fetch(`/api/v1/submissions/${submissionID}`);
                if (!res.ok) return;
                const data = await res.json();
                const done = data.status !== 'pending' && data.status !== 'assigned';
                if (done) {
                    clearInterval(poll);
                    window.location.reload();
                }
            } catch (_) {
                // network blip — try again next tick
            }
        }, 2000);
    }
}

// ── Destructive-action confirmation ────────────────────────────────────────
// One seam for "are you sure?" (UI audit S5). A form or control declares the
// question in markup:
//
//   <form … data-confirm="Delete this assignment? Students will lose access.">
//   <button … data-confirm="Revoke this agent? It loses access immediately.">
//
// It replaces 49 hand-written inline handlers (an onclick or onsubmit whose
// body called the native dialog directly). Those were not just repetitive:
// the same action carried different wording on different pages, and the two
// pages that rebuilt rows in JS carried a *second* copy of each message that
// could drift from the first.
//
// It is also the seam any improvement lands in, which is how the styled dialog
// arrived: swapping the native one was a change to this function, not to 49
// call sites. (Requiring a typed course code before a destructive delete would
// be the same.)
//
// (The guard in check-styles.sh greps for the native call, and cannot tell
// markup from prose about markup — so this comment describes the old idiom
// rather than quoting it. Same lesson as the Leaf-comment finding in #1266.)
//
// Clicks are handled in the CAPTURE phase so a cancelled action also stops the
// handlers layered around it (row-click navigation, popover toggles) rather
// than merely stopping the default. Submits are handled in the bubble phase,
// which runs before inplace-forms.js's own submit listener (app.js loads
// first) — and that one bails on `defaultPrevented`, so a cancelled submit
// stays cancelled.
//
// The dialog behind this seam is a real one now (ChickadeeUI.confirmAction),
// so the answer arrives in a promise rather than blocking the event loop. A
// listener cannot wait for that, so the shape is: always cancel the action,
// ask, and REPLAY it if the answer was yes. The replay re-dispatches the
// original interaction — a click on the element, or requestSubmit() on the
// form with its original submitter — so everything layered around it (row-click
// navigation, inplace-forms.js's own submit listener, formaction) sees exactly
// what it saw before, and the marker below keeps the replay from asking again.
(function confirmActions() {
    const replaying = new WeakSet();

    function replayClick(el) {
        replaying.add(el);
        try { el.click(); } finally { replaying.delete(el); }
    }

    function replaySubmit(form, submitter) {
        replaying.add(form);
        try {
            // requestSubmit() fires the submit event (submit() deliberately
            // does not), which is what inplace-forms.js listens for.
            if (form.requestSubmit) form.requestSubmit(submitter || undefined);
            else form.submit();
        } finally {
            replaying.delete(form);
        }
    }

    document.addEventListener('click', (e) => {
        const el = e.target instanceof Element ? e.target.closest('[data-confirm]') : null;
        // A <form data-confirm> asks on submit, not on every click inside it.
        if (!el || el.tagName === 'FORM') return;
        if (replaying.has(el)) return;
        const message = el.getAttribute('data-confirm');
        if (!message) return;
        e.preventDefault();
        e.stopPropagation();
        window.ChickadeeUI.confirmAction(message, el).then((ok) => {
            if (ok) replayClick(el);
        });
    }, true);

    document.addEventListener('submit', (e) => {
        const form = e.target;
        if (!(form instanceof Element) || !form.matches('[data-confirm]')) return;
        // A submitter with its own question already asked during the click —
        // the secondary "Clear"/"Remove" buttons that carry `formaction`.
        if (e.submitter && e.submitter.hasAttribute('data-confirm')) return;
        if (replaying.has(form)) return;
        const message = form.getAttribute('data-confirm');
        if (!message) return;
        const submitter = e.submitter || null;
        e.preventDefault();
        window.ChickadeeUI.confirmAction(message, form).then((ok) => {
            if (ok) replaySubmit(form, submitter);
        });
    });
}());

// ── Nav dropdown menus ─────────────────────────────────────────────────────
// Click-to-open menus for nav items that carry more than one option (the
// Instructor course picker, the account/log-out menu).  Each is a
// [data-nav-dropdown] wrapper holding a .nav-dropdown-toggle button and a
// .nav-dropdown-menu panel.  Only one menu is open at a time; a click outside
// or Escape closes it.
(function navDropdowns() {
    const dropdowns = Array.from(document.querySelectorAll('[data-nav-dropdown]'));
    if (dropdowns.length === 0) return;

    function closeAll(except) {
        dropdowns.forEach((dd) => {
            if (dd === except) return;
            dd.classList.remove('open');
            const t = dd.querySelector('.nav-dropdown-toggle');
            if (t) t.setAttribute('aria-expanded', 'false');
        });
    }

    dropdowns.forEach((dd) => {
        const toggle = dd.querySelector('.nav-dropdown-toggle');
        if (!toggle) return;
        toggle.addEventListener('click', (e) => {
            e.preventDefault();
            e.stopPropagation();
            const willOpen = !dd.classList.contains('open');
            closeAll(dd);
            dd.classList.toggle('open', willOpen);
            toggle.setAttribute('aria-expanded', willOpen ? 'true' : 'false');
        });
    });

    // Outside click closes any open menu.  Clicks inside a menu (e.g. the
    // account link, or a submitting course-picker button) are left alone.
    document.addEventListener('click', (e) => {
        if (e.target.closest('[data-nav-dropdown]')) return;
        closeAll(null);
    });

    document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape') closeAll(null);
    });
}());

// ── Floating action popovers (per-student extension / grade-override) ────────
// The <details class="ext-details"> panels on the roster and submission pages
// hold a .popover-panel or .ext-panel form. They live inside .results-table,
// which clips its overflow (for the rounded corners), so a panel on a row near
// the bottom of the table is cut off — the Save button disappears below the
// table edge and can't even be scrolled to.
//
// When a panel opens, promote it to position:fixed and place it next to its
// summary button, clamped to stay fully within the viewport: below the button
// when it fits, flipped above when it doesn't, and height-capped with its own
// scroll if it is somehow taller than the screen. position:fixed also escapes
// the table's overflow clip. Phones keep the CSS static-flow panel (the
// max-width:640px rule), which is in normal flow and never overflows.
//
// Delegated on the document (capture phase — `toggle` does not bubble) so
// panels rebuilt by a background poll repaint keep floating without rebinding.
(function floatingActionPopovers() {
    const PANEL_SELECTOR = '.popover-panel, .ext-panel';

    const GAP = 6;      // px between the summary button and the panel
    const MARGIN = 8;   // min px kept clear of every viewport edge
    const isPhone = () => window.matchMedia('(max-width: 640px)').matches;
    // Geometry the JS computes per-open; the static float styling
    // (position:fixed etc.) lives on .is-floating in styles.css.
    const FLOATED = ['left', 'top', 'maxHeight'];

    let active = null;  // the <details> whose panel is currently floated

    const panelOf = (d) => d.querySelector(PANEL_SELECTOR);

    const clear = (panel) => {
        if (!panel) return;
        panel.classList.remove('is-floating');
        FLOATED.forEach((prop) => { panel.style[prop] = ''; });
    };

    function place(d) {
        const summary = d.querySelector('summary');
        const panel = panelOf(d);
        if (!summary || !panel) return;
        // On phones the CSS drops the panel into static flow — leave it there.
        if (isPhone()) { clear(panel); return; }

        // Float it, cap its height to the viewport, and measure at the cap.
        panel.classList.add('is-floating');
        panel.style.maxHeight = (window.innerHeight - 2 * MARGIN) + 'px';
        panel.style.left = '0px';
        panel.style.top = '0px';

        const s = summary.getBoundingClientRect();
        const pw = panel.offsetWidth;
        const ph = panel.offsetHeight;

        // Right-align the panel under the button, then clamp horizontally.
        const left = Math.min(Math.max(s.right - pw, MARGIN), window.innerWidth - pw - MARGIN);
        // Prefer below the button; flip above if it would overflow the bottom;
        // clamp to the top edge if it fits neither way.
        let top = s.bottom + GAP;
        if (top + ph > window.innerHeight - MARGIN) {
            const above = s.top - GAP - ph;
            top = above >= MARGIN ? above : Math.max(MARGIN, window.innerHeight - MARGIN - ph);
        }
        panel.style.left = Math.round(left) + 'px';
        panel.style.top = Math.round(top) + 'px';
    }

    const reposition = () => { if (active && active.open) place(active); };

    document.addEventListener('toggle', (e) => {
        const d = e.target;
        if (!(d instanceof Element) || !d.matches('details.ext-details')) return;
        if (!panelOf(d)) return;
        if (d.open) {
            // Native <details> allow several open at once; only float one.
            if (active && active !== d) active.open = false;
            active = d;
            place(d);
        } else {
            clear(panelOf(d));
            if (active === d) active = null;
        }
    }, true);

    // Keep the floated panel glued to its button as the page scrolls/resizes.
    // Capture phase so it also fires for scrolls inside nested scroll areas.
    window.addEventListener('scroll', reposition, true);
    window.addEventListener('resize', reposition);
    document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape' && active) active.open = false;
    });
}());
