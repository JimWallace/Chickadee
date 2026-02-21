// Drag-drop zone on the submission form
const dropZone   = document.getElementById('drop-zone');
const fileInput  = document.getElementById('file-input');
const fileNameEl = document.getElementById('drop-filename');

if (dropZone && fileInput) {
    dropZone.addEventListener('click', () => fileInput.click());

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

// Results page: poll until the submission reaches its final state.
//
// Statuses that require polling:
//   pending / assigned       — worker hasn't started yet
//   browser-complete         — browser run done, waiting for official worker result
const root = document.getElementById('submission-root');
if (root) {
    const isPending         = root.dataset.pending === 'true';
    const isBrowserComplete = root.dataset.browserComplete === 'true';

    if (isPending || isBrowserComplete) {
        const submissionID = root.dataset.submissionId;
        const poll = setInterval(async () => {
            try {
                const res = await fetch(`/api/v1/submissions/${submissionID}`);
                if (!res.ok) return;
                const data = await res.json();
                const done = data.status !== 'pending'
                          && data.status !== 'assigned'
                          && data.status !== 'browser-complete';
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
