// notebook.js — Glue between the Chickadee parent page and the JupyterLite iframe.
//
// Flow:
//   1. Fetch the instructor's assignment.ipynb from the Chickadee server.
//   2. Seed it into JupyterLite's IndexedDB storage (only on first visit; don't
//      overwrite the student's existing work).
//   3. Navigate the iframe to open the notebook.
//   4. On Submit: read the current notebook from IndexedDB and POST it to
//      POST /api/v1/submissions/file.

(async function () {
    const frame   = document.getElementById('jl-frame');
    const statusEl = document.getElementById('nb-status');
    const setupID = frame.dataset.setupId;

    // JupyterLite storage constants (must match the built JupyterLite app).
    const JL_DB_NAME    = 'JupyterLite Storage - ./';
    const JL_STORE_NAME = 'files';
    const NOTEBOOK_KEY  = 'assignment.ipynb';

    // ── IndexedDB helpers ────────────────────────────────────────────────────

    function openDB() {
        return new Promise((resolve, reject) => {
            const req = indexedDB.open(JL_DB_NAME);
            req.onupgradeneeded = e => {
                // Create the store if JupyterLite hasn't initialised it yet.
                if (!e.target.result.objectStoreNames.contains(JL_STORE_NAME)) {
                    e.target.result.createObjectStore(JL_STORE_NAME);
                }
            };
            req.onsuccess = e => resolve(e.target.result);
            req.onerror   = e => reject(e.target.error);
        });
    }

    function dbGet(db, key) {
        return new Promise((resolve, reject) => {
            const tx  = db.transaction(JL_STORE_NAME, 'readonly');
            const req = tx.objectStore(JL_STORE_NAME).get(key);
            req.onsuccess = e => resolve(e.target.result);
            req.onerror   = e => reject(e.target.error);
        });
    }

    function dbPut(db, key, value) {
        return new Promise((resolve, reject) => {
            const tx  = db.transaction(JL_STORE_NAME, 'readwrite');
            const req = tx.objectStore(JL_STORE_NAME).put(value, key);
            req.onsuccess = () => resolve();
            req.onerror   = e => reject(e.target.error);
        });
    }

    // ── Seed the notebook on first visit ─────────────────────────────────────

    async function seedNotebook() {
        const db = await openDB();

        // Don't overwrite existing student work.
        const existing = await dbGet(db, NOTEBOOK_KEY);
        if (existing) {
            db.close();
            return;
        }

        // Fetch the instructor's skeleton from our server.
        let nb;
        try {
            const res = await fetch(`/api/v1/testsetups/${setupID}/assignment`);
            if (!res.ok) throw new Error(`HTTP ${res.status}`);
            nb = await res.json();
        } catch (err) {
            console.warn('[Chickadee] Could not load assignment notebook:', err);
            db.close();
            return;
        }

        // Write the notebook model in the format JupyterLite's BrowserStorageDrive expects.
        const now = new Date().toISOString();
        const model = {
            name:          NOTEBOOK_KEY,
            path:          NOTEBOOK_KEY,
            type:          'notebook',
            format:        'json',
            content:       nb,
            mimetype:      'application/x-ipynb+json',
            writable:      true,
            created:       now,
            last_modified: now,
            size:          null,
        };

        await dbPut(db, NOTEBOOK_KEY, model);
        db.close();
    }

    // ── Submit handler ────────────────────────────────────────────────────────

    document.getElementById('nb-submit').addEventListener('click', async () => {
        statusEl.textContent = 'Reading notebook…';

        let model;
        try {
            const db = await openDB();
            model    = await dbGet(db, NOTEBOOK_KEY);
            db.close();
        } catch (err) {
            statusEl.textContent = 'Error reading notebook from storage.';
            console.error('[Chickadee] IndexedDB read failed:', err);
            return;
        }

        if (!model) {
            statusEl.textContent = 'No notebook found — have you opened the assignment?';
            return;
        }

        statusEl.textContent = 'Submitting…';

        const nbJSON = JSON.stringify(model.content);
        const blob   = new Blob([nbJSON], { type: 'application/json' });
        const form   = new FormData();
        form.append('testSetupID', setupID);
        form.append('filename',    NOTEBOOK_KEY);
        form.append('file',        blob, NOTEBOOK_KEY);

        let json;
        try {
            const resp = await fetch('/api/v1/submissions/file', { method: 'POST', body: form });
            if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
            json = await resp.json();
        } catch (err) {
            statusEl.textContent = 'Submission failed — please try again.';
            console.error('[Chickadee] Submission error:', err);
            return;
        }

        window.location.href = `/submissions/${json.submissionID}`;
    });

    // ── Boot sequence ─────────────────────────────────────────────────────────

    await seedNotebook();
    frame.src = `/jupyterlite/lab/index.html?path=${encodeURIComponent(NOTEBOOK_KEY)}`;
}());
