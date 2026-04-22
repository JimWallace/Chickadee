// Chickadee — Pattern Family Editor
//
// Browser-side module that drives the pattern-family modal on the
// instructor assignment authoring pages.  Factored out of
// Resources/Views/assignment-edit.leaf in v0.4.90 so the edit and create
// pages render from a single copy instead of two copies that drift on
// every polish release.
//
// The modal HTML still lives in the Leaf template (both pages include the
// same block of markup — extracting that hit a LeafKit cycle-detection
// false-positive); this file owns every event listener, fetch, and piece
// of state that hangs off those DOM IDs.  DOM IDs are stable:
//   family-editor-overlay, family-editor-title, family-editor-close,
//   family-editor-status, family-id, family-name, family-kind,
//   family-function, family-params, family-function-select,
//   family-function-hint, family-function-label,
//   family-default-hint, family-default-tolerance, family-tolerance-label,
//   family-cases-header, family-cases-body, family-cases-empty,
//   add-case-btn, add-family-btn, family-save-btn, family-cancel-btn.
//
// The host page wires the module via:
//
//   window.initPatternFamilyEditor({
//       assignmentID: 'TWTFKZ',                 // edit mode
//       // OR
//       draftID: 'setup_ab12...',               // create-draft mode (future)
//       csrfToken: '<token>',
//       initialFamilies: [...],                 // parsed pattern-families-seed JSON
//       urls: {
//           solutionNotebook: function () {...}, // GET returns .ipynb JSON bytes
//           scanNotebook:     function () {...}, // POST /scan-notebook endpoint
//           putFamilies:      function () {...}  // PUT endpoint for full family list
//       },
//       onFamiliesChange: function (applied) {} // suite-table sync hook
//   })
//
// Returns `{ open(indexOrNegOne), close(), getFamilies() }`.  Host calls
// `open(-1)` from its "New Family" button and `open(idx)` when the suite
// table's "Edit Family" button fires.

(function (global) {
    'use strict';

    function initPatternFamilyEditor(config) {
        config = config || {};
        var csrfToken       = config.csrfToken || '';
        var urls            = config.urls || {};
        var onFamiliesChange = typeof config.onFamiliesChange === 'function'
            ? config.onFamiliesChange
            : function () {};

        if (typeof urls.solutionNotebook !== 'function'
         || typeof urls.scanNotebook     !== 'function'
         || typeof urls.putFamilies      !== 'function') {
            throw new Error('initPatternFamilyEditor: urls must supply solutionNotebook, scanNotebook, putFamilies functions');
        }

        // ── State ──────────────────────────────────────────────────────────
        var familiesState = Array.isArray(config.initialFamilies)
            ? config.initialFamilies.slice()
            : [];

        // Cached scan result.  Populated on first modal open, reused until the
        // page reloads.  Each entry has { name, paramNames, paramTypes,
        // returnType, paramCount, isShadowed }.
        var scannedFunctions = null;
        var scanLoading = false;

        var addFamilyBtn     = document.getElementById('add-family-btn');
        var overlay          = document.getElementById('family-editor-overlay');
        var titleEl          = document.getElementById('family-editor-title');
        var idInput          = document.getElementById('family-id');
        var nameInput        = document.getElementById('family-name');
        var kindInput        = document.getElementById('family-kind');
        var fnInput          = document.getElementById('family-function');
        var paramsInput      = document.getElementById('family-params');
        var fnSelect         = document.getElementById('family-function-select');
        var fnHint           = document.getElementById('family-function-hint');
        var defaultHintInput = document.getElementById('family-default-hint');
        var toleranceInput   = document.getElementById('family-default-tolerance');
        var toleranceLabel   = document.getElementById('family-tolerance-label');
        var functionLabel    = document.getElementById('family-function-label');
        var casesHeader      = document.getElementById('family-cases-header');
        var casesBody        = document.getElementById('family-cases-body');
        var casesEmpty       = document.getElementById('family-cases-empty');
        var addCaseBtn       = document.getElementById('add-case-btn');
        var saveBtn          = document.getElementById('family-save-btn');
        var cancelBtn        = document.getElementById('family-cancel-btn');
        var closeBtn         = document.getElementById('family-editor-close');
        var statusEl         = document.getElementById('family-editor-status');

        if (!overlay) {
            // No modal rendered on this page — still return the API so the
            // host doesn't crash at init time, but all methods no-op.
            return noopAPI();
        }

        var editingIndex = -1;   // index in familiesState; -1 when creating.
        // The modal no longer asks for tier/points — the suite table row owns
        // those.  On edit we keep the family's existing values; on create we
        // default and the instructor adjusts from the row afterwards.
        var editingTier = 'public';
        var editingPoints = 1;

        // Current function's type annotations.  Populated from the scan result
        // in applyFunctionSelection and used by readCasesFromTable to coerce
        // typed cell values into the right JSON shape (so `True` in a `bool`
        // column becomes `true`, not the string "True").  Parallel to
        // paramNames; each entry is either a string (Python type annotation
        // as written — `int`, `bool`, `list[int]`, `Optional[str]`) or null.
        var currentParamTypes = [];
        var currentReturnType = null;

        function escHtml(s) {
            return String(s == null ? '' : s)
                .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
                .replace(/"/g, '&quot;');
        }

        // ── Solution-notebook scan ─────────────────────────────────────────

        /// Fetches the assignment's solution notebook and posts it to the
        /// scan-notebook endpoint.  Caches the result on `scannedFunctions`.
        function ensureScannedFunctions() {
            if (scannedFunctions !== null) return Promise.resolve(scannedFunctions);
            if (scanLoading) {
                return new Promise(function (resolve) {
                    var iv = setInterval(function () {
                        if (!scanLoading) { clearInterval(iv); resolve(scannedFunctions || []); }
                    }, 50);
                });
            }
            scanLoading = true;
            return fetch(urls.solutionNotebook(), {
                headers: { 'x-csrf-token': csrfToken }
            })
            .then(function (r) { return r.ok ? r.text() : Promise.reject('No solution notebook'); })
            .then(function (text) {
                return fetch(urls.scanNotebook(), {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json', 'x-csrf-token': csrfToken },
                    body: text
                });
            })
            .then(function (r) { return r.ok ? r.json() : Promise.reject('Scan failed'); })
            .then(function (fns) { scannedFunctions = fns || []; scanLoading = false; return scannedFunctions; })
            .catch(function () { scannedFunctions = []; scanLoading = false; return []; });
        }

        function populateFunctionSelect(selectedName) {
            if (!scannedFunctions || !scannedFunctions.length) {
                fnSelect.innerHTML = '<option value="">— No functions detected in solution —</option>';
                fnSelect.disabled = true;
                fnHint.textContent = 'Create or update the solution notebook so its top-level functions can be detected.';
                return;
            }
            fnSelect.disabled = false;
            fnHint.textContent = '';
            var options = ['<option value="">— Select a function —</option>'];
            scannedFunctions.forEach(function (fn) {
                var label = fn.name + '(' + ((fn.paramNames || []).join(', ')) + ')';
                // A shadowed definition is one the runtime will never see —
                // Python's second `def <name>` replaces the first, so a family
                // targeting the early version silently fails with "wrong arity"
                // errors.  Disable the option and annotate so the instructor
                // sees why.
                if (fn.isShadowed) {
                    label += '  ⚠ redefined later (will not be callable)';
                    options.push('<option value="" disabled>' + escHtml(label) + '</option>');
                    return;
                }
                var sel = (fn.name === selectedName) ? ' selected' : '';
                options.push('<option value="' + escHtml(fn.name) + '"' + sel + '>' + escHtml(label) + '</option>');
            });
            fnSelect.innerHTML = options.join('');
            // If a function was preselected, make sure derived fields are consistent.
            if (selectedName) applyFunctionSelection(selectedName, /*preserveCases=*/true);
        }

        /// When a function is picked (or the modal opens in edit mode), update
        /// the hidden id/function/params fields and rebuild the per-arg columns
        /// in the cases table.  Optionally preserves existing case rows (edit mode).
        function applyFunctionSelection(fnName, preserveCases) {
            var fn = null;

            // Edit mode: if an existing family already has paramNames, pick
            // the scanner entry whose arity matches.  Without this the
            // non-shadowed preference below swaps a 1-arg family onto the
            // 3-arg overload (and vice versa) the instant the modal reopens
            // — the columns silently change under the saved cases.
            var desiredParamCount = null;
            if (preserveCases && editingIndex >= 0) {
                var family = familiesState[editingIndex];
                if (family && family.paramNames) desiredParamCount = family.paramNames.length;
            }
            if (desiredParamCount != null) {
                (scannedFunctions || []).forEach(function (f) {
                    if (f.name !== fnName) return;
                    if ((f.paramNames || []).length !== desiredParamCount) return;
                    fn = f;
                });
            }

            // New-family (or no-matching-arity) path: pick the LAST
            // (non-shadowed) occurrence — that's the version Python actually
            // exposes at runtime.  `Array.find` would return the first, which
            // is the shadowed one.
            if (!fn) {
                (scannedFunctions || []).forEach(function (f) {
                    if (f.name === fnName && !f.isShadowed) fn = f;
                });
            }
            if (!fn) {
                // Fallback: no live definition (only shadowed ones) — fall
                // through to first match so the editor still populates, but
                // the dropdown will have already disabled these entries.
                fn = (scannedFunctions || []).find(function (f) { return f.name === fnName; });
            }
            var paramNames = fn ? (fn.paramNames || []) : [];
            // Capture the per-parameter + return types for type-aware coercion
            // of cell values.  Fall back to an all-null array when the scanner
            // didn't report paramTypes (older clients or hint-free notebooks).
            var scannedTypes = fn ? (fn.paramTypes || []) : [];
            currentParamTypes = paramNames.map(function (_, i) {
                return scannedTypes[i] != null ? scannedTypes[i] : null;
            });
            currentReturnType = fn ? (fn.returnType || null) : null;
            fnInput.value = fnName || '';
            paramsInput.value = paramNames.join(',');
            // Default family id to the function name (user can't edit it in v1).
            // Keep existing id in edit mode where it may differ.
            if (!preserveCases || !idInput.value) {
                idInput.value = fnName ? sanitizeFamilyID(fnName) : '';
            }
            // Auto-suggest a family name if the user hasn't typed one yet.
            if (fnName && !nameInput.value.trim()) {
                nameInput.value = fnName + ' — boundary cases';
            }
            rebuildCasesHeader(paramNames);
            if (!preserveCases) {
                casesBody.innerHTML = '';
                addCaseRow(null, paramNames);
            } else {
                // Regenerate rows to match the new param columns, preserving
                // existing data by position.
                var existing = readCasesFromTableRaw(paramNames.length);
                casesBody.innerHTML = '';
                existing.forEach(function (c) { addCaseRow(c, paramNames); });
                if (!existing.length) addCaseRow(null, paramNames);
            }
            updateCasesEmptyMessage();
        }

        function sanitizeFamilyID(s) {
            return String(s || '').toLowerCase().replace(/[^a-z0-9_]/g, '_').replace(/^_+|_+$/g, '');
        }

        function rebuildCasesHeader(paramNames) {
            var th = ['<th style="width:2.25rem">#</th>', '<th>Label</th>'];
            if (!paramNames.length) {
                th.push('<th>Args (JSON)</th>');
            } else {
                paramNames.forEach(function (p, i) {
                    // Show the type annotation alongside the param name when
                    // we know it — `bmi: float`, `exempt: bool` — so the
                    // instructor sees what the column expects without
                    // scrolling back to the solution.
                    var t = currentParamTypes && currentParamTypes[i];
                    var label = t ? (escHtml(p) + ': ' + escHtml(t)) : escHtml(p);
                    th.push('<th><code style="font-size:.7rem">' + label + '</code></th>');
                });
            }
            var expectedHeader = currentReturnType
                ? 'Expected <code style="font-size:.7rem;font-weight:normal">: ' + escHtml(currentReturnType) + '</code>'
                : 'Expected';
            th.push('<th>' + expectedHeader + '</th>');
            th.push('<th>Hint (override)</th>');
            th.push('<th style="width:4rem"></th>');
            casesHeader.innerHTML = th.join('');
        }

        // ── Cases table ────────────────────────────────────────────────────

        function updateCasesEmptyMessage() {
            casesEmpty.style.display = casesBody.children.length === 0 ? '' : 'none';
        }

        function addCaseRow(initial, paramNames) {
            paramNames = paramNames || [];
            var c = initial || { label: '', args: [], expected: null, hint: '' };
            var tds = [];
            // Column 1: auto-numbered sequence (readonly, regenerated on reorder).
            tds.push('<td class="pf-case-num" style="text-align:center;color:var(--meta);font-size:.75rem"></td>');
            tds.push('<td><input type="text" class="form-input pf-case-label" value="' + escHtml(c.label) + '" placeholder="e.g. bmi < 18.5 is underweight" style="width:100%;padding:.2rem .4rem;font-size:.8rem"></td>');

            if (!paramNames.length) {
                // No param names yet — single free-form JSON args field.
                tds.push('<td><input type="text" class="form-input pf-case-args" value="' + escHtml(JSON.stringify(c.args || [])) + '" placeholder="[18.49]" style="width:100%;padding:.2rem .4rem;font-size:.8rem;font-family:monospace"></td>');
            } else {
                paramNames.forEach(function (_, i) {
                    var val = (c.args && c.args[i] !== undefined) ? renderTypedCellValue(c.args[i]) : '';
                    tds.push('<td><input type="text" class="form-input pf-case-arg" data-arg-index="' + i + '" value="' + escHtml(val) + '" placeholder="e.g. 18.49 or underweight" style="width:100%;padding:.2rem .4rem;font-size:.8rem;font-family:monospace"></td>');
                });
            }
            tds.push('<td><input type="text" class="form-input pf-case-expected" value="' + escHtml(c.expected == null ? '' : renderTypedCellValue(c.expected)) + '" placeholder="e.g. underweight" style="width:100%;padding:.2rem .4rem;font-size:.8rem;font-family:monospace"></td>');
            tds.push('<td><input type="text" class="form-input pf-case-hint" value="' + escHtml(c.hint || '') + '" style="width:100%;padding:.2rem .4rem;font-size:.8rem"></td>');
            tds.push('<td><button type="button" class="btn action-btn action-danger pf-case-remove" style="padding:.2rem .4rem;font-size:.75rem">Remove</button></td>');

            var tr = document.createElement('tr');
            tr.innerHTML = tds.join('');
            casesBody.appendChild(tr);
            // Existing non-empty expected values are treated as author-set so
            // the auto-computer doesn't overwrite them on first edit.
            if (c.expected != null) {
                var expCell = tr.querySelector('.pf-case-expected');
                if (expCell && expCell.value.trim() !== '') expCell.dataset.manual = '1';
            }
            renumberCases();
            updateCasesEmptyMessage();
        }

        function renumberCases() {
            Array.from(casesBody.querySelectorAll('.pf-case-num')).forEach(function (td, i) {
                var n = i + 1;
                td.textContent = (n < 10 ? '0' + n : String(n));
            });
        }

        /// Interprets a per-column cell value the way an instructor would
        /// expect when we have no type information.  Accepts Python-style
        /// capitalised literals (`True`/`False`/`None`) in addition to JSON.
        function parseTypedCellValue(raw) {
            var trimmed = String(raw == null ? '' : raw).trim();
            switch (trimmed) {
                case 'True':  return true;
                case 'False': return false;
                case 'None':  return null;
            }
            try { return JSON.parse(trimmed); }
            catch (_) { return String(raw); }
        }

        /// Normalises a Python type annotation into a simple kind the coercer
        /// knows how to handle.  Strips `Optional[T]` / `Union[T, None]` /
        /// `T | None` wrappers and generic parameters (`list[int]` → `list`).
        function normaliseTypeHint(hint) {
            if (hint == null) return null;
            var t = String(hint).trim();
            if (!t) return null;
            var unionMatch = t.match(/^Union\[\s*([^,\]]+)\s*,\s*None\s*\]$/i);
            if (unionMatch) t = unionMatch[1].trim();
            var pipeMatch = t.match(/^([^|]+?)\s*\|\s*None$/);
            if (pipeMatch) t = pipeMatch[1].trim();
            var optMatch = t.match(/^Optional\[\s*(.+?)\s*\]$/);
            if (optMatch) t = optMatch[1].trim();
            var genMatch = t.match(/^([A-Za-z_][A-Za-z0-9_]*)\[/);
            if (genMatch) t = genMatch[1];
            return t.toLowerCase();
        }

        /// Type-aware coercion of a raw cell string into the right JSON shape
        /// for the column's type annotation.  Falls back to the generic
        /// `parseTypedCellValue` when the type is unknown, missing, or the
        /// raw string doesn't plausibly fit the declared type.
        function coerceByType(raw, typeHint) {
            var trimmed = String(raw == null ? '' : raw).trim();
            var kind = normaliseTypeHint(typeHint);
            if (!kind) return parseTypedCellValue(raw);

            if (trimmed === '' || trimmed === 'None' || trimmed === 'null') {
                return null;
            }

            switch (kind) {
                case 'bool': {
                    var lower = trimmed.toLowerCase();
                    if (lower === 'true'  || trimmed === 'True'  || trimmed === '1') return true;
                    if (lower === 'false' || trimmed === 'False' || trimmed === '0') return false;
                    return parseTypedCellValue(raw);
                }
                case 'int': {
                    if (/^-?\d+$/.test(trimmed)) return parseInt(trimmed, 10);
                    return parseTypedCellValue(raw);
                }
                case 'float': {
                    if (/^-?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/.test(trimmed)) {
                        return parseFloat(trimmed);
                    }
                    return parseTypedCellValue(raw);
                }
                case 'str':
                case 'string': {
                    if (trimmed.length >= 2 && trimmed[0] === '"' && trimmed[trimmed.length - 1] === '"') {
                        try { return JSON.parse(trimmed); } catch (_) { /* fall through */ }
                    }
                    if (trimmed.length >= 2 && trimmed[0] === "'" && trimmed[trimmed.length - 1] === "'") {
                        return trimmed.slice(1, -1);
                    }
                    return String(raw);
                }
                case 'list':
                case 'tuple':
                case 'dict':
                case 'set': {
                    try {
                        return JSON.parse(trimmed);
                    } catch (_) {
                        return parseTypedCellValue(raw);
                    }
                }
                default:
                    return parseTypedCellValue(raw);
            }
        }

        /// Inverse of `parseTypedCellValue` for redisplaying an existing
        /// value in a cell when the modal reopens.  Strings render without
        /// surrounding quotes so the user's original typing round-trips;
        /// everything else renders as JSON.
        function renderTypedCellValue(v) {
            if (v === null) return 'null';
            if (typeof v === 'string') return v;
            return JSON.stringify(v);
        }

        /// Reads current rows into PatternCase values.  Strict JSON is only
        /// required for the fallback single-args field (when no parameters
        /// are detected); per-column cells accept bare values.  Throws with
        /// a readable message on required-field or structural failures.
        function readCasesFromTable(paramNames) {
            paramNames = paramNames || [];
            var rows = Array.from(casesBody.querySelectorAll('tr'));
            var out = [];
            for (var i = 0; i < rows.length; i++) {
                var row = rows[i];
                var label = row.querySelector('.pf-case-label').value.trim();
                var rawExp = row.querySelector('.pf-case-expected').value;
                if (rawExp.trim() === '') rawExp = '';
                var hint   = row.querySelector('.pf-case-hint').value.trim();
                var caseNum = (i + 1 < 10 ? '0' + (i + 1) : String(i + 1));
                var args = [];
                if (paramNames.length === 0) {
                    var rawArgs = (row.querySelector('.pf-case-args') || {}).value || '';
                    rawArgs = rawArgs.trim();
                    if (rawArgs !== '') {
                        try { args = JSON.parse(rawArgs); }
                        catch (e) { throw new Error('Case ' + caseNum + ': args must be valid JSON (' + e.message + ')'); }
                        if (!Array.isArray(args)) throw new Error('Case ' + caseNum + ': args must be a JSON array');
                    }
                } else {
                    for (var a = 0; a < paramNames.length; a++) {
                        var cell = row.querySelector('.pf-case-arg[data-arg-index="' + a + '"]');
                        var raw = cell ? cell.value : '';
                        if (raw.trim() === '') throw new Error('Case ' + caseNum + ': missing value for "' + paramNames[a] + '"');
                        var paramTypeHint = currentParamTypes ? currentParamTypes[a] : null;
                        args.push(coerceByType(raw, paramTypeHint));
                    }
                }
                var expected;
                if (rawExp === '') throw new Error('Case ' + caseNum + ': expected value is required');
                expected = coerceByType(rawExp, currentReturnType);
                if (!label) throw new Error('Case ' + caseNum + ': label is required');
                out.push({
                    key: caseNum,
                    label: label,
                    args: args,
                    expected: expected,
                    hint: hint || null,
                    enabled: true
                });
            }
            return out;
        }

        /// Lossy read used when switching between function selections —
        /// preserves what we can but doesn't throw on parse errors.
        function readCasesFromTableRaw(argCount) {
            var rows = Array.from(casesBody.querySelectorAll('tr'));
            return rows.map(function (row) {
                var label = row.querySelector('.pf-case-label').value;
                var rawExp = row.querySelector('.pf-case-expected').value;
                var hint = row.querySelector('.pf-case-hint').value;
                var args = [];
                var cells = row.querySelectorAll('.pf-case-arg');
                if (cells.length) {
                    Array.from(cells).forEach(function (c) {
                        try { args.push(JSON.parse(c.value)); } catch (_) { args.push(null); }
                    });
                } else {
                    var single = row.querySelector('.pf-case-args');
                    if (single) {
                        try { args = JSON.parse(single.value); if (!Array.isArray(args)) args = []; } catch (_) { args = []; }
                    }
                }
                var expected = null;
                try { expected = rawExp.trim() === '' ? null : JSON.parse(rawExp); } catch (_) {}
                return { label: label, args: args, expected: expected, hint: hint };
            });
        }

        // ── Modal open/close ───────────────────────────────────────────────

        function updateKindVisibility() {
            var kind = kindInput.value;
            if (toleranceLabel) {
                toleranceLabel.style.display = (kind === 'approximate_equality') ? 'flex' : 'none';
            }
            // Variable-equality families don't target a function — hide the
            // function dropdown entirely and replace its role in the data
            // model with `paramNames = ["variable"]`.
            if (functionLabel) {
                functionLabel.style.display = (kind === 'variable_equality') ? 'none' : 'flex';
            }
        }

        /// Applies the data-model defaults that go with a given kind.
        /// Switching between non-variable kinds leaves cases alone.
        /// Switching to/from variable_equality changes the case column
        /// layout, so we rebuild the rows.
        function applyKindDefaults(newKind, previousKind) {
            if (newKind === previousKind) return;
            var switchedIntoVar  = (newKind      === 'variable_equality');
            var switchedOutOfVar = (previousKind === 'variable_equality');
            if (!switchedIntoVar && !switchedOutOfVar) return;

            if (switchedIntoVar) {
                fnInput.value = '_';
                paramsInput.value = 'variable';
                rebuildCasesHeader(['variable']);
                casesBody.innerHTML = '';
                addCaseRow(null, ['variable']);
            } else {
                fnInput.value = '';
                paramsInput.value = '';
                rebuildCasesHeader([]);
                casesBody.innerHTML = '';
                addCaseRow(null, []);
                if (fnSelect) fnSelect.value = '';
            }
            updateCasesEmptyMessage();
        }

        function openEditor(familyIdx) {
            editingIndex = (typeof familyIdx === 'number') ? familyIdx : -1;
            statusEl.textContent = '';
            casesBody.innerHTML = '';

            var preselectedFn = '';
            if (editingIndex >= 0) {
                var family = familiesState[editingIndex];
                titleEl.textContent = 'Edit Pattern Family';
                idInput.value = family.id || '';
                nameInput.value = family.name || '';
                kindInput.value = family.kind || 'boundary_equality';
                fnInput.value = family.functionName || '';
                paramsInput.value = (family.paramNames || []).join(',');
                editingTier = (family.defaults && family.defaults.tier) || 'public';
                editingPoints = Math.max(1, parseInt(family.defaults && family.defaults.points) || 1);
                defaultHintInput.value = (family.defaults && family.defaults.hint) || '';
                var tol = family.defaults && family.defaults.tolerance;
                toleranceInput.value = (tol == null) ? '' : String(tol);
                preselectedFn = family.functionName || '';
                rebuildCasesHeader(family.paramNames || []);
                (family.cases || []).forEach(function (c) { addCaseRow(c, family.paramNames || []); });
                if (!(family.cases || []).length) addCaseRow(null, family.paramNames || []);
            } else {
                titleEl.textContent = 'New Pattern Family';
                idInput.value = '';
                nameInput.value = '';
                kindInput.value = 'boundary_equality';
                fnInput.value = '';
                paramsInput.value = '';
                editingTier = 'public';
                editingPoints = 1;
                defaultHintInput.value = '';
                toleranceInput.value = '';
                rebuildCasesHeader([]);
            }
            updateKindVisibility();

            overlay.style.display = 'flex';
            updateCasesEmptyMessage();

            // Kick off (or reuse) the scan and populate the function dropdown.
            fnSelect.innerHTML = '<option value="">— Scanning solution notebook… —</option>';
            fnSelect.disabled = true;
            fnHint.textContent = '';
            ensureScannedFunctions().then(function () {
                populateFunctionSelect(preselectedFn);
            });

            setTimeout(function () { nameInput.focus(); }, 0);
        }

        function closeEditor() { overlay.style.display = 'none'; }

        function readFamilyFromEditor() {
            var paramNames = paramsInput.value.split(',').map(function (s) { return s.trim(); }).filter(Boolean);
            var cases = readCasesFromTable(paramNames);
            var kind = kindInput.value || 'boundary_equality';
            // For variable-equality families there's no function to derive
            // the family id from — fall back to a sanitised family name.
            if (kind === 'variable_equality' && !idInput.value.trim()) {
                var derivedID = sanitizeFamilyID(nameInput.value);
                if (!derivedID) {
                    throw new Error('Family name is required (used to derive the family id for variable-equality families).');
                }
                idInput.value = derivedID;
            }
            var defaults = {
                tier: editingTier,
                points: editingPoints,
                hint: defaultHintInput.value.trim() || null
            };
            if (kind === 'approximate_equality') {
                var tolRaw = (toleranceInput.value || '').trim();
                if (tolRaw !== '') {
                    var tol = Number(tolRaw);
                    if (!isFinite(tol) || tol < 0) {
                        throw new Error('Tolerance must be a non-negative number.');
                    }
                    defaults.tolerance = tol;
                }
            }
            return {
                id: idInput.value.trim(),
                name: nameInput.value.trim(),
                kind: kind,
                functionName: fnInput.value.trim(),
                paramNames: paramNames,
                defaults: defaults,
                cases: cases
            };
        }

        function putFamilies(next) {
            statusEl.textContent = 'Saving…';
            saveBtn.disabled = true;
            return fetch(urls.putFamilies(), {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json', 'x-csrf-token': csrfToken },
                body: JSON.stringify(next)
            })
            .then(function (r) {
                if (!r.ok) return r.text().then(function (t) { throw new Error(extractErrorMessage(t) || ('HTTP ' + r.status)); });
                return r.json();
            })
            .then(function (applied) {
                familiesState = applied;
                saveBtn.disabled = false;
                statusEl.textContent = '';
                return applied;
            })
            .catch(function (err) {
                saveBtn.disabled = false;
                statusEl.textContent = 'Error: ' + (err && err.message ? err.message : err);
                throw err;
            });
        }

        /// Server error pages are HTML; pull the `error-message` paragraph
        /// out of them so the status line shows a clean one-liner.
        function extractErrorMessage(body) {
            if (!body) return '';
            var m = body.match(/class="error-message"[^>]*>([\s\S]*?)<\/p>/);
            if (m) {
                var text = m[1].replace(/<[^>]+>/g, '').replace(/&#39;/g, "'").replace(/&quot;/g, '"')
                               .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>');
                return text.trim();
            }
            return body.length > 200 ? body.substring(0, 200) + '…' : body;
        }

        // ── Event wiring ───────────────────────────────────────────────────

        if (addFamilyBtn) addFamilyBtn.addEventListener('click', function () { openEditor(-1); });
        if (closeBtn)     closeBtn.addEventListener('click', closeEditor);
        if (cancelBtn)    cancelBtn.addEventListener('click', closeEditor);
        overlay.addEventListener('click', function (e) { if (e.target === overlay) closeEditor(); });
        document.addEventListener('keydown', function (e) {
            if (e.key === 'Escape' && overlay.style.display !== 'none') closeEditor();
        });

        if (fnSelect) fnSelect.addEventListener('change', function () {
            applyFunctionSelection(fnSelect.value, /*preserveCases=*/true);
        });

        if (kindInput) {
            var _previousKind = kindInput.value;
            kindInput.addEventListener('change', function () {
                var newKind = kindInput.value;
                applyKindDefaults(newKind, _previousKind);
                _previousKind = newKind;
                updateKindVisibility();
            });
        }

        if (addCaseBtn) addCaseBtn.addEventListener('click', function () {
            var paramNames = paramsInput.value.split(',').map(function (s) { return s.trim(); }).filter(Boolean);
            addCaseRow(null, paramNames);
        });
        casesBody.addEventListener('click', function (e) {
            var btn = e.target && e.target.closest('.pf-case-remove');
            if (btn) {
                var tr = btn.closest('tr');
                if (tr) tr.remove();
                renumberCases();
                updateCasesEmptyMessage();
            }
        });

        // ── Pyodide auto-compute of Expected column ───────────────────────
        // When the instructor fills in a case's input args, we evaluate the
        // selected function in the solution notebook against those args and
        // populate the Expected cell.  Loaded lazily on first row edit so
        // the ~10 MB Pyodide download doesn't happen if the instructor never
        // uses a family.  Respects manual overrides: once the user types in
        // the Expected cell we mark it `data-manual` and never clobber.
        var _pyodidePromise = null;
        var _solutionLoadedPromise = null;

        function getPyodide() {
            if (_pyodidePromise) return _pyodidePromise;
            _pyodidePromise = new Promise(function (resolve, reject) {
                if (window.loadPyodide) return resolve();
                var s = document.createElement('script');
                s.src = 'https://cdn.jsdelivr.net/pyodide/v0.27.0/full/pyodide.js';
                s.onload = resolve;
                s.onerror = function () { reject(new Error('Pyodide failed to load')); };
                document.head.appendChild(s);
            }).then(function () { return window.loadPyodide(); });
            return _pyodidePromise;
        }

        /// Splits a notebook into its code cells' source, skipping markdown,
        /// stripping IPython magic (`%`) and shell (`!`) lines.
        function extractSolutionCells(nb) {
            if (!nb || !Array.isArray(nb.cells)) return [];
            var out = [];
            nb.cells.forEach(function (cell) {
                if (cell.cell_type !== 'code') return;
                var src = Array.isArray(cell.source) ? cell.source.join('') : (cell.source || '');
                var lines = src.split('\n').filter(function (ln) {
                    var t = ln.replace(/^\s+/, '');
                    return t[0] !== '%' && t[0] !== '!';
                });
                var code = lines.join('\n');
                if (code.trim()) out.push(code);
            });
            return out;
        }

        /// Loads the solution notebook into Pyodide's global namespace,
        /// cell by cell, catching per-cell errors so one failing statement
        /// doesn't stop later cells from defining their functions.
        function ensureSolutionLoaded() {
            if (_solutionLoadedPromise) return _solutionLoadedPromise;
            _solutionLoadedPromise = fetch(urls.solutionNotebook(), {
                headers: { 'x-csrf-token': csrfToken }
            })
            .then(function (r) { return r.ok ? r.json() : Promise.reject(new Error('no-solution')); })
            .then(function (nb) {
                var cells = extractSolutionCells(nb);
                if (!cells.length) return Promise.reject(new Error('empty-solution'));
                return getPyodide().then(function (py) {
                    return cells.reduce(function (chain, cellSrc) {
                        return chain.then(function () {
                            return py.runPythonAsync(cellSrc).catch(function () {
                                // Swallow: usage-code failures in a cell
                                // don't prevent later defs from landing.
                            });
                        });
                    }, Promise.resolve()).then(function () { return py; });
                });
            });
            _solutionLoadedPromise.catch(function () { _solutionLoadedPromise = null; });
            return _solutionLoadedPromise;
        }

        /// Calls `fnName(*args)` on the loaded solution and returns the
        /// result as a JSON-serialisable value, or an error summary if it
        /// throws.
        function callSolution(fnName, args) {
            return ensureSolutionLoaded().then(function (py) {
                var argsJSON = JSON.stringify(args);
                var pyCode = [
                    'import json as _json',
                    '_fn = globals().get(' + JSON.stringify(fnName) + ')',
                    'if _fn is None:',
                    '    raise NameError(' + JSON.stringify(fnName) + ' + " not defined in solution notebook")',
                    '_args = _json.loads(' + JSON.stringify(argsJSON) + ')',
                    '_result = _fn(*_args)',
                    '_json.dumps(_result, default=str)'
                ].join('\n');
                var resJson = py.runPython(pyCode);
                return { ok: true, value: JSON.parse(resJson) };
            }).catch(function (err) {
                var msg = (err && err.message) ? String(err.message).split('\n').filter(function (l) { return l.trim(); }).pop() : String(err);
                return { ok: false, error: msg || 'error' };
            });
        }

        var _autoComputeTimer = null;
        var _autoComputeRow = null;

        function scheduleAutoCompute(row) {
            if (!row) return;
            _autoComputeRow = row;
            if (_autoComputeTimer) clearTimeout(_autoComputeTimer);
            _autoComputeTimer = setTimeout(function () {
                var r = _autoComputeRow; _autoComputeRow = null;
                autoComputeRow(r);
            }, 400);
        }

        function autoComputeRow(row) {
            if (!row || !row.parentElement) return;
            // Variable-equality families don't call a function — skip.
            if (kindInput && kindInput.value === 'variable_equality') return;
            var fnName = (fnInput.value || '').trim();
            if (!fnName) return;
            var paramNames = paramsInput.value.split(',').map(function (s) { return s.trim(); }).filter(Boolean);
            if (!paramNames.length) return;  // fallback JSON-args mode: no auto-compute

            var expectedEl = row.querySelector('.pf-case-expected');
            if (!expectedEl) return;
            if (expectedEl.dataset.manual === '1' && expectedEl.value.trim() !== '') return;

            var args = [];
            for (var i = 0; i < paramNames.length; i++) {
                var cell = row.querySelector('.pf-case-arg[data-arg-index="' + i + '"]');
                var raw = cell ? cell.value : '';
                if (raw.trim() === '') return;
                var paramTypeHint = currentParamTypes ? currentParamTypes[i] : null;
                args.push(coerceByType(raw, paramTypeHint));
            }

            expectedEl.placeholder = 'computing…';
            callSolution(fnName, args).then(function (res) {
                if (!row.parentElement) return;
                if (expectedEl.dataset.manual === '1' && expectedEl.value.trim() !== '') return;
                expectedEl.placeholder = 'e.g. underweight';
                if (res.ok) {
                    expectedEl.value = renderTypedCellValue(res.value);
                    expectedEl.dataset.autoComputed = '1';
                    expectedEl.title = 'Auto-computed from solution notebook';
                    expectedEl.style.color = 'var(--gray-500)';
                } else {
                    expectedEl.title = 'Solution raised: ' + res.error;
                }
            });
        }

        casesBody.addEventListener('input', function (e) {
            var t = e.target;
            if (!t || !t.classList) return;
            if (t.classList.contains('pf-case-arg')) {
                scheduleAutoCompute(t.closest('tr'));
            } else if (t.classList.contains('pf-case-expected')) {
                // User is editing the Expected cell directly — mark as
                // manual so auto-compute won't clobber.  If they clear it,
                // un-mark so the next arg change can refill.
                t.style.color = '';
                t.title = '';
                if (t.value.trim() === '') {
                    delete t.dataset.manual;
                    delete t.dataset.autoComputed;
                    scheduleAutoCompute(t.closest('tr'));
                } else {
                    t.dataset.manual = '1';
                    delete t.dataset.autoComputed;
                }
            }
        });

        // Suite table: handle Edit/Delete on family rows (script rows are
        // handled by the suite-table IIFE elsewhere on the page).
        var suiteBody = document.getElementById('suite-config-body');
        if (suiteBody) {
            suiteBody.addEventListener('click', function (e) {
                var editBtn = e.target && e.target.closest('.family-edit-btn');
                var delBtn  = e.target && e.target.closest('.family-delete-btn');
                if (editBtn) {
                    var fid = editBtn.getAttribute('data-family-id');
                    var idx = familiesState.findIndex(function (f) { return f.id === fid; });
                    if (idx >= 0) openEditor(idx);
                } else if (delBtn) {
                    var fid2 = delBtn.getAttribute('data-family-id');
                    var idx2 = familiesState.findIndex(function (f) { return f.id === fid2; });
                    if (idx2 < 0) return;
                    var family = familiesState[idx2];
                    var caseCount = (family.cases || []).length;
                    if (!confirm('Delete pattern family "' + family.name + '"? This removes '
                                 + caseCount + ' generated test script' + (caseCount === 1 ? '' : 's') + '.')) {
                        return;
                    }
                    var next = familiesState.slice();
                    next.splice(idx2, 1);
                    putFamilies(next)
                        .then(function (applied) { onFamiliesChange(applied); })
                        .catch(function () {});
                }
            });
        }

        saveBtn.addEventListener('click', function () {
            var family;
            try { family = readFamilyFromEditor(); }
            catch (e) { statusEl.textContent = e.message || String(e); return; }

            if (!family.functionName) { statusEl.textContent = 'Pick a function from the dropdown first.'; return; }
            if (!family.id) { statusEl.textContent = 'Family id could not be derived from the function name.'; return; }
            if (!family.name) { statusEl.textContent = 'Family name is required.'; return; }
            if (!family.cases.length) { statusEl.textContent = 'Add at least one case.'; return; }

            var next = familiesState.slice();
            if (editingIndex >= 0) {
                next[editingIndex] = family;
            } else {
                if (next.some(function (f) { return f.id === family.id; })) {
                    statusEl.textContent = 'A family for "' + family.functionName + '" already exists.';
                    return;
                }
                next.push(family);
            }
            putFamilies(next)
                .then(function (applied) {
                    onFamiliesChange(applied);
                    closeEditor();
                })
                .catch(function () {});
        });

        return {
            open: openEditor,
            close: closeEditor,
            getFamilies: function () { return familiesState.slice(); }
        };
    }

    function noopAPI() {
        return {
            open: function () {},
            close: function () {},
            getFamilies: function () { return []; }
        };
    }

    global.initPatternFamilyEditor = initPatternFamilyEditor;
})(window);
