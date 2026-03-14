// Public/browser-runner.js
//
// Chickadee browser-side WASM runner for labs (gradingMode: "browser").
//
// Submit-triggered (not polling): notebook.js calls window.BrowserRunner.runAndSubmit()
// when the student clicks Submit.  Tests run locally in Pyodide; the notebook
// bytes and TestOutcomeCollection are submitted to the server in one atomic call.
//
// Workflow:
//   1. Fetch test setup zip from /api/v1/browser-runner/testsetups/:id/download
//   2. Unpack zip into Pyodide in-memory filesystem
//   3. Write test_runtime.py + sitecustomize.py helper libraries
//   4. Write notebook bytes and extract code cells to .py (equiv. of nb_to_py.py)
//   5. Run each .py test script in Pyodide; capture stdout/stderr
//   6. POST notebook bytes + TestOutcomeCollection to /api/v1/submissions/browser-result
//
// Only active for gradingMode="browser" pages (guard at top of IIFE).
// R test scripts (.R) are deferred until WebR is available (Issue #77).
// Shell scripts (.sh) are not supported in the browser environment.

(function () {
    'use strict';

    const scriptEl    = document.currentScript;
    const gradingMode = scriptEl ? scriptEl.dataset.gradingMode : null;

    // Only expose browser runner for browser-graded assignments.
    if (gradingMode !== 'browser') return;

    const statusEl = document.getElementById('browser-runner-status');
    if (statusEl) statusEl.hidden = false;

    // -------------------------------------------------------------------------
    // Public API — called by notebook.js on Submit
    // -------------------------------------------------------------------------

    window.BrowserRunner = { runAndSubmit };

    /**
     * Run all test scripts against the student's notebook and submit results.
     *
     * @param {Uint8Array} notebookBytes  Raw bytes of the student's .ipynb file.
     * @param {string}     setupID        The test setup ID for this assignment.
     * @returns {{ outcomes: object[], response: object }}
     */
    async function runAndSubmit(notebookBytes, setupID) {
        let py, JSZip;
        try {
            setRunnerStatus('loading', 'Initializing Python runtime…');
            py = await loadPyodideOnce();
        } catch (e) {
            throw new Error('Failed to initialize Python runtime: ' + toMessage(e));
        }
        try {
            JSZip = await loadJSZip();
        } catch (e) {
            throw new Error('Failed to load ZIP library: ' + toMessage(e));
        }

        // Unique work directory per run to avoid state leakage.
        const workDir = `/chickadee_work_${Date.now()}`;
        try {
            py.FS.mkdir(workDir);
        } catch (e) {
            throw new Error('Failed to create work directory: ' + toMessage(e));
        }

        try {
            // 1. Download and unpack the test setup zip.
            setRunnerStatus('loading', 'Fetching test setup…');
            let setupZip;
            try {
                setupZip = await fetchBytes(`/api/v1/browser-runner/testsetups/${setupID}/download`);
            } catch (e) {
                throw new Error('Failed to download test setup: ' + toMessage(e));
            }
            let zip;
            try {
                zip = await JSZip.loadAsync(setupZip);
            } catch (e) {
                throw new Error('Failed to unpack test setup zip: ' + toMessage(e));
            }
            for (const [name, file] of Object.entries(zip.files)) {
                if (file.dir) continue;
                const data     = await file.async('uint8array');
                const fullPath = `${workDir}/${name}`;
                // Create parent directories as needed.
                const parts = name.split('/');
                if (parts.length > 1) {
                    let cur = workDir;
                    for (const part of parts.slice(0, -1)) {
                        cur += '/' + part;
                        try { py.FS.mkdir(cur); } catch (_) { /* already exists */ }
                    }
                }
                py.FS.writeFile(fullPath, data);
            }

            // 2. Write runtime helper libraries.
            py.FS.writeFile(`${workDir}/test_runtime.py`,  TEST_RUNTIME_PY);
            py.FS.writeFile(`${workDir}/sitecustomize.py`, SITECUSTOMIZE_PY);

            // 3. Write notebook bytes and extract code cells to .py.
            const notebookFilename = 'submission.ipynb';
            py.FS.writeFile(`${workDir}/${notebookFilename}`, notebookBytes);
            const notebookText = new TextDecoder().decode(notebookBytes);
            await extractNotebook(py, workDir, notebookFilename, notebookText);

            // Add working directory to Python's path and set up builtins.
            //
            // sitecustomize.py is NOT auto-imported in Pyodide — the interpreter
            // is already running when we write the file to MEMFS, so CPython's
            // "import sitecustomize at startup" never fires.  We must import it
            // explicitly here.  We also flush stale copies of our helper modules
            // (test_runtime, sitecustomize, and any student_* modules) so that
            // repeated submissions within the same Pyodide session don't inherit
            // the previous run's module state (especially test_runtime's
            // _loaded_student_modules global).
            try {
                await py.runPythonAsync(`
import sys, os

# Replace any stale chickadee work-directory on the path.
sys.path = [p for p in sys.path if not p.startswith('/chickadee_work_')]
sys.path.insert(0, '${workDir}')
os.chdir('${workDir}')

# Flush stale helper + student modules so fresh files are picked up.
for _key in list(sys.modules.keys()):
    if _key in ('sitecustomize', 'test_runtime') or _key.startswith('student_'):
        del sys.modules[_key]

# Importing sitecustomize runs its side-effects: registers passed/failed/
# errored/require_function as builtins and loads student code into
# builtins.student_module.
import sitecustomize  # noqa: F401
`);
            } catch (e) {
                throw new Error('Failed to configure Python environment: ' + toMessage(e));
            }

            // 4. Fetch manifest from server (test.properties.json is not in the zip;
            //    the server serves it directly from the database via the manifest endpoint).
            setRunnerStatus('loading', 'Loading test configuration…');
            let manifest;
            try {
                const manifestText = await fetchText(`/api/v1/browser-runner/testsetups/${setupID}/manifest`);
                manifest = JSON.parse(manifestText);
            } catch (e) {
                throw new Error('Failed to load test configuration: ' + toMessage(e));
            }
            const outcomes = [];

            setRunnerStatus('loading', 'Running tests…');
            for (const entry of manifest.testSuites || []) {
                const script     = entry.script || '';
                const ext        = script.split('.').pop().toLowerCase();
                const tier       = entry.tier || 'public';
                const scriptPath = `${workDir}/${script}`;

                if (ext === 'py') {
                    let src = '';
                    try { src = py.FS.readFile(scriptPath, { encoding: 'utf8' }); }
                    catch (_) {
                        outcomes.push(makeOutcome(script, tier, 'error',
                            `Script not found: ${script}`, null, 0));
                        continue;
                    }
                    outcomes.push(await runPyScript(py, src, script, tier,
                        manifest.timeLimitSeconds || 10));

                } else if (ext === 'r') {
                    outcomes.push(makeOutcome(script, tier, 'error',
                        'R test scripts require WebR — not yet supported in browser runner',
                        null, 0));

                } else if (ext === 'sh' || ext === 'bash') {
                    outcomes.push(makeOutcome(script, tier, 'error',
                        'Shell scripts cannot run in the browser runner',
                        null, 0));

                } else {
                    outcomes.push(makeOutcome(script, tier, 'error',
                        `Unsupported test script type: .${ext}`,
                        null, 0));
                }
            }

            // 5. Build collection and POST notebook + results atomically.
            const collection = buildCollection(setupID, outcomes);
            const response   = await postBrowserResult(notebookBytes, collection, setupID);

            setRunnerStatus('ok', 'Done — results submitted.');
            return { outcomes, response };

        } finally {
            // Clean up MEMFS to avoid OOM on repeated submissions.
            try { removeRecursive(py, workDir); } catch (_) { /* best-effort */ }
        }
    }

    // -------------------------------------------------------------------------
    // Status display
    // -------------------------------------------------------------------------

    function setRunnerStatus(type, msg) {
        if (!statusEl) return;
        statusEl.textContent = msg;
        statusEl.className   = `nb-status${type ? ' nb-status-' + type : ''}`;
    }

    // -------------------------------------------------------------------------
    // Notebook extraction (mirrors runner-support nb_to_py.py / RunnerDaemon.swift)
    // -------------------------------------------------------------------------

    async function extractNotebook(py, workDir, filename, notebookText) {
        let notebook;
        try { notebook = JSON.parse(notebookText); } catch (_) { return; }

        // Detect kernel language the same way RunnerDaemon.swift does.
        const meta   = notebook.metadata || {};
        const ks     = meta.kernelspec || {};
        const ksName = (ks.name || '').toLowerCase();
        const liName = ((meta.language_info || {}).name || '').toLowerCase();
        const isR    = ksName === 'ir' || ksName === 'r' || ksName === 'webr' || liName === 'r';
        const ext    = isR ? 'R' : 'py';

        const stem    = filename.replace(/\.ipynb$/i, '');
        const outPath = `${workDir}/${stem}.${ext}`;

        let code = `# Generated from ${filename}\n\n`;
        for (const cell of (notebook.cells || [])) {
            if (cell.cell_type !== 'code') continue;
            const src = Array.isArray(cell.source)
                ? cell.source.join('')
                : (cell.source || '');
            const trimmed = src.replace(/\s+$/, '');
            if (trimmed.trim()) code += trimmed + '\n\n';
        }

        py.FS.writeFile(outPath, code);

        // Write .chickadee_student_module hint so test_runtime.py can find the file.
        py.FS.writeFile(`${workDir}/.chickadee_student_module`, `${stem}.${ext}`);
    }

    // -------------------------------------------------------------------------
    // Python script execution
    // -------------------------------------------------------------------------

    async function runPyScript(py, src, scriptName, tier, timeLimitSeconds) {
        const startMs = Date.now();
        let stdout    = '';
        let stderr    = '';

        // Redirect sys.stdout / sys.stderr to JS buffers.
        await py.runPythonAsync(`
import sys, io
_br_stdout = io.StringIO()
_br_stderr = io.StringIO()
sys.stdout = _br_stdout
sys.stderr = _br_stderr
`);

        let timedOut = false;
        let pyErr    = null;

        const runPromise     = py.runPythonAsync(src).catch(err => { pyErr = err; });
        const timeoutPromise = sleep(timeLimitSeconds * 1000).then(() => { timedOut = true; });

        await Promise.race([runPromise, timeoutPromise]);

        // Restore stdout/stderr and collect output.
        try {
            const captured = await py.runPythonAsync(`
(str(_br_stdout.getvalue()), str(_br_stderr.getvalue()))
`);
            [stdout, stderr] = captured.toJs ? captured.toJs() : [String(captured), ''];
            captured.destroy && captured.destroy();
        } catch (_) { /* fallback: no output */ }

        await py.runPythonAsync(`
sys.stdout = sys.__stdout__
sys.stderr = sys.__stderr__
`);

        const executionTimeMs = Date.now() - startMs;

        if (timedOut) {
            return makeOutcome(scriptName, tier, 'timeout', 'timed out', null, executionTimeMs);
        }

        // Parse status from stdout.  test_runtime.py prints one JSON line then
        // raises SystemExit.  If no JSON was printed, fall back to exit-code logic.
        const lastLine = (stdout || '')
            .split('\n')
            .map(l => l.trim())
            .filter(l => l)
            .pop() || '';

        let status      = 'pass';
        let shortResult = 'passed';
        let longResult  = null;

        if (pyErr) {
            const msg = pyErr.message || String(pyErr);
            if (msg.includes('SystemExit')) {
                // test_runtime.py called passed/failed/errored.
                const exitMatch = msg.match(/SystemExit:\s*(-?\d+)/);
                const code = exitMatch ? parseInt(exitMatch[1]) : 1;
                status = code === 0 ? 'pass' : code === 1 ? 'fail' : 'error';
            } else {
                status = 'error';
            }
        }

        // Prefer the JSON result the script printed (same protocol as native runner).
        if (lastLine) {
            try {
                const parsed = JSON.parse(lastLine);
                shortResult = parsed.shortResult || (status === 'pass' ? 'passed' : status);
            } catch (_) {
                shortResult = lastLine.substring(0, 200);
            }
        } else {
            shortResult = status === 'pass' ? 'passed' : status === 'fail' ? 'failed' : 'error';
        }

        if (status !== 'pass') {
            const parts      = [];
            const stdoutTrim = (stdout || '').trim();
            const stderrTrim = (stderr || '').trim();
            if (stdoutTrim) parts.push(`stdout:\n${stdoutTrim}`);
            if (stderrTrim) parts.push(`stderr:\n${stderrTrim}`);
            if (pyErr && !String(pyErr.message).includes('SystemExit')) {
                parts.push(`exception:\n${pyErr.message || pyErr}`);
            }
            if (parts.length) longResult = parts.join('\n\n');
        } else if ((stderr || '').trim()) {
            longResult = (stderr || '').trim();
        }

        return makeOutcome(scriptName, tier, status, shortResult, longResult, executionTimeMs);
    }

    // -------------------------------------------------------------------------
    // Outcome / collection builders
    // -------------------------------------------------------------------------

    function makeOutcome(scriptName, tier, status, shortResult, longResult, executionTimeMs) {
        // Strip extension to get test name (matches native runner).
        const testName = scriptName.replace(/\.\w+$/, '') || scriptName;
        return {
            testName,
            testClass:          null,
            tier,
            status,
            shortResult,
            longResult:         longResult || null,
            executionTimeMs,
            memoryUsageBytes:   null,
            attemptNumber:      1,
            isFirstPassSuccess: status === 'pass',
        };
    }

    function buildCollection(setupID, outcomes) {
        const passCount    = outcomes.filter(o => o.status === 'pass').length;
        const failCount    = outcomes.filter(o => o.status === 'fail').length;
        const errorCount   = outcomes.filter(o => o.status === 'error').length;
        const timeoutCount = outcomes.filter(o => o.status === 'timeout').length;
        const totalMs      = outcomes.reduce((s, o) => s + o.executionTimeMs, 0);

        return {
            submissionID:    '',    // server fills this in when it creates the record
            testSetupID:     setupID,
            attemptNumber:   1,     // server recomputes from prior submission count
            buildStatus:     outcomes.length === 0 ? 'failed' : 'passed',
            compilerOutput:  null,
            outcomes,
            totalTests:      outcomes.length,
            passCount,
            failCount,
            errorCount,
            timeoutCount,
            executionTimeMs: totalMs,
            runnerVersion:   'browser-wasm-runner/1.0',
            timestamp:       new Date().toISOString(),
        };
    }

    // -------------------------------------------------------------------------
    // POST notebook bytes + TestOutcomeCollection to the server
    // -------------------------------------------------------------------------

    async function postBrowserResult(notebookBytes, collection, setupID) {
        const formData = new FormData();
        formData.append('collection', JSON.stringify(collection));
        formData.append('notebook',
            new Blob([notebookBytes], { type: 'application/octet-stream' }),
            'submission.ipynb');
        formData.append('testSetupID', setupID);

        const res = await fetch('/api/v1/submissions/browser-result', {
            method: 'POST',
            body:   formData,
        });
        if (!res.ok) {
            const text = await res.text();
            throw new Error(`Failed to submit results: ${res.status} ${text}`);
        }
        return res.json();
    }

    // -------------------------------------------------------------------------
    // Pyodide loader (lazy singleton)
    // -------------------------------------------------------------------------

    let _pyodide = null;

    async function loadPyodideOnce() {
        if (_pyodide) return _pyodide;
        if (!window.loadPyodide) {
            await loadScript('https://cdn.jsdelivr.net/pyodide/v0.27.0/full/pyodide.js');
        }
        _pyodide = await window.loadPyodide();
        return _pyodide;
    }

    // -------------------------------------------------------------------------
    // JSZip loader (lazy singleton)
    // -------------------------------------------------------------------------

    let _JSZip = null;

    async function loadJSZip() {
        if (_JSZip) return _JSZip;
        if (!window.JSZip) {
            await loadScript('https://cdn.jsdelivr.net/npm/jszip@3.10.1/dist/jszip.min.js');
        }
        _JSZip = window.JSZip;
        return _JSZip;
    }

    // -------------------------------------------------------------------------
    // MEMFS helpers
    // -------------------------------------------------------------------------

    function removeRecursive(py, path) {
        const stat = py.FS.stat(path);
        if (py.FS.isDir(stat.mode)) {
            for (const name of py.FS.readdir(path)) {
                if (name === '.' || name === '..') continue;
                removeRecursive(py, `${path}/${name}`);
            }
            py.FS.rmdir(path);
        } else {
            py.FS.unlink(path);
        }
    }

    // -------------------------------------------------------------------------
    // Misc helpers
    // -------------------------------------------------------------------------

    async function fetchBytes(url) {
        const res = await fetch(url);
        if (!res.ok) throw new Error(`Fetch failed ${res.status}: ${url}`);
        return res.arrayBuffer();
    }

    async function fetchText(url) {
        const res = await fetch(url);
        if (!res.ok) throw new Error(`Fetch failed ${res.status}: ${url}`);
        return res.text();
    }

    /** Converts any thrown value to a human-readable string. */
    function toMessage(e) {
        if (e instanceof Error && e.message) return e.message;
        const s = String(e);
        return (s && s !== '[object Object]') ? s : 'unknown error';
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

    function sleep(ms) {
        return new Promise(resolve => setTimeout(resolve, ms));
    }

    // -------------------------------------------------------------------------
    // Embedded runtime helpers (kept in sync with Sources/Worker/RunnerDaemon.swift)
    // -------------------------------------------------------------------------

    // test_runtime.py — mirrors the testRuntimePy string in RunnerDaemon.swift.
    // Update both locations when making changes.
    const TEST_RUNTIME_PY = `\
import inspect
import importlib.util
import json
import sys
import traceback
from pathlib import Path
from typing import Dict, List, Optional, Any


def _caller_file(depth: int = 3) -> Path:
    frame = inspect.stack()[depth]
    return Path(frame.filename)


def _first_comment_label() -> str:
    path = _caller_file()
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            s = line.strip()
            if not s:
                continue
            if s.startswith("#!") or s.startswith("# -*-"):
                continue
            if s.startswith("#"):
                label = s.lstrip("#").strip()
                return label if label else path.stem
            break
    except Exception:
        pass
    return path.stem


def _emit(payload: Dict[str, object]) -> None:
    print(json.dumps(payload, ensure_ascii=False))


def passed(message: Optional[str] = None):
    label = _first_comment_label()
    _emit({
        "shortResult": message or f"{label}: passed",
        "status": "pass",
        "test": label,
    })
    raise SystemExit(0)


def failed(message: str = "failed"):
    label = _first_comment_label()
    _emit({
        "shortResult": f"{label}: failed",
        "status": "fail",
        "test": label,
        "error": message,
    })
    raise SystemExit(1)


def errored(message: str = "error", err: Optional[Exception] = None):
    label = _first_comment_label()
    summary = message.strip() if isinstance(message, str) and message.strip() else "error"
    payload = {
        "shortResult": f"{label}: {summary}",
        "status": "error",
        "test": label,
        "error": summary,
    }
    if err is not None:
        payload["exception"] = repr(err)
        payload["traceback"] = traceback.format_exc()
    _emit(payload)
    raise SystemExit(2)


def _candidate_student_files() -> List[Path]:
    cwd = Path(".")
    files: List[Path] = []
    for p in cwd.glob("*.py"):
        name = p.name
        if name in {"test_runtime.py", "sitecustomize.py", "nb_to_py.py"}:
            continue
        lower = name.lower()
        if lower.startswith("publictest") or lower.startswith("secrettest") or lower.startswith("releasetest"):
            continue
        files.append(p)
    return sorted(files, key=_student_file_sort_key)


def _student_file_sort_key(path: Path):
    lower = path.name.lower()
    if lower == "assignment.py":
        return (90, lower)
    if lower in {"solution.py", "submission.py"}:
        return (0, lower)
    return (10, lower)


def _preferred_student_module() -> Optional[Path]:
    hint = Path(".chickadee_student_module")
    if not hint.exists():
        return None
    try:
        raw = hint.read_text(encoding="utf-8").strip()
    except Exception:
        return None
    if not raw:
        return None
    preferred = Path(raw).name
    if not preferred.endswith(".py"):
        return None
    path = Path(preferred)
    return path if path.exists() else None


def _module_name_for_path(path: Path) -> str:
    stem = path.stem
    safe = "".join(ch if (ch.isalnum() or ch == "_") else "_" for ch in stem)
    if not safe:
        safe = "student"
    if safe[0].isdigit():
        safe = f"m_{safe}"
    return f"student_{safe}"


def _ordered_student_files() -> List[Path]:
    preferred = _preferred_student_module()
    if preferred is not None:
        return [preferred]
    return _candidate_student_files()


_loaded_student_modules: Optional[Dict[str, Any]] = None
_loaded_student_order: List[str] = []
_student_module_errors: Dict[str, str] = {}


def load_student_modules(force_reload: bool = False) -> Dict[str, Any]:
    global _loaded_student_modules, _loaded_student_order, _student_module_errors
    if _loaded_student_modules is not None and not force_reload:
        return _loaded_student_modules

    modules: Dict[str, Any] = {}
    order: List[str] = []
    errors: Dict[str, str] = {}

    for path in _ordered_student_files():
        key = path.name
        try:
            module_name = _module_name_for_path(path)
            spec = importlib.util.spec_from_file_location(module_name, path)
            if spec is None or spec.loader is None:
                errors[key] = "Could not create import spec."
                continue
            module = importlib.util.module_from_spec(spec)
            sys.modules[module_name] = module
            spec.loader.exec_module(module)
            modules[key] = module
            order.append(key)
        except Exception:
            errors[key] = traceback.format_exc()

    _loaded_student_modules = modules
    _loaded_student_order = order
    _student_module_errors = errors
    return modules


def student_module_errors() -> Dict[str, str]:
    return _student_module_errors


def student_module_names_in_load_order() -> List[str]:
    return list(_loaded_student_order)


def load_student_module():
    modules = load_student_modules()
    if not _loaded_student_order:
        return None
    return modules.get(_loaded_student_order[0])


def require_function(name: str):
    modules = load_student_modules()
    for key in _loaded_student_order:
        module = modules.get(key)
        if module is None:
            continue
        fn = getattr(module, name, None)
        if fn is not None and callable(fn):
            return fn

    if not modules:
        errors = student_module_errors()
        if errors:
            first_name = next(iter(errors.keys()))
            errored(
                "Could not load any student Python module from submission. "
                f"First load failure came from '{first_name}'."
            )
        errored("Could not load a student Python module from submission.")

    errored(f"Required function '{name}' was not found or is not callable in loaded student modules.")
`;

    // sitecustomize.py — auto-imported by Python; makes helpers available as builtins.
    // Mirrors the sitecustomizePy constant in RunnerDaemon.swift.
    const SITECUSTOMIZE_PY = `\
import builtins
import test_runtime as _tr

builtins.passed = _tr.passed
builtins.failed = _tr.failed
builtins.errored = _tr.errored
builtins.require_function = _tr.require_function

_student_modules = _tr.load_student_modules()
builtins.student_modules = _student_modules
_student_module = _tr.load_student_module()
builtins.student_module = _student_module
for _module_name in _tr.student_module_names_in_load_order():
    _module = _student_modules.get(_module_name)
    if _module is None:
        continue
    for _name, _value in vars(_module).items():
        if _name.startswith("_"):
            continue
        if callable(_value) and not hasattr(builtins, _name):
            setattr(builtins, _name, _value)
`;

})();
