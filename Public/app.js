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

// Results page: poll until the submission is no longer pending
const root = document.getElementById('submission-root');
if (root && root.dataset.pending === 'true') {
    const submissionID = root.dataset.submissionId;
    const poll = setInterval(async () => {
        try {
            const res = await fetch(`/api/v1/submissions/${submissionID}`);
            if (!res.ok) return;
            const data = await res.json();
            if (data.status !== 'pending' && data.status !== 'assigned') {
                clearInterval(poll);
                window.location.reload();
            }
        } catch (_) {
            // network blip — try again next tick
        }
    }, 2000);
}
