// Returns the CSRF token from the <meta name="csrf-token"> tag in <head>.
// Used by JS fetch calls to satisfy the CSRF middleware on POST endpoints.
function getCsrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content
        ?? document.querySelector('input[name="_csrf"]')?.value
        ?? '';
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
