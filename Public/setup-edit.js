// Public/setup-edit.js
//
// Instructor notebook editor page (Phase 8).
//
// Two independent features:
//
// 1. SAVE — The instructor edits the notebook in JupyterLite, downloads it via
//    JupyterLite's built-in "File → Download" menu, then uploads the .ipynb
//    here. Clicking the "Save notebook…" label opens a file picker; on change
//    the file is PUT to /api/v1/testsetups/:id/assignment.
//
// 2. RUN TESTS — Re-uses the full Pyodide engine from assignment-validate.js.
//    The instructor uploads a .py solution file and the saved version of the
//    notebook is fetched from the server (so they always test the saved state,
//    not an in-memory draft).

(function () {
    'use strict';

    const scriptEl     = document.currentScript;
    const setupID      = scriptEl ? scriptEl.dataset.setupId      : null;
    const assignmentID = scriptEl ? scriptEl.dataset.assignmentId : null;
    const editorURL    = scriptEl ? scriptEl.dataset.editorUrl    : null;
    const notebookURL  = scriptEl ? scriptEl.dataset.notebookUrl  : null;

    // ── DOM refs ─────────────────────────────────────────────────────────────
    const frame          = document.getElementById('jl-frame');
    const saveFile       = document.getElementById('save-file');
    const editStatus     = document.getElementById('edit-status');
    const runBtn         = document.getElementById('run-btn');
    const runPanel       = document.getElementById('run-panel');
    const solutionFile   = document.getElementById('solution-file');
    const runSolutionBtn = document.getElementById('run-solution-btn');
    const validateStatus = document.getElementById('validate-status');
    const resultsEl      = document.getElementById('validate-results');

    if (!setupID || !frame) return;

    // ── 1. Load JupyterLite ──────────────────────────────────────────────────
    // The server pre-materializes a versioned notebook file and passes a full
    // editor URL with workspace + path so JupyterLite can open it directly.
    frame.src = editorURL ||
        `/jupyterlite/lab/index.html?workspace=${encodeURIComponent(setupID)}&reset&path=assignment.ipynb`;

    // ── 2. Save notebook ─────────────────────────────────────────────────────
    // Workflow:
    //   a. Instructor edits in JupyterLite.
    //   b. Instructor chooses File → Download in JupyterLite to get the .ipynb.
    //   c. Instructor clicks "Save notebook…" label → file picker opens.
    //   d. On file selected: PUT raw JSON to /api/v1/testsetups/:id/assignment.

    if (saveFile) {
        saveFile.addEventListener('change', async () => {
            const file = saveFile.files && saveFile.files[0];
            if (!file) return;

            setStatus(editStatus, 'loading', 'Saving…');

            try {
                const text = await readFileAsText(file);

                // Basic JSON sanity check before uploading.
                JSON.parse(text);

                const res = await fetch(`/api/v1/testsetups/${setupID}/assignment`, {
                    method:  'PUT',
                    headers: { 'Content-Type': 'application/json' },
                    body:    text,
                });

                if (res.ok) {
                    setStatus(editStatus, 'ok', 'Saved ✓');
                    setTimeout(() => setStatus(editStatus, '', ''), 4000);
                } else {
                    const msg = await res.text().catch(() => res.statusText);
                    setStatus(editStatus, 'error', `Save failed: ${msg}`);
                }
            } catch (err) {
                setStatus(editStatus, 'error', `Save failed: ${err.message}`);
            } finally {
                // Reset the file input so the same file can be selected again.
                saveFile.value = '';
            }
        });
    }

    // ── 3. Run tests button ──────────────────────────────────────────────────
    // Shows/hides the inline validation panel.

    if (runBtn && runPanel) {
        // Enable after page is interactive (always enabled — no prerequisite).
        runBtn.disabled = false;

        runBtn.addEventListener('click', () => {
            runPanel.hidden = !runPanel.hidden;
            if (!runPanel.hidden) {
                runPanel.scrollIntoView({ behavior: 'smooth', block: 'start' });
            }
        });
    }

    // Enable "Run" inside the panel when a solution file is selected.
    if (solutionFile && runSolutionBtn) {
        solutionFile.addEventListener('change', () => {
            runSolutionBtn.disabled = !solutionFile.files || solutionFile.files.length === 0;
        });
    }

    if (runSolutionBtn) {
        runSolutionBtn.addEventListener('click', async () => {
            if (!solutionFile || !solutionFile.files || solutionFile.files.length === 0) return;

            runSolutionBtn.disabled = true;
            clearResults();
            setStatus(validateStatus, 'loading', 'Loading grading engine…');

            try {
                const solutionSource = await readFileAsText(solutionFile.files[0]);

                // Always fetch the *server-saved* version of the notebook
                // so that the run reflects the last saved state.
                setStatus(validateStatus, 'loading', 'Fetching test definitions…');
                const nbRes = await fetch(notebookURL);
                if (!nbRes.ok) {
                    throw new Error(`Could not fetch notebook: ${nbRes.status}. Save your edits first.`);
                }
                const notebook = await nbRes.json();

                setStatus(validateStatus, 'loading', 'Running tests…');
                const outcomes = await runSolutionAgainstNotebook(solutionSource, notebook);

                renderResults(outcomes);
                setStatus(validateStatus, '', '');
            } catch (err) {
                setStatus(validateStatus, 'error', `Error: ${err.message}`);
            } finally {
                runSolutionBtn.disabled = false;
            }
        });
    }

    // ── Pyodide execution engine ─────────────────────────────────────────────
    // (Identical to assignment-validate.js — kept local to avoid a shared
    //  module dependency for now.)

    let pyodide = null;

    async function loadPyodideOnce() {
        if (pyodide) return pyodide;
        if (!window.loadPyodide) {
            await loadScript('https://cdn.jsdelivr.net/pyodide/v0.27.0/full/pyodide.js');
        }
        pyodide = await window.loadPyodide();
        return pyodide;
    }

    async function runSolutionAgainstNotebook(solutionSource, notebook) {
        const py = await loadPyodideOnce();

        // Fresh interpreter for each run.
        await py.runPythonAsync('import sys; sys.modules.clear()');

        // Step 1: Execute the solution file.
        try {
            await py.runPythonAsync(solutionSource);
        } catch (err) {
            const longResult = await captureTraceback(py, err);
            return [{
                testName:          'solution_load_error',
                testClass:         null,
                tier:              'public',
                status:            'error',
                shortResult:       `Solution failed to load: ${firstLine(err.message)}`,
                longResult,
                executionTimeMs:   0,
                memoryUsageBytes:  null,
                attemptNumber:     1,
                isFirstPassSuccess: false,
            }];
        }

        // Step 2: Run setup cells, then test cells.
        const outcomes = [];

        for (const cell of notebook.cells) {
            if (cell.cell_type !== 'code') continue;

            const source = Array.isArray(cell.source)
                ? cell.source.join('')
                : cell.source;

            if (!source.trim()) continue;

            const testMeta = parseTestComment(source);
            const startMs  = Date.now();

            if (testMeta) {
                const outcome = await runTestCell(py, source, testMeta, startMs);
                outcomes.push(outcome);
            } else {
                try {
                    await py.runPythonAsync(source);
                } catch (err) {
                    const longResult = await captureTraceback(py, err);
                    outcomes.push({
                        testName:          'setup_error',
                        testClass:         null,
                        tier:              'public',
                        status:            'error',
                        shortResult:       `Setup cell failed: ${firstLine(err.message)}`,
                        longResult,
                        executionTimeMs:   Date.now() - startMs,
                        memoryUsageBytes:  null,
                        attemptNumber:     1,
                        isFirstPassSuccess: false,
                    });
                    break;
                }
            }
        }

        return outcomes;
    }

    async function runTestCell(py, source, meta, startMs) {
        let status      = 'pass';
        let shortResult = 'passed';
        let longResult  = null;

        try {
            await py.runPythonAsync(source);
        } catch (err) {
            const msg = err.message || String(err);
            longResult = await captureTraceback(py, err);

            if (msg.includes('AssertionError') || msg.includes('assert')) {
                status = 'fail';
                const assertMsg = extractAssertionMessage(msg);
                shortResult = assertMsg
                    ? `failed: ${assertMsg.substring(0, 80)}`
                    : 'failed';
            } else {
                status      = 'error';
                shortResult = `error: ${firstLine(msg).substring(0, 80)}`;
            }
        }

        return {
            testName:          meta.name,
            testClass:         null,
            tier:              meta.tier,
            status,
            shortResult,
            longResult,
            executionTimeMs:   Date.now() - startMs,
            memoryUsageBytes:  null,
            attemptNumber:     1,
            isFirstPassSuccess: status === 'pass',
        };
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    async function captureTraceback(py, err) {
        try {
            const tb = await py.runPythonAsync(`
import traceback, sys
_exc = sys.last_value
if _exc is not None:
    ''.join(traceback.format_exception(type(_exc), _exc, _exc.__traceback__))
else:
    ''
`);
            return tb.trim() || (err.message || String(err));
        } catch (_) {
            return err.message || String(err);
        }
    }

    function extractAssertionMessage(msg) {
        const line = msg.split('\n').find(l => l.includes('AssertionError'));
        if (!line) return null;
        const colon = line.indexOf(':');
        return colon >= 0 ? line.slice(colon + 1).trim() : null;
    }

    function firstLine(msg) {
        return (msg || '').split('\n')[0].trim();
    }

    function parseTestComment(source) {
        const line  = source.trimStart().split('\n')[0];
        const match = line.match(/^#\s*TEST:\s*(\S+)(.*)/);
        if (!match) return null;
        const name  = match[1];
        const kvStr = match[2].trim();
        const kv    = {};
        for (const part of kvStr.split(/\s+/)) {
            const [k, v] = part.split('=');
            if (k && v !== undefined) kv[k] = v;
        }
        return { name, tier: kv.tier || 'public' };
    }

    function readFileAsText(file) {
        return new Promise((resolve, reject) => {
            const reader = new FileReader();
            reader.onload  = e => resolve(e.target.result);
            reader.onerror = () => reject(new Error('Could not read file'));
            reader.readAsText(file);
        });
    }

    // ── Results rendering ────────────────────────────────────────────────────

    function clearResults() {
        if (resultsEl) {
            resultsEl.hidden    = true;
            resultsEl.innerHTML = '';
        }
    }

    function renderResults(outcomes) {
        if (!resultsEl) return;

        const pass    = outcomes.filter(o => o.status === 'pass').length;
        const total   = outcomes.length;
        const totalMs = outcomes.reduce((s, o) => s + o.executionTimeMs, 0);
        const allPassed = pass === total && total > 0;

        const scoreEl = document.createElement('p');
        scoreEl.className = 'score';
        scoreEl.innerHTML =
            `${pass} / ${total} passed ` +
            `<span class="exec-time">(${totalMs} ms)</span>` +
            (allPassed ? ' <span style="color:var(--green)">✓ All tests passed!</span>' : '');

        const table = document.createElement('table');
        table.className = 'results-table';
        table.innerHTML = `
            <thead>
                <tr>
                    <th>Test</th>
                    <th>Tier</th>
                    <th>Result</th>
                    <th>ms</th>
                </tr>
            </thead>`;

        const tbody = document.createElement('tbody');
        for (const o of outcomes) {
            const tr = document.createElement('tr');
            tr.className = `status-${o.status}`;
            const longCell = o.longResult
                ? `<details><summary>details</summary><pre>${escHtml(o.longResult)}</pre></details>`
                : '';
            tr.innerHTML = `
                <td><code>${escHtml(o.testName)}</code></td>
                <td><span class="tier">${escHtml(o.tier)}</span></td>
                <td>${escHtml(o.shortResult)}${longCell}</td>
                <td class="time">${o.executionTimeMs}</td>`;
            tbody.appendChild(tr);
        }
        table.appendChild(tbody);

        resultsEl.innerHTML = '';
        resultsEl.appendChild(scoreEl);
        resultsEl.appendChild(table);
        resultsEl.hidden = false;
        resultsEl.scrollIntoView({ behavior: 'smooth', block: 'start' });
    }

    function escHtml(str) {
        return String(str ?? '')
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;');
    }

    function setStatus(el, type, msg) {
        if (!el) return;
        el.textContent = msg;
        el.className   = `nb-status${type ? ' nb-status-' + type : ''}`;
    }

    function loadScript(src) {
        return new Promise((resolve, reject) => {
            const s   = document.createElement('script');
            s.src     = src;
            s.onload  = resolve;
            s.onerror = () => reject(new Error(`Failed to load ${src}`));
            document.head.appendChild(s);
        });
    }
})();
