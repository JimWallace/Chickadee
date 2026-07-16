// Returns the CSRF token from the <meta name="csrf-token"> tag in <head>.
// Used by JS fetch calls to satisfy the CSRF middleware on POST endpoints.
// Kept as a global for back-compat; delegates to the shared implementation
// in Public/chickadee-ui.js.
/* exported getCsrfToken */
function getCsrfToken() {
    return ChickadeeUI.getCsrfToken();
}

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
