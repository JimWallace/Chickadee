// Chickadee — "Generate Starter Tests" panel on the new-assignment page.
//
// Scans the draft's solution notebook for function definitions, lists them as
// checkboxes, and writes one generated test script per checked function into
// the draft suite.
//
// WHY IT LIVES HERE. It was ~90 lines of inline JS in `assignment-new.leaf`,
// which is neither linted nor testable, and #1269 already established that the
// create page's inline copies are where this codebase's stale forks accumulate.
// `applyScanPayload` had been moved into `pattern-family-editor.js` for exactly
// this reason; the caller stayed behind. Two of the three defects fixed in the
// move were invisible from the template:
//
//   * the scan did not tell the server which language to read, so a declared-R
//     assignment whose solution still carried a Python kernelspec scanned as
//     Python and listed functions no generated test could be written for;
//   * the generate step filtered its work list to empty on any non-Python
//     assignment and then reported "N test file(s) added to suite." from the
//     count of files it had NOT written.
//
// Config is passed in rather than read from globals, so the page's Leaf
// conditionals (is there a draft? is there a solution notebook?) stay in the
// template where they belong:
//
//   csrfToken          string
//   draftID            string | null   — null before the first notebook upload
//   solutionNotebookURL string | null  — the draft's saved solution, when it has one

(function (global) {
    'use strict';

    /// Wires the panel. Safe to call on a page that does not render it.
    function initGeneratedStarterTests(config) {
        var cfg = config || {};
        var csrfToken = cfg.csrfToken;

        var scanBtn        = document.getElementById('scan-solution-btn');
        var scanStatus     = document.getElementById('scan-status');
        var scanResults    = document.getElementById('scan-results');
        var fnChecklist    = document.getElementById('fn-checklist');
        var genTplSelect   = document.getElementById('gen-template-select');
        var addGenTestsBtn = document.getElementById('add-gen-tests-btn');
        var genPanel       = document.getElementById('gen-tests-panel');

        if (!scanBtn && !addGenTestsBtn) return;

        var scannedFunctions = [];

        if (cfg.solutionNotebookURL && genPanel) genPanel.style.display = '';

        function setStatus(text) { if (scanStatus) scanStatus.textContent = text; }

        // Say up front that the scan cannot read this language, rather than
        // running it and reporting "No functions found." — the same answer an
        // empty solution gives, which is how an R author was left unable to
        // tell a limitation from a mistake.  The server says as much when
        // asked; asking requires clicking a button that looks like it works.
        if (!global.ChickadeeLanguage.canScanFunctions()) {
            var scanLabel = global.ChickadeeLanguage.label();
            if (scanBtn) scanBtn.disabled = true;
            setStatus('Scanning a solution for functions is Python-only'
                + (scanLabel ? ', and this is a ' + scanLabel + ' assignment' : '')
                + '. Use "+ Add Test" in a section to add a test by hand.');
            return;
        }

        /// The template the scan already rendered for this function, or a
        /// placeholder when the scan carried none.
        function generatedTemplate(type, fnName) {
            var fn = scannedFunctions.find(function (f) { return f.name === fnName; });
            if (fn && Array.isArray(fn.templates)) {
                var key = type.indexOf(':') === -1 ? type : type.split(':')[1];
                var tpl = fn.templates.find(function (t) { return t.id === key; });
                if (tpl && typeof tpl.content === 'string') return tpl.content;
            }
            return '# Test: ' + fnName + '\n# TODO: implement test\npassed("placeholder")\n';
        }

        function runScan(notebookText) {
            setStatus('Scanning…');
            if (scanResults) scanResults.style.display = 'none';
            // Tell the server which language to read, as the family editor's
            // scan does. Without it the endpoint falls back to the notebook's
            // own kernelspec — a better default than assuming Python, but not
            // the assignment's declared answer.
            var scanLanguage = global.ChickadeeLanguage.facts().name;
            var scanURL = '/instructor/scan-notebook'
                + (scanLanguage ? '?language=' + encodeURIComponent(scanLanguage) : '');
            return fetch(scanURL, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json', 'x-csrf-token': csrfToken },
                body: notebookText
            })
            .then(function (r) { return r.ok ? r.json() : Promise.reject(r.statusText); })
            .then(function (payload) {
                // Shared with the family editor, so the "we cannot read this
                // language" message is written once. It clears the checklist on
                // an unsupported language, which is what stops the generate
                // step below from ever being reachable there.
                scannedFunctions = global.chickadeeApplyScanPayload(payload,
                    { status: scanStatus, checklist: fnChecklist, results: scanResults });
                return scannedFunctions;
            })
            .catch(function (err) { setStatus('Scan failed: ' + err); return []; });
        }

        if (scanBtn) {
            scanBtn.addEventListener('click', function () {
                var solInput = document.getElementById('solution-notebook-file-input');
                var hasUpload = solInput && solInput.files.length > 0;
                if (!hasUpload && cfg.solutionNotebookURL) {
                    fetch(cfg.solutionNotebookURL, { headers: { 'x-csrf-token': csrfToken } })
                        .then(function (r) { return r.ok ? r.text() : Promise.reject(r.statusText); })
                        .then(function (text) { runScan(text); })
                        .catch(function (err) { setStatus('Scan failed: ' + err); });
                    return;
                }
                if (!hasUpload) {
                    setStatus('Upload a solution notebook first.');
                    return;
                }
                var reader = new FileReader();
                reader.onload = function (e) { runScan(e.target.result); };
                reader.readAsText(solInput.files[0]);
            });
        }

        if (addGenTestsBtn) {
            addGenTestsBtn.addEventListener('click', function () {
                if (!cfg.draftID) {
                    setStatus('Upload a notebook first to start a draft.');
                    return;
                }
                var tplType = genTplSelect ? genTplSelect.value : 'py:correctness';
                var checked = fnChecklist
                    ? Array.prototype.slice.call(
                        fnChecklist.querySelectorAll('input[type=checkbox]:checked'))
                    : [];
                if (checked.length === 0) {
                    setStatus('Select at least one function.');
                    return;
                }
                // REFUSE OUT LOUD. This used to filter the work list to empty
                // on any non-Python assignment and then report success with
                // `checked.length` — a count of files nobody wrote. The guard
                // is right: these templates ARE Python and land under a `.py`
                // name, which is a thing to keep out of another language's
                // suite. Only its silence was wrong.
                if (!global.ChickadeeLanguage.isPython()) {
                    var langLabel = global.ChickadeeLanguage.label();
                    setStatus('Generated starter tests are Python-only'
                        + (langLabel ? ', and this is a ' + langLabel + ' assignment' : '')
                        + '. Use "+ Add Test" in a section to add one by hand.');
                    return;
                }
                setStatus('Saving ' + checked.length + ' test(s)…');
                var ops = checked.map(function (chk) {
                    var fnName = chk.value;
                    return fetch('/instructor/new/draft/scripts?draftID='
                        + encodeURIComponent(cfg.draftID), {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json', 'x-csrf-token': csrfToken },
                        body: JSON.stringify({
                            filename: 'test_' + fnName + '.py',
                            content: generatedTemplate(tplType, fnName),
                            tier: 'public',
                            points: 1,
                            isTest: true
                        })
                    }).then(function (r) {
                        return r.ok
                            ? r.json()
                            : r.text().then(function (t) {
                                return Promise.reject(t || ('HTTP ' + r.status));
                            });
                    }).then(function (data) {
                        if (global.chickadeeAddExistingSuiteScript) {
                            global.chickadeeAddExistingSuiteScript(data);
                        }
                    });
                });
                Promise.all(ops).then(function () {
                    setStatus(checked.length + ' test file(s) added to suite.');
                    if (scanResults) scanResults.style.display = 'none';
                }).catch(function (err) {
                    setStatus('Could not add generated tests: ' + err);
                });
            });
        }
    }

    global.initGeneratedStarterTests = initGeneratedStarterTests;
})(window);
