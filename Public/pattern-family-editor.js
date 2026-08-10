// Chickadee — Pattern Family Editor
//
// Browser-side module that drives the pattern-family modal on the
// instructor assignment authoring pages.  Factored out of
// Resources/Views/assignment-edit.leaf in v0.4.90 so the edit and create
// pages render from a single copy instead of two copies that drift on
// every polish release.
//
// The form HTML lives in Resources/Views/_family-editor-body.leaf (included
// by both pages); this file owns every event listener, fetch, and piece
// of state that hangs off those DOM IDs.  DOM IDs are stable:
//   family-editor-body, family-editor-status, family-id, family-name,
//   family-kind, family-function, family-params, family-function-select,
//   family-function-hint, family-function-label,
//   family-default-hint, family-default-tolerance, family-tolerance-label,
//   family-cases-header, family-cases-body, family-cases-empty,
//   add-case-btn, family-section-name-label.
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
//           scanNotebook:     function () {...}  // POST /scan-notebook endpoint
//       }
//   })
//
// The module registers a body renderer on `window.ChickadeeTestRenderers
// .family` for the unified Test Editor modal (test-editor-modal.js); saves
// flow through `window.chickadeeSaveFamiliesViaSuite` (the single PUT /suite
// write path).  The shell (or the inline accordion editor) is the only entry
// point; the returned `{ getFamilies() }` exists for console debugging.

(function (global) {
    'use strict';

    function initPatternFamilyEditor(config) {
        config = config || {};
        var csrfToken       = config.csrfToken || '';
        var urls            = config.urls || {};

        if (typeof urls.solutionNotebook !== 'function'
         || typeof urls.scanNotebook     !== 'function') {
            throw new Error('initPatternFamilyEditor: urls must supply solutionNotebook + scanNotebook functions');
        }

        // ── The assignment's language ──────────────────────────────────────
        //
        // This module had NO notion of language at all: it validated Python
        // identifiers, accepted `True` / `False` / `None`, echoed Python reprs,
        // and named Python in the optional-argument placeholder — on R, Lua, Octave,
        // C++ and Racket assignments alike, while the server rendered the very
        // same family correctly in those languages. The generated test was
        // right and every hint given while authoring it was wrong.
        //
        // The facts come from `#assignment-language-seed`, written by
        // `AuthoringLanguageFacts` on the server. The literal spellings in
        // particular are COMPUTED there by `JSONValue.literal(_:)` — the same
        // call that renders the real test — so the editor cannot drift from
        // what will actually be generated. An assignment with no language (a
        // plain `.sh` suite), or a page that predates the seed, falls back to
        // Python's spellings, which is exactly today's behaviour.
        var languageFacts = ChickadeeLanguage.facts();

        // Why the last scan found nothing, when the reason is the language
        // rather than the solution. Null means the scan genuinely ran.
        //
        // This declaration was lost when the private language reader above was
        // replaced by the shared module, leaving three assignments to an
        // undeclared name — a ReferenceError under 'use strict', on every scan.
        // No test covered it; eslint's no-undef did.
        var scanUnsupportedReason = null;

        /// "R" / "Lua" / …, or "" when the assignment declares no language.
        function languageLabel() { return ChickadeeLanguage.label(); }

        // ── State ──────────────────────────────────────────────────────────
        var familiesState = Array.isArray(config.initialFamilies)
            ? config.initialFamilies.slice()
            : [];

        // Cached scan result.  Populated on first modal open, reused until the
        // page reloads.  Each entry has { name, paramNames, paramTypes,
        // returnType, paramCount, isShadowed }.
        var scannedFunctions = null;
        // Cached in-flight scan promise — concurrent callers share it instead
        // of spinning on a flag (old 50 ms setInterval poll).
        var scanPromise = null;

        // Section-level variables in scope for the family currently being
        // edited.  Refreshed from the DOM whenever the modal opens.  Used
        // to extend `$name` highlight / validation / auto-compute so a
        // family case can reference variables declared on its enclosing
        // section, not just its own family-scoped variables.  v0.4.100+.
        var currentSectionVariables = [];

        // Display name of the same section.  v0.4.111 switched the
        // dropdown filter from "functions used by tests in this
        // section" (filename-token match) to "functions defined under
        // the matching `## ` header in the solution notebook"
        // (scanner-emitted `sectionName` match).  The header-match
        // approach works for brand-new sections that don't yet have
        // any tests — the v0.4.108–110 token filter couldn't.
        var currentSectionName = null;
        // Tracks the kind currently shown in the editor so the kind-change
        // handler (and the "+ Add Test" preset path) can diff against the
        // previously-displayed kind when deciding whether to relay out the
        // cases columns.  Resynced on every open.
        var lastSelectedKind = 'boundary_equality';

        /// Reads section variables for the given family id out of the
        /// server-rendered `.section-vars-body` tbody in the family row's
        /// enclosing section block.  Returns `{ vars, sectionName }`.
        /// Picks up any unsaved edits to the Shared Inputs table too —
        /// auto-compute sees the live value the instructor just typed,
        /// same way family variables already work.
        function readSectionContextForFamily(familyID) {
            var familyRow = document.querySelector(
                'tr[data-kind="family"][data-family-id="' + String(familyID).replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"]'
            );
            if (!familyRow) return { vars: [], sectionName: null, sectionID: null };
            var block = familyRow.closest('.section-block[data-section-id]');
            if (!block) return { vars: [], sectionName: null, sectionID: null };
            var sectionID = block.getAttribute('data-section-id') || null;
            var sectionName = (block.querySelector('.section-header strong') || {}).textContent || null;
            var varTbody = block.querySelector('tbody.section-vars-body');
            if (!varTbody) return { vars: [], sectionName: sectionName, sectionID: sectionID };
            var vars = Array.from(varTbody.querySelectorAll('tr.section-var-row')).map(function (tr) {
                var name = (tr.querySelector('.section-var-name') || {}).value || '';
                var raw  = (tr.querySelector('.section-var-value') || {}).value || '';
                name = name.trim();
                if (!name) return null;
                var parsed;
                try { parsed = JSON.parse(raw.trim()); }
                catch (_) { parsed = String(raw); }
                return { name: name, value: parsed };
            }).filter(Boolean);
            return { vars: vars, sectionName: sectionName, sectionID: sectionID };
        }


        /// Reads section context by section id (rather than by family id).
        /// Used for the "+ New Family" path: the per-section toolbar
        /// stashes the target section on `window.__chickadeeTargetSection`
        /// before opening the modal, so we can show the inherited shared
        /// inputs even though the family hasn't been saved yet.
        /// v0.4.106+.
        function readSectionContextBySectionID(sectionID) {
            if (!sectionID) return { vars: [], sectionName: null, sectionID: null };
            var safe = String(sectionID).replace(/\\/g, '\\\\').replace(/"/g, '\\"');
            var block = document.querySelector('.section-block[data-section-id="' + safe + '"]');
            if (!block) return { vars: [], sectionName: null, sectionID: null };
            var sectionName = (block.querySelector('.section-header strong') || {}).textContent || null;
            var varTbody = block.querySelector('tbody.section-vars-body');
            if (!varTbody) return { vars: [], sectionName: sectionName, sectionID: sectionID };
            var vars = Array.from(varTbody.querySelectorAll('tr.section-var-row')).map(function (tr) {
                var name = (tr.querySelector('.section-var-name') || {}).value || '';
                var raw  = (tr.querySelector('.section-var-value') || {}).value || '';
                name = name.trim();
                if (!name) return null;
                var parsed;
                try { parsed = JSON.parse(raw.trim()); }
                catch (_) { parsed = String(raw); }
                return { name: name, value: parsed };
            }).filter(Boolean);
            return { vars: vars, sectionName: sectionName, sectionID: sectionID };
        }


        /// Paints the read-only "Shared inputs from section: X" block
        /// inside the family editor modal from the given context.
        /// Hides the block entirely when the family isn't in a section
        /// or the section has no variables declared.  Not editable
        /// here — instructor edits in the section's Inputs table
        /// (prevents accidental drift from tests in other families
        /// that rely on the same shared values).  v0.4.102+.
        /// v0.4.108: section vars are now rendered as locked rows at the
        /// top of the family Variables table (see `renderVariablesTable`).
        /// This function only updates the section-name label next to the
        /// table title — call sites pass `{ sectionName }` from the
        /// section-context lookup.  Kept as a function (not inlined)
        /// because both the new-family and existing-family branches in
        /// `openEditor` share it.
        function renderReadOnlySectionVars(ctx) {
            var label = document.getElementById('family-section-name-label');
            if (!label) return;
            var sectionName = (ctx && ctx.sectionName) || '';
            label.textContent = sectionName ? '— section: ' + sectionName : '';
        }

        // v0.4.238: the family form is a body renderer of the unified Test
        // Editor modal — its markup lives in `#family-editor-body` and the
        // shell owns the chrome (title / save / close).
        var bodyEl           = document.getElementById('family-editor-body');
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
        var statusEl         = document.getElementById('family-editor-status');

        if (!bodyEl) {
            // No family form rendered on this page — still return the API so
            // the host doesn't crash at init time, but all methods no-op.
            return noopAPI();
        }

        // Name the assignment's language in the variables table header.  The
        // static markup reads "Value (JSON or literal)" so the page is honest
        // before this runs; it said "Python literal" to R, Lua, Octave, C++ and
        // Racket authors, the same defect the "Python default" placeholder
        // below had — missed because this instance lives in Leaf, not here.
        (function () {
            var valueHeader = document.getElementById('family-variable-value-header');
            if (valueHeader && languageLabel()) {
                valueHeader.textContent = 'Value (JSON / ' + languageLabel() + ' literal)';
            }
        })();

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
        // Parallel to paramNames.  `true` means this parameter has a default
        // value in the signature (e.g. `currentDate: str = "..."`), which
        // lets the instructor leave the cell empty and have the renderer
        // omit the arg from the call so Python's own default binds.
        var currentParamHasDefault = [];
        var currentReturnType = null;

        // v0.4.94: in-memory family variables [{name, value}] displayed in
        // the Variables table above the Cases table.  Arg cells can
        // reference these by typing `$name` (mirrored by `argVarRefs` in
        // each saved case).  The table is separate from `cases` because
        // variables are family-wide, not case-scoped.
        var familyVariables = [];

        // Shared implementation (Public/chickadee-ui.js); local alias keeps
        // the many call sites short.
        var escHtml = ChickadeeUI.escapeHtml;

        // ── Solution-notebook scan ─────────────────────────────────────────

        /// Fetches the assignment's solution notebook and posts it to the
        /// scan-notebook endpoint.  Caches the result on `scannedFunctions`.
        function ensureScannedFunctions() {
            if (scannedFunctions !== null) return Promise.resolve(scannedFunctions);
            if (scanPromise) return scanPromise;
            scanPromise = fetch(urls.solutionNotebook(), {
                headers: { 'x-csrf-token': csrfToken }
            })
            .then(function (r) { return r.ok ? r.text() : Promise.reject('No solution notebook'); })
            .then(function (text) {
                // Tell the server which language to read. Without it the
                // endpoint falls back to the notebook's own kernelspec, which
                // is a better default than assuming Python but is not the
                // assignment's declared answer.
                var scanURL = urls.scanNotebook()
                    + (languageFacts.name
                        ? (urls.scanNotebook().indexOf('?') === -1 ? '?' : '&')
                          + 'language=' + encodeURIComponent(languageFacts.name)
                        : '');
                return fetch(scanURL, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json', 'x-csrf-token': csrfToken },
                    body: text
                });
            })
            .then(function (r) { return r.ok ? r.json() : Promise.reject('Scan failed'); })
            .then(function (payload) {
                // The response is an OBJECT now. It used to be a bare array,
                // which could only ever say "no functions" — the same answer
                // for an empty solution and for a language the scanner cannot
                // read. An array is still accepted so a cached older page does
                // not break.
                var read = readScanPayload(payload);
                scanUnsupportedReason = read.unsupportedReason;
                scannedFunctions = read.functions;
                return scannedFunctions;
            })
            .catch(function () { scannedFunctions = []; return []; });
            return scanPromise;
        }

        function populateFunctionSelect(selectedName) {
            if (!scannedFunctions || !scannedFunctions.length) {
                fnSelect.innerHTML = '<option value="">— No functions detected in solution —</option>';
                fnSelect.disabled = true;
                fnHint.textContent = 'Create or update the solution notebook so its top-level functions can be detected.';
                return;
            }
            // v0.4.111: filter the dropdown to functions defined under
            // the family's section in the solution notebook (each
            // scanned `def` carries the `##` header it was nested
            // under, emitted by `scanNotebookForSectionsAndFunctions`).
            // Match by section NAME — that's what the scanner knows;
            // the editor's section ID isn't visible to it.  Keeps the
            // currently-selected function in the dropdown even if it
            // happens to belong to a different header (defensive for
            // renamed sections).  Falls back to "show all" when:
            //   - the section name is unknown (e.g. Ungrouped block,
            //     or a fresh family before placement);
            //   - no scanned function matched this section name (the
            //     instructor renamed the section so it no longer
            //     matches a `##` header — better to show everything
            //     than block them).
            var allowed = null;
            if (currentSectionName) {
                allowed = new Set();
                scannedFunctions.forEach(function (fn) {
                    if (fn.sectionName === currentSectionName) allowed.add(fn.name);
                });
                if (allowed.size === 0) allowed = null;
            }
            if (allowed && selectedName) allowed.add(selectedName);
            // The message that was wrong for five of six languages: an R
            // author whose solution the scanner cannot read was shown the
            // same "no functions" state as an author with an empty solution,
            // and nothing distinguished them.
            if (scanUnsupportedReason) {
                fnSelect.disabled = true;
                fnHint.textContent = scanUnsupportedReason;
                fnSelect.innerHTML = '<option value="">\u2014 Enter the function name below \u2014</option>';
                return;
            }
            fnSelect.disabled = false;
            fnHint.textContent = allowed
                ? 'Showing functions defined under this section in the solution notebook.'
                : '';
            var options = ['<option value="">— Select a function —</option>'];
            scannedFunctions.forEach(function (fn) {
                if (allowed && !allowed.has(fn.name)) return;
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
            var scannedHasDefault = fn ? (fn.paramHasDefault || []) : [];
            currentParamTypes = paramNames.map(function (_, i) {
                return scannedTypes[i] != null ? scannedTypes[i] : null;
            });
            currentParamHasDefault = paramNames.map(function (_, i) {
                return scannedHasDefault[i] === true;
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
                var existing = readCasesFromTableRaw();
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
                    // scrolling back to the solution.  Optional (defaulted)
                    // params get a dimmed `?` suffix so the instructor
                    // knows they can be skipped.
                    var t  = currentParamTypes && currentParamTypes[i];
                    var hd = currentParamHasDefault && currentParamHasDefault[i];
                    var labelBase = t ? (escHtml(p) + ': ' + escHtml(t)) : escHtml(p);
                    var labelFull = hd
                        ? (labelBase + '<span style="color:var(--gray-500);font-weight:normal"> ?</span>')
                        : labelBase;
                    th.push('<th><code style="font-size:.7rem">' + labelFull + '</code></th>');
                });
            }
            var expectedHeader = currentReturnType
                ? 'Expected <code style="font-size:.7rem;font-weight:normal">: ' + escHtml(currentReturnType) + '</code>'
                : 'Expected';
            th.push('<th>' + expectedHeader + '</th>');
            th.push('<th>Hint <span style="color:var(--gray-500);font-weight:normal">(optional)</span></th>');
            th.push('<th style="width:4rem"></th>');
            casesHeader.innerHTML = th.join('');
        }

        // ── Cases table ────────────────────────────────────────────────────

        function updateCasesEmptyMessage() {
            casesEmpty.style.display = casesBody.children.length === 0 ? '' : 'none';
        }

        function addCaseRow(initial, paramNames) {
            paramNames = paramNames || [];
            var c = initial || { label: '', args: [], expected: null };
            var argsProvided = Array.isArray(c.argsProvided) ? c.argsProvided : [];
            var argVarRefs   = Array.isArray(c.argVarRefs)   ? c.argVarRefs   : [];
            var tds = [];
            // Column 1: auto-numbered sequence (readonly, regenerated on reorder).
            tds.push('<td class="pf-case-num" style="text-align:center;color:var(--gray-500);font-size:.75rem"></td>');
            tds.push('<td><input type="text" class="form-input pf-case-label" value="' + escHtml(c.label) + '" placeholder="e.g. bmi < 18.5 is underweight" style="width:100%;padding:.2rem .4rem;font-size:.8rem"></td>');

            if (!paramNames.length) {
                // No param names yet — single free-form JSON args field.
                tds.push('<td><input type="text" class="form-input pf-case-args" value="' + escHtml(JSON.stringify(c.args || [])) + '" placeholder="[18.49]" style="width:100%;padding:.2rem .4rem;font-size:.8rem;font-family:monospace"></td>');
            } else {
                paramNames.forEach(function (_, i) {
                    // Display precedence: variable reference (`$name`) > literal
                    // > blank (omitted / use the language's own default).
                    var varName = argVarRefs[i] || null;
                    var wasProvided = (argsProvided.length === 0) ? true : !!argsProvided[i];
                    var val;
                    if (varName) {
                        val = '$' + varName;
                    } else if (!wasProvided) {
                        val = '';
                    } else {
                        val = (c.args && c.args[i] !== undefined) ? renderTypedCellValue(c.args[i]) : '';
                    }
                    // Placeholder signals "— default —" for optional params,
                    // so the instructor can tell at a glance which cells
                    // can be left empty.
                    var hasDefault = currentParamHasDefault && currentParamHasDefault[i];
                    // Names the assignment's language rather than Python —
                    // this string was shown to R, Lua, Octave, C++ and Racket
                    // authors verbatim.
                    var defaultHint = languageLabel()
                        ? '\u2014 ' + languageLabel() + ' default \u2014'
                        : '\u2014 default \u2014';
                    var placeholder = hasDefault ? defaultHint : 'e.g. 18.49 or underweight';
                    tds.push('<td><input type="text" class="form-input pf-case-arg" data-arg-index="' + i + '" value="' + escHtml(val) + '" placeholder="' + escHtml(placeholder) + '" style="width:100%;padding:.2rem .4rem;font-size:.8rem;font-family:monospace"></td>');
                });
            }
            // Expected cell. Display precedence: per-student ref (`$name`,
            // resolved per student at grading time) > literal value.
            var expectedDisplay = c.expectedVarRef
                ? '$' + c.expectedVarRef
                : (c.expected == null ? '' : renderTypedCellValue(c.expected));
            tds.push('<td><input type="text" class="form-input pf-case-expected" value="' + escHtml(expectedDisplay) + '" placeholder="e.g. underweight or $expr" style="width:100%;padding:.2rem .4rem;font-size:.8rem;font-family:monospace"></td>');
            tds.push('<td><input type="text" class="form-input pf-case-hint" value="' + escHtml(c.hint || '') + '" placeholder="shown to students on failure" style="width:100%;padding:.2rem .4rem;font-size:.8rem"></td>');
            tds.push('<td><button type="button" class="btn action-btn action-danger pf-case-remove" style="padding:.2rem .4rem;font-size:.75rem">Remove</button></td>');

            var tr = document.createElement('tr');
            tr.innerHTML = tds.join('');
            casesBody.appendChild(tr);
            // Author-set expected values — a literal OR a per-student `$ref` —
            // are marked manual so the auto-computer doesn't overwrite them.
            var expCell = tr.querySelector('.pf-case-expected');
            if (expCell && expCell.value.trim() !== '') {
                expCell.dataset.manual = '1';
                refreshExpectedCellHighlight(expCell, collectDeclaredInputNames());
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

        // ── Family variables ────────────────────────────────────────────────
        //
        // Variables are family-scoped named values (lists, dicts, scalars)
        // that get prepended as module-level assignments to every generated
        // test in the family.  Editor UI lives above the Cases table; arg
        // cells reference them with `$name`.  v0.4.94; live-validation
        // and cross-wiring into the arg-cell highlighter + Pyodide
        // resolver added in v0.4.95.

        var variablesBody  = document.getElementById('family-variables-body');
        var variablesEmpty = document.getElementById('family-variables-empty');
        var addVariableBtn = document.getElementById('add-family-variable-btn');

        var PYTHON_KEYWORDS = new Set([
            'False','None','True','and','as','assert','async','await','break',
            'class','continue','def','del','elif','else','except','finally',
            'for','from','global','if','import','in','is','lambda','nonlocal',
            'not','or','pass','raise','return','try','while','with','yield'
        ]);

        /// Is `s` a name the SERVER will accept for a family variable or
        /// function?
        ///
        /// Still Python's grammar, deliberately, because that is what the
        /// server applies here: `PatternFamilyValidator` and the inputs
        /// services call `isValidPythonIdentifier` for every language. Widening
        /// the client alone would let a name through that the save then
        /// rejects, which is worse than the wording bug this fixes.
        ///
        /// (The server DOES have a per-language identifier dispatch —
        /// `isValidRIdentifier` and friends — but it is private to
        /// `NotebookCheckKindHandler` and reaches notebook checks only.
        /// Extending it to families is a real improvement and a real behaviour
        /// change: `my.df` would become a legal R variable name, and `$name`
        /// reference parsing has to be checked against a dot before that can
        /// ship. It is not a wording fix and is not bundled with one.)
        function isValidServerIdentifier(s) {
            if (!s) return false;
            if (PYTHON_KEYWORDS.has(s)) return false;
            return /^[A-Za-z_][A-Za-z0-9_]*$/.test(s);
        }

        /// Shared with the Global/Section Inputs editors — see
        /// Public/authoring-language.js for why these are not a local copy.
        function matchScalarToken(trimmed) {
            var hit = ChickadeeLanguage.matchScalarToken(trimmed);
            return hit ? { ok: true, value: hit.value, kind: hit.kind, strict: false } : null;
        }

        function languageReprToJSON(trimmed) { return ChickadeeLanguage.reprToJSON(trimmed); }

        /// Tries to parse `raw` the same way the server / renderer will:
        /// JSON first, then the language's own scalar spellings, then bare
        /// string.  Returns `{ ok, value, kind, strict }` where `strict` is true
        /// when `JSON.parse` succeeded (so the parse round-trips exactly)
        /// and false when we fell back to a bare string.  Used by the
        /// inline validator to distinguish "nice typed value" from
        /// "interpreting as a string literal" for the instructor.
        function tryParseVarValue(raw) {
            var trimmed = String(raw == null ? '' : raw).trim();
            if (trimmed === '') return { ok: false, value: undefined, kind: 'empty', strict: false };
            var scalar = matchScalarToken(trimmed);
            if (scalar) return scalar;
            try {
                var v = JSON.parse(trimmed);
                var kind =
                    Array.isArray(v) ? 'list' :
                    (v === null) ? 'null' :
                    (typeof v === 'object') ? 'dict' :
                    (typeof v === 'boolean') ? 'bool' :
                    (typeof v === 'number') ? 'number' :
                    (typeof v === 'string') ? 'string' : 'scalar';
                return { ok: true, value: v, kind: kind, strict: true };
            } catch (_) {
                // v0.4.112: language-repr fallback for variables (matches
                // the same conversion in coerceByType).  Pasting a
                // dict like `{'address': {'city': 'Waterloo'}}` into a
                // section's input value should Just Work — in whichever
                // language the assignment is written.
                if (trimmed.indexOf('"') === -1) {
                    var pyish = languageReprToJSON(trimmed);
                    try {
                        var v2 = JSON.parse(pyish);
                        var k2 =
                            Array.isArray(v2) ? 'list' :
                            (v2 === null) ? 'null' :
                            (typeof v2 === 'object') ? 'dict' :
                            (typeof v2 === 'boolean') ? 'bool' :
                            (typeof v2 === 'number') ? 'number' :
                            (typeof v2 === 'string') ? 'string' : 'scalar';
                        return { ok: true, value: v2, kind: k2, strict: false };
                    } catch (_) { /* fall through */ }
                }
                return { ok: true, value: String(raw), kind: 'string', strict: false };
            }
        }

        function renderVariablesTable() {
            if (!variablesBody) return;
            variablesBody.innerHTML = '';
            // v0.4.108: section-level shared inputs render as locked
            // rows at the top of the family Variables table — read-
            // only `<code>`s in place of inputs, with no per-row
            // chrome (no 🔒 icon, no "from section" label — the
            // section name in the table title is sufficient context;
            // v0.4.109 stripped both).  Family-level rows with the
            // same name shadow at render time, so we mark shadowed
            // section rows with a strike-through and an inline amber
            // note so the instructor sees which value the test will
            // actually use.
            (currentSectionVariables || []).forEach(function (v) {
                var familyShadow = familyVariables.some(function (fv) {
                    return fv.name && fv.name.trim() === v.name;
                });
                var tr = document.createElement('tr');
                tr.className = 'pf-var-section-row';
                tr.setAttribute('data-section-var', '1');
                var preview = '';
                try { preview = JSON.stringify(v.value); }
                catch (_) { preview = String(v.value); }
                var textDeco = familyShadow ? 'line-through' : 'none';
                var shadowNote = familyShadow
                    ? '<span class="card-meta" style="font-size:.7rem;color:var(--amber);margin-left:.4rem">shadowed by family variable below</span>'
                    : '';
                tr.innerHTML =
                    '<td></td>'
                  + '<td style="vertical-align:top;padding:.3rem .4rem"><code style="font-family:monospace;font-size:.8rem;text-decoration:' + textDeco + '">' + escHtml(v.name) + '</code>' + shadowNote + '</td>'
                  + '<td style="vertical-align:top;padding:.3rem .4rem;font-family:monospace;font-size:.78rem;color:var(--gray-600);text-decoration:' + textDeco + '">' + escHtml(preview) + '</td>'
                  + '<td></td>';
                variablesBody.appendChild(tr);
            });
            familyVariables.forEach(function (v, i) {
                var tr = document.createElement('tr');
                tr.setAttribute('data-var-index', String(i));
                tr.innerHTML =
                    // Row-level valid indicator — empty until both name
                    // and value pass their checks.  Replaces the v0.4.94
                    // "✓ referenced as $name" / "✓ parsed as dict" text
                    // lines beneath each input.
                    '<td class="pf-var-row-valid" style="vertical-align:middle;text-align:center;color:var(--green);font-size:1rem"></td>'
                  + '<td style="vertical-align:top">'
                  +   '<input type="text" class="form-input pf-var-name" data-var-index="' + i + '" value="' + escHtml(v.name || '') + '" placeholder="e.g. patient_database" style="width:100%;padding:.2rem .4rem;font-size:.8rem;font-family:monospace">'
                  + '</td>'
                  + '<td style="vertical-align:top">'
                  +   '<input type="text" class="form-input pf-var-value" data-var-index="' + i + '" value="' + escHtml(v.value == null ? '' : JSON.stringify(v.value)) + '" placeholder="{&quot;p01&quot;: {...}} or [1, 2, 3]" style="width:100%;padding:.2rem .4rem;font-size:.8rem;font-family:monospace">'
                  + '</td>'
                  + '<td style="vertical-align:top"><button type="button" class="btn action-btn action-danger pf-var-remove" data-var-index="' + i + '" style="padding:.2rem .4rem;font-size:.75rem">Remove</button></td>';
                variablesBody.appendChild(tr);
                refreshVarRowStatus(tr);
            });
            if (variablesEmpty) {
                variablesEmpty.style.display = familyVariables.length ? 'none' : '';
            }
            // Variable set may have changed → refresh every arg cell's
            // `$name` highlighting so broken refs show up immediately.
            refreshAllArgCellVarHighlighting();
        }

        /// Paint a single variable row's validation state.  Instead of the
        /// v0.4.94 verbose text lines beneath each input, v0.4.100
        /// collapses the row into a single green "✓" in the leading
        /// column when both name and value are fully valid, plus a red
        /// outline on whichever input is wrong.  The row stays quiet
        /// until something's typed — no placeholder noise.
        function refreshVarRowStatus(row) {
            if (!row) return;
            var nameEl   = row.querySelector('.pf-var-name');
            var valueEl  = row.querySelector('.pf-var-value');
            var validEl  = row.querySelector('.pf-var-row-valid');
            if (!nameEl || !valueEl || !validEl) return;

            var name   = nameEl.value.trim();
            var rawVal = valueEl.value;

            // Name validity.
            var nameOk = false;
            var nameError = null;
            if (!name) {
                // Empty row — silent, not an error.
                nameEl.style.borderColor = '';
            } else if (!isValidServerIdentifier(name)) {
                nameError = 'Use letters, digits and underscores, starting with a letter or underscore.';
            } else {
                var allNames = Array.from(variablesBody.querySelectorAll('.pf-var-name'))
                    .map(function (el) { return el.value.trim(); });
                var dup = allNames.filter(function (n) { return n === name; }).length > 1;
                if (dup) {
                    nameError = 'Duplicate — each variable needs a unique name.';
                } else {
                    nameOk = true;
                }
            }
            nameEl.style.borderColor = nameError ? 'var(--red)' : '';
            nameEl.title = nameError || '';

            // Value validity.
            var parsed = tryParseVarValue(rawVal);
            var valueOk = false;
            var valueError = null;
            if (parsed.kind === 'empty') {
                valueEl.style.borderColor = '';  // silent until typed
            } else if (parsed.strict) {
                valueOk = true;
                valueEl.style.borderColor = '';
            } else {
                // Bare-string fallback — almost always a typo in dict/list JSON.
                valueError = 'Treated as a bare string. Wrap in quotes for a JSON string, or check the syntax for list/dict.';
                valueEl.style.borderColor = 'var(--amber)';
            }
            valueEl.title = valueError || (valueOk ? 'Parsed as ' + parsed.kind : '');

            // Row-level checkmark: only when BOTH are valid.
            validEl.textContent = (nameOk && valueOk) ? '✓' : '';
        }

        /// Paint every case-table arg cell to reflect whether its
        /// current text resolves to a declared variable.  Green = valid
        /// ref, red = `$name` with no matching variable, default styling
        /// for plain literals / empty cells.  Cheap enough to run on
        /// every keystroke.
        /// Names a `$name` ref (in an arg cell or the Expected cell) may
        /// resolve to: family variables, the family's section variables, and
        /// assignment-scope Global Inputs — literal values AND `=` per-student
        /// expressions alike (both carry a name in the Global Inputs panel).
        /// The strict per-student-vs-literal + kind checks run server-side; the
        /// editor only needs "is this name declared anywhere" so it doesn't
        /// red-flag a valid per-student ref.
        function collectDeclaredInputNames() {
            var names = new Set();
            Array.from(variablesBody ? variablesBody.querySelectorAll('.pf-var-name') : []).forEach(function (el) {
                var n = (el.value || '').trim();
                if (n && isValidServerIdentifier(n)) names.add(n);
            });
            (currentSectionVariables || []).forEach(function (v) {
                if (v && v.name && isValidServerIdentifier(v.name)) names.add(v.name);
            });
            Array.from(document.querySelectorAll('.global-input-name')).forEach(function (el) {
                var n = (el.value || '').trim();
                if (n && isValidServerIdentifier(n)) names.add(n);
            });
            return names;
        }

        function refreshAllArgCellVarHighlighting() {
            var declaredVarNames = collectDeclaredInputNames();
            Array.from(casesBody ? casesBody.querySelectorAll('.pf-case-arg') : []).forEach(function (cell) {
                refreshArgCellHighlight(cell, declaredVarNames);
            });
            Array.from(casesBody ? casesBody.querySelectorAll('.pf-case-expected') : []).forEach(function (cell) {
                refreshExpectedCellHighlight(cell, declaredVarNames);
            });
        }

        function refreshArgCellHighlight(cell, declaredNames) {
            var raw = (cell.value || '').trim();
            var match = raw.match(/^\$([A-Za-z_][A-Za-z0-9_]*)$/);
            cell.style.fontStyle = '';
            cell.style.color = '';
            cell.style.borderColor = '';
            cell.title = '';
            if (!match) return;
            var name = match[1];
            if (declaredNames && declaredNames.has(name)) {
                cell.style.fontStyle = 'italic';
                cell.style.color = 'var(--green)';
                cell.title = 'Bound to input $' + name;
            } else {
                cell.style.color = 'var(--red)';
                cell.style.borderColor = 'var(--red)';
                cell.title = 'No input named $' + name + ' is declared (Variables table or Global Inputs).';
            }
        }

        /// Highlight for the Expected cell.  A `$name` ref gets the green/red
        /// treatment (per-student expected); a non-ref literal is left alone so
        /// it keeps any auto-compute / manual styling rather than being cleared
        /// when an unrelated keystroke triggers a bulk refresh.
        function refreshExpectedCellHighlight(cell, declaredNames) {
            var raw = (cell.value || '').trim();
            var match = raw.match(/^\$([A-Za-z_][A-Za-z0-9_]*)$/);
            if (!match) {
                cell.style.fontStyle = '';
                cell.style.borderColor = '';
                return;  // leave color/title to auto-compute / manual styling
            }
            var name = match[1];
            cell.style.fontStyle = 'italic';
            if (declaredNames && declaredNames.has(name)) {
                cell.style.color = 'var(--green)';
                cell.style.borderColor = '';
                cell.title = '$' + name + ' — per-student expected (resolved at grading time)';
            } else {
                cell.style.color = 'var(--red)';
                cell.style.borderColor = 'var(--red)';
                cell.title = 'No input named $' + name + ' is declared (Variables table or Global Inputs).';
            }
        }

        /// Reads the Variables-table inputs back into `familyVariables`
        /// (call before `readFamilyFromEditor` so the two stay in sync).
        /// Strict mode: throws on empty/invalid rows.  Non-strict: tries
        /// to preserve what it can so live-edit flows don't clobber
        /// partial state.
        function syncFamilyVariablesFromTable(opts) {
            opts = opts || {};
            if (!variablesBody) return;
            var rows = Array.from(variablesBody.querySelectorAll('tr'));
            var out = [];
            rows.forEach(function (row, i) {
                var nameEl  = row.querySelector('.pf-var-name');
                var valueEl = row.querySelector('.pf-var-value');
                var name    = (nameEl  ? nameEl.value  : '').trim();
                var rawVal  = (valueEl ? valueEl.value : '').trim();
                if (!name && !rawVal) return; // empty row — drop silently
                if (!name) {
                    if (opts.strict) throw new Error('Variable row ' + (i + 1) + ': name is required.');
                    return;
                }
                if (opts.strict && !isValidServerIdentifier(name)) {
                    throw new Error('Variable "' + name + '": use letters, digits and underscores, '
                        + 'starting with a letter or underscore.');
                }
                if (rawVal === '') {
                    if (opts.strict) throw new Error('Variable "' + name + '": value is required.');
                    return;
                }
                var parsed = tryParseVarValue(rawVal);
                out.push({ name: name, value: parsed.value });
            });
            // Duplicate-name check mirrors server-side validation.
            if (opts.strict) {
                var seen = new Set();
                for (var j = 0; j < out.length; j++) {
                    if (seen.has(out[j].name)) {
                        throw new Error('Duplicate variable name: "' + out[j].name + '". Each variable needs a unique name.');
                    }
                    seen.add(out[j].name);
                }
            }
            familyVariables = out;
        }

        if (addVariableBtn) {
            addVariableBtn.addEventListener('click', function () {
                // Pull any edits from the DOM first so we don't clobber
                // in-progress typing when we re-render.
                try { syncFamilyVariablesFromTable({ strict: false }); } catch (_) {}
                familyVariables.push({ name: '', value: null });
                renderVariablesTable();
                // Focus the new row's name input.
                var rows = variablesBody ? variablesBody.querySelectorAll('tr') : [];
                var last = rows[rows.length - 1];
                if (last) {
                    var nameInputNew = last.querySelector('.pf-var-name');
                    if (nameInputNew) nameInputNew.focus();
                }
            });
        }
        if (variablesBody) {
            variablesBody.addEventListener('click', function (e) {
                var btn = e.target && e.target.closest('.pf-var-remove');
                if (!btn) return;
                // Sync first so the other rows' in-progress edits don't
                // disappear when we drop this one.
                try { syncFamilyVariablesFromTable({ strict: false }); } catch (_) {}
                var idx = parseInt(btn.getAttribute('data-var-index'), 10);
                if (isFinite(idx) && idx >= 0 && idx < familyVariables.length) {
                    familyVariables.splice(idx, 1);
                    renderVariablesTable();
                }
            });
            // Live validation: every keystroke refreshes the row's two
            // status lines + re-highlights every arg cell so a rename or
            // typo-fix in a variable is visible immediately.  Also
            // re-schedules auto-compute for every case row that
            // references a variable — when the instructor finishes
            // typing the variable's value, the Expected column for
            // `$name` cells picks up the resolution automatically.
            variablesBody.addEventListener('input', function (e) {
                var row = e.target && e.target.closest('tr[data-var-index]');
                if (!row) return;
                refreshVarRowStatus(row);
                refreshAllArgCellVarHighlighting();
                rescheduleAutoComputeForVariableRefCases();
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
                        // v0.4.112: a value pasted in the assignment's own
                        // syntax (single-quoted strings, the language's
                        // true/false/null spellings) is a common copy-paste
                        // source — rewrite it to JSON conservatively.
                        if (trimmed.indexOf('"') === -1) {
                            try {
                                return JSON.parse(languageReprToJSON(trimmed));
                            } catch (_) { /* fall through */ }
                        }
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
            if (typeof v === 'string') {
                // Single-line `<input type="text">` silently strips
                // newlines / carriage returns on `.value` assignment,
                // mangling multi-line expected values (e.g. the
                // `mailingLabel` case from Assignment 3 returns a
                // three-line string joined by `\n`).  When the string
                // contains a control char that wouldn't survive the
                // input, render as a JSON-quoted string so the escape
                // sequences are literal text in the cell and the
                // round-trip through `coerceByType` reconstructs the
                // real value.  Plain strings stay unquoted so the
                // common case reads naturally.
                if (/[\n\r\t]/.test(v)) return JSON.stringify(v);
                return v;
            }
            return JSON.stringify(v);
        }

        /// Reads current rows into PatternCase values.  Strict JSON is only
        /// required for the fallback single-args field (when no parameters
        /// are detected); per-column cells accept bare values.  Throws with
        /// a readable message on required-field or structural failures.
        ///
        /// Per v0.4.94, each arg cell may hold one of three things:
        ///   1. A literal value (e.g. `20260422`, `"underweight"`) — parsed
        ///      via `coerceByType` using the scanner-reported type hint.
        ///   2. A variable reference `$name` — resolves at render time to
        ///      the bare identifier `name` in the generated test.  Must
        ///      match a declared family variable; validation rejects
        ///      dangling refs.
        ///   3. Empty — only allowed when the scanner reported the param
        ///      has a default value (`paramHasDefault[i]`), in which case
        ///      the renderer omits the arg from the call and Python's
        ///      default value applies.
        function readCasesFromTable(paramNames) {
            paramNames = paramNames || [];
            // Names a `$name` ref (arg or expected) may resolve to: family +
            // section variables AND assignment-scope Global Inputs / `=`
            // expressions.  The server does the strict per-student-vs-literal +
            // kind checks at save; here we only reject names declared nowhere.
            var declaredVarNames = collectDeclaredInputNames();
            var rows = Array.from(casesBody.querySelectorAll('tr'));
            var out = [];
            for (var i = 0; i < rows.length; i++) {
                var row = rows[i];
                var label = row.querySelector('.pf-case-label').value.trim();
                var rawExp = row.querySelector('.pf-case-expected').value;
                if (rawExp.trim() === '') rawExp = '';
                var caseNum = (i + 1 < 10 ? '0' + (i + 1) : String(i + 1));
                var args = [];
                var argsProvided = [];
                var argVarRefs   = [];
                if (paramNames.length === 0) {
                    var rawArgs = (row.querySelector('.pf-case-args') || {}).value || '';
                    rawArgs = rawArgs.trim();
                    if (rawArgs !== '') {
                        try { args = JSON.parse(rawArgs); }
                        catch (e) { throw new Error('Case ' + caseNum + ': args must be valid JSON (' + e.message + ')'); }
                        if (!Array.isArray(args)) throw new Error('Case ' + caseNum + ': args must be a JSON array');
                    }
                    argsProvided = args.map(function () { return true; });
                    argVarRefs   = args.map(function () { return null; });
                } else {
                    for (var a = 0; a < paramNames.length; a++) {
                        var cell = row.querySelector('.pf-case-arg[data-arg-index="' + a + '"]');
                        var raw = cell ? cell.value : '';
                        var trimmed = raw.trim();
                        var paramTypeHint = currentParamTypes ? currentParamTypes[a] : null;
                        if (trimmed === '') {
                            // Empty cell: allowed only if the scanner saw a default.
                            var hasDefault = currentParamHasDefault && currentParamHasDefault[a];
                            if (!hasDefault) {
                                throw new Error('Case ' + caseNum + ': missing value for "' + paramNames[a] + '"');
                            }
                            args.push(null);                   // placeholder; renderer ignores
                            argsProvided.push(false);
                            argVarRefs.push(null);
                            continue;
                        }
                        // Variable reference: `$ident` (not `$"...$"` quoted).
                        var varMatch = trimmed.match(/^\$([A-Za-z_][A-Za-z0-9_]*)$/);
                        if (varMatch) {
                            var varName = varMatch[1];
                            if (!declaredVarNames.has(varName)) {
                                throw new Error('Case ' + caseNum + ': "' + paramNames[a] + '" references unknown variable "$' + varName + '" — declare it in the Variables table.');
                            }
                            args.push(null);                   // placeholder; renderer uses the ref
                            argsProvided.push(true);
                            argVarRefs.push(varName);
                            continue;
                        }
                        // Literal: coerce by type hint.
                        args.push(coerceByType(raw, paramTypeHint));
                        argsProvided.push(true);
                        argVarRefs.push(null);
                    }
                }
                var expected;
                var expectedVarRef = null;
                // stdout_equality permits an empty Expected — that's the
                // legitimate "this function should print nothing" case.
                // For all other kinds an empty cell is still an error.
                var allowEmptyExpected = (kindInput && kindInput.value === 'stdout_equality');
                if (rawExp === '' && !allowEmptyExpected) throw new Error('Case ' + caseNum + ': expected value is required');
                if (rawExp === '') {
                    expected = '';
                } else {
                    // Per-student expected: `$name` references a declared input
                    // (a global/section `=` expression), resolved per student at
                    // grading time — mirrors arg-cell refs.
                    var expRefMatch = rawExp.trim().match(/^\$([A-Za-z_][A-Za-z0-9_]*)$/);
                    if (expRefMatch) {
                        var expRefName = expRefMatch[1];
                        if (!declaredVarNames.has(expRefName)) {
                            throw new Error('Case ' + caseNum + ': expected references unknown variable "$' + expRefName + '" — declare it in the Variables table or Global Inputs.');
                        }
                        expectedVarRef = expRefName;
                        expected = null;   // placeholder; renderer uses the ref
                    } else {
                        expected = coerceByType(rawExp, currentReturnType);
                    }
                }
                if (!label) throw new Error('Case ' + caseNum + ': label is required');
                var hintCell = row.querySelector('.pf-case-hint');
                var hint = hintCell ? hintCell.value.trim() : '';
                var caseObj = {
                    key: caseNum,
                    label: label,
                    args: args,
                    argsProvided: argsProvided,
                    argVarRefs: argVarRefs,
                    expected: expected,
                    enabled: true
                };
                if (expectedVarRef) caseObj.expectedVarRef = expectedVarRef;
                if (hint) caseObj.hint = hint;   // omit when blank to keep the manifest clean
                out.push(caseObj);
            }
            return out;
        }

        /// Lossy read used when switching between function selections —
        /// preserves what we can but doesn't throw on parse errors.  Uses
        /// the same type-aware coercion as the strict save path so bare
        /// strings (like `"underweight"`) round-trip without being
        /// nullified by strict `JSON.parse`.  Also preserves variable
        /// references (`$name`) and "omitted" state across a header
        /// rebuild so the instructor doesn't silently lose data when
        /// adding a case, changing tolerance, etc.
        function readCasesFromTableRaw() {
            var rows = Array.from(casesBody.querySelectorAll('tr'));
            return rows.map(function (row) {
                var label = row.querySelector('.pf-case-label').value;
                var rawExp = row.querySelector('.pf-case-expected').value;
                var args = [];
                var argsProvided = [];
                var argVarRefs   = [];
                var cells = row.querySelectorAll('.pf-case-arg');
                if (cells.length) {
                    Array.from(cells).forEach(function (c, idx) {
                        var raw = c.value;
                        if (String(raw).trim() === '') {
                            args.push(null);
                            argsProvided.push(false);
                            argVarRefs.push(null);
                            return;
                        }
                        var varMatch = String(raw).trim().match(/^\$([A-Za-z_][A-Za-z0-9_]*)$/);
                        if (varMatch) {
                            args.push(null);
                            argsProvided.push(true);
                            argVarRefs.push(varMatch[1]);
                            return;
                        }
                        var typeHint = currentParamTypes ? currentParamTypes[idx] : null;
                        args.push(coerceByType(raw, typeHint));
                        argsProvided.push(true);
                        argVarRefs.push(null);
                    });
                } else {
                    var single = row.querySelector('.pf-case-args');
                    if (single) {
                        try { args = JSON.parse(single.value); if (!Array.isArray(args)) args = []; } catch (_) { args = []; }
                        argsProvided = args.map(function () { return true; });
                        argVarRefs   = args.map(function () { return null; });
                    }
                }
                // Preserve a per-student `$name` Expected ref across header
                // rebuilds (lossy read — no validation here, mirrors arg refs).
                var expected = null;
                var expectedVarRef = null;
                var rawExpTrim = rawExp.trim();
                var expRefMatch = rawExpTrim.match(/^\$([A-Za-z_][A-Za-z0-9_]*)$/);
                if (expRefMatch) {
                    expectedVarRef = expRefMatch[1];
                } else if (rawExpTrim !== '') {
                    expected = coerceByType(rawExp, currentReturnType);
                }
                var hintCell = row.querySelector('.pf-case-hint');
                var hint = hintCell ? hintCell.value.trim() : '';
                var obj = {
                    label: label,
                    args: args,
                    argsProvided: argsProvided,
                    argVarRefs: argVarRefs,
                    expected: expected
                };
                if (expectedVarRef) obj.expectedVarRef = expectedVarRef;
                if (hint) obj.hint = hint;   // preserve across header rebuilds
                return obj;
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

        // `presetKind` (optional) seeds the kind dropdown for a brand-new
        // family — used by the unified "+ Add Test" dispatcher.  Ignored
        // when editing an existing family.
        function openEditor(familyIdx, presetKind) {
            editingIndex = (typeof familyIdx === 'number') ? familyIdx : -1;
            statusEl.textContent = '';
            casesBody.innerHTML = '';

            // Grab the section variables in scope for the family we're
            // about to edit (editing an existing family).  For a new
            // family (+ New Family button), currentSectionVariables stays
            // empty — the family isn't placed in any section until the
            // user saves and drags it into one.
            var preselectedFn = '';
            if (editingIndex >= 0) {
                var family = familiesState[editingIndex];
                var ctx = readSectionContextForFamily(family.id);
                currentSectionVariables = ctx.vars;
                currentSectionName = ctx.sectionName;
                renderReadOnlySectionVars(ctx);
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
                familyVariables = Array.isArray(family.variables)
                    ? family.variables.map(function (v) { return { name: v.name, value: v.value }; })
                    : [];
                rebuildCasesHeader(family.paramNames || []);
                (family.cases || []).forEach(function (c) { addCaseRow(c, family.paramNames || []); });
                if (!(family.cases || []).length) addCaseRow(null, family.paramNames || []);
            } else {
                idInput.value = '';
                nameInput.value = '';
                kindInput.value = presetKind || 'boundary_equality';
                fnInput.value = '';
                paramsInput.value = '';
                editingTier = 'public';
                editingPoints = 1;
                defaultHintInput.value = '';
                toleranceInput.value = '';
                familyVariables = [];
                // New family: pull section context from the per-section
                // "+ New Family" toolbar's stashed target id (set in
                // assignment-edit.leaf's IIFE before the global button
                // is click()ed).  v0.4.106 — previously this branch
                // unconditionally cleared the read-only block, so a
                // section's $patients-style shared input wasn't visible
                // and `$patients` refs in arg cells couldn't auto-
                // compute Expected.  When opened from the global "+
                // New Family" button (`__chickadeeTargetSection` empty
                // / unset), we still emit the empty-context render so
                // the block hides cleanly.
                var targetSid = window.__chickadeeTargetSection || '';
                var newCtx = readSectionContextBySectionID(targetSid);
                currentSectionVariables = newCtx.vars;
                currentSectionName = newCtx.sectionName;
                renderReadOnlySectionVars(newCtx);
                rebuildCasesHeader([]);
            }
            renderVariablesTable();
            updateKindVisibility();

            // A new family seeded with a non-default kind (via "+ Add Test")
            // may need its cases columns laid out differently — only
            // variable-equality changes the layout, and applyKindDefaults
            // is a no-op for the kinds that share boundary's columns.
            if (editingIndex < 0) {
                applyKindDefaults(kindInput.value, 'boundary_equality');
            }
            // Resync the kind-change tracker to what's actually shown so the
            // next user-driven change diffs against the right baseline.
            lastSelectedKind = kindInput.value;

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

        function readFamilyFromEditor() {
            // Pull Variables-table edits first; readCasesFromTable checks
            // `$name` refs against the synced `familyVariables` list.
            syncFamilyVariablesFromTable({ strict: true });
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
            // Carry forward the existing family-level dependsOn when
            // editing (the modal doesn't expose it).  Without this, every
            // modal save wipes any prerequisites the instructor set on the
            // family via the suite-table row — which would cause the
            // generated cases to lose their inherited deps on the next
            // apply.
            var existingDependsOn = [];
            if (editingIndex >= 0 && familiesState[editingIndex]
                && Array.isArray(familiesState[editingIndex].dependsOn)) {
                existingDependsOn = familiesState[editingIndex].dependsOn.slice();
            }
            return {
                id: idInput.value.trim(),
                name: nameInput.value.trim(),
                kind: kind,
                functionName: fnInput.value.trim(),
                paramNames: paramNames,
                defaults: defaults,
                cases: cases,
                variables: familyVariables.slice(),
                dependsOn: existingDependsOn
            };
        }

        /// Persists the full family list through the single `PUT /suite` write
        /// path (`window.chickadeeSaveFamiliesViaSuite`): the suite-table
        /// reconciles itself and re-seeds from the response.  Rejects if the
        /// save hook isn't present (a page without the suite table).
        function persistFamilies(next) {
            statusEl.textContent = 'Saving…';
            if (typeof window.chickadeeSaveFamiliesViaSuite !== 'function') {
                return Promise.reject(new Error('suite table not ready'));
            }
            return window.chickadeeSaveFamiliesViaSuite(next)
                .then(function (applied) {
                    familiesState = applied;
                    statusEl.textContent = '';
                    return applied;
                })
                .catch(function (err) {
                    statusEl.textContent = 'Error: ' + (err && err.message ? err.message : err);
                    throw err;
                });
        }

        // ── Event wiring ───────────────────────────────────────────────────

        if (fnSelect) fnSelect.addEventListener('change', function () {
            applyFunctionSelection(fnSelect.value, /*preserveCases=*/true);
        });

        if (kindInput) {
            kindInput.addEventListener('change', function () {
                var newKind = kindInput.value;
                applyKindDefaults(newKind, lastSelectedKind);
                lastSelectedKind = newKind;
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
        //
        // v0.4.135: the interpreter runs in a Web Worker (`/python-eval-worker.js`)
        // instead of on the main thread.  Synchronous tight loops in the
        // instructor's solution notebook (`while True: pass`, infinite
        // recursion) used to freeze the editor modal and the rest of the
        // page because `runPythonAsync` only yields at `await` boundaries
        // — the 5-second timeout fired but the main thread was already
        // blocked.  In a worker we can `terminate()` the worker mid-run,
        // unblocking the UI, and allocate a fresh worker for the next
        // call.  The first call after a kill pays the ~5s Pyodide reload
        // cost again.
        var _solutionLoadedPromise = null;
        var _worker = null;
        var _nextRequestId = 1;
        var _pendingRequests = new Map();

        // Hard cap on how long we wait for the solution function to return.
        // After v0.4.135 this enforces a true wall-clock limit (worker is
        // terminated on timeout) instead of just catching cooperative hangs.
        var TIMEOUT_MS = 5000;
        // Longer cap for the one-time solution-notebook load (importing
        // heavy modules, reading a CSV, etc.).  Bounded so a top-level
        // infinite loop in a setup cell can't strand auto-compute on
        // "computing…" forever.
        var LOAD_TIMEOUT_MS = 30000;

        function getWorker() {
            if (_worker) return _worker;
            var version = (document.querySelector('meta[name="app-version"]') || {}).content || '';
            var workerURL = '/python-eval-worker.js' + (version ? '?v=' + encodeURIComponent(version) : '');
            _worker = new Worker(workerURL);
            _worker.addEventListener('message', function (e) {
                var data = e.data || {};
                var handler = _pendingRequests.get(data.id);
                if (handler) {
                    _pendingRequests.delete(data.id);
                    handler(data);
                }
            });
            _worker.addEventListener('error', function (e) {
                // Surface uncaught worker errors to every pending request
                // so the modal doesn't sit forever.  The next call spins
                // up a fresh worker.
                var err = (e && e.message) ? e.message : 'worker error';
                _pendingRequests.forEach(function (handler) {
                    handler({ ok: false, error: err });
                });
                _pendingRequests.clear();
                killWorker();
            });
            return _worker;
        }

        function killWorker() {
            if (_worker) {
                try { _worker.terminate(); } catch (_) {}
                _worker = null;
            }
            // The worker held the loaded solution module; the next call
            // must re-load it.
            _solutionLoadedPromise = null;
        }

        /// Sends a message to the Pyodide worker, optionally with a
        /// wall-clock timeout.  When the timeout fires we terminate the
        /// worker (killing whatever Python is running, including
        /// synchronous tight loops) and reject with `__chickadee_timeout__`.
        /// Pending requests on the killed worker are also rejected so
        /// concurrent in-flight calls don't hang.
        function workerSend(message, timeoutMs) {
            return new Promise(function (resolve, reject) {
                var id = _nextRequestId++;
                var worker = getWorker();
                var timer = null;
                if (timeoutMs && timeoutMs > 0) {
                    timer = setTimeout(function () {
                        _pendingRequests.delete(id);
                        killWorker();
                        reject(new Error('__chickadee_timeout__'));
                    }, timeoutMs);
                }
                _pendingRequests.set(id, function (data) {
                    if (timer) { clearTimeout(timer); }
                    if (data.ok) {
                        resolve(data);
                    } else {
                        reject(new Error(data.error || 'unknown error'));
                    }
                });
                try {
                    var payload = Object.assign({ id: id }, message);
                    worker.postMessage(payload);
                } catch (err) {
                    if (timer) { clearTimeout(timer); }
                    _pendingRequests.delete(id);
                    reject(err);
                }
            });
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
        ///
        /// Returns `{ py, cellErrors: [{ index, message }] }`.  The
        /// `cellErrors` list lets `callSolution` explain a downstream
        /// NameError ("function `foo` not defined") in terms of the
        /// earlier cell that crashed before reaching the def — pre-v0.4.130
        /// the per-cell errors were swallowed silently and a missing
        /// function gave a confusing message that didn't mention the cause.
        function ensureSolutionLoaded() {
            if (_solutionLoadedPromise) return _solutionLoadedPromise;
            _solutionLoadedPromise = fetch(urls.solutionNotebook(), {
                headers: { 'x-csrf-token': csrfToken }
            })
            .then(function (r) { return r.ok ? r.json() : Promise.reject(new Error('no-solution')); })
            .then(function (nb) {
                var cells = extractSolutionCells(nb);
                if (!cells.length) return Promise.reject(new Error('empty-solution'));
                // Hard cap on the load too.  A pathological top-level
                // cell (e.g. `while True: pass` outside any function,
                // or a heavy CSV read with a bug that loops) used to
                // hang the auto-compute forever — the function-call
                // timeout never fired because we never got past load.
                // 30s is generous (legitimate heavy imports, large
                // pandas reads) while still bounded.  On timeout we
                // terminate the worker; the next attempt re-loads.
                return workerSend({ type: 'loadCells', cells: cells }, LOAD_TIMEOUT_MS);
            })
            .then(function (data) {
                return { cellErrors: data.cellErrors || [] };
            });
            _solutionLoadedPromise.catch(function () { _solutionLoadedPromise = null; });
            return _solutionLoadedPromise;
        }

        /// Calls `fnName(*args)` on the loaded solution and returns the
        /// result as a JSON-serialisable value, or an error summary if it
        /// throws.  When `opts.captureStdout` is set, `redirect_stdout`
        /// wraps the call and the captured string is returned instead of
        /// the function's return value (used by the `stdout_equality`
        /// pattern kind).
        ///
        /// Result shape:
        ///   { ok: true,  value: <parsed>, returnedNone: false }     // value-returning success
        ///   { ok: true,  value: null,     returnedNone: true  }     // function returned None
        ///   { ok: false, unsupported: "<reason>" }                  // non-JSON-native return type
        ///   { ok: false, error: "<msg>" }                           // exception inside Python
        ///   { ok: false, timedOut: true, error: "..." }             // 5s budget exceeded
        ///
        /// The Python boundary uses a sentinel-keyed wrapper
        /// (`__chickadee_kind__`) instead of bare `_json.dumps(_result)`
        /// so that a `None` return is unambiguous — pre-fix, `None`
        /// became the string `"null"` and silently landed in the
        /// Expected cell as if the instructor had typed it.  v0.4.130
        /// extends the same sentinel to flag return types that don't
        /// round-trip cleanly via JSON (coroutines, generators, sets,
        /// tuples, bytes, complex) so the instructor sees a specific
        /// reason instead of `default=str` silently storing the repr
        /// string in the Expected cell.
        /// Auto-compute via the SERVER, in the assignment's own language.
        ///
        /// The browser path below is a Python kernel. It did not fail on an R,
        /// Lua, Octave, C++ or Racket assignment — it computed a PYTHON answer
        /// for a value that would be compared against that language's result,
        /// which is worse than not offering it. `PersonalizationEvaluator` on
        /// the server already evaluates in all six, so this routes there rather
        /// than growing five more kernels into the page.
        ///
        /// The value comes back as a LITERAL in that language (base R and Lua
        /// have no JSON to serialize with), so it is read with the same
        /// language-aware parser hand-typed values go through. A composite the
        /// parser cannot take is reported, not stored: storing a repr string
        /// would make it compare as text at grade time.
        function callSolutionOnServer(fnName, args, opts) {
            var captureStdout = !!(opts && opts.captureStdout);
            if (!urls.computeExpected) {
                return Promise.resolve({ ok: false, error: 'Auto-compute is unavailable on this page.' });
            }
            return fetch(urls.computeExpected(), {
                method: 'POST',
                headers: { 'Content-Type': 'application/json', 'x-csrf-token': csrfToken },
                body: JSON.stringify({
                    functionName: fnName, args: args, captureStdout: captureStdout
                })
            })
            .then(function (r) { return r.ok ? r.json() : Promise.reject('compute failed'); })
            .then(function (res) {
                if (res.unsupportedReason) return { ok: false, error: res.unsupportedReason };
                if (!res.ok) return { ok: false, error: res.error || 'The solution raised an error.' };
                var parsed = tryParseVarValue(res.rendered);
                if (!parsed.ok || !parsed.strict) {
                    // Scalars round-trip; a language repr of a list or record
                    // does not. Say so instead of storing the text.
                    var scalar = matchScalarToken(String(res.rendered).trim());
                    if (scalar) return { ok: true, value: scalar.value };
                    return {
                        ok: false,
                        error: 'Computed ' + res.rendered + ' — enter it here in JSON.'
                    };
                }
                return { ok: true, value: parsed.value };
            })
            .catch(function (e) { return { ok: false, error: String(e) }; });
        }

        function callSolution(fnName, args, opts) {
            // Python keeps the in-page kernel: it is faster, and its handling of
            // a None return and of types that do not round-trip through JSON is
            // behaviour existing assignments rely on. Every other language goes
            // to the server, which is the only place that can answer at all.
            if (languageFacts.name && languageFacts.name !== 'python') {
                return callSolutionOnServer(fnName, args, opts);
            }
            var captureStdout = !!(opts && opts.captureStdout);
            return ensureSolutionLoaded().then(function (loaded) {
                var cellErrors = loaded.cellErrors || [];
                var argsJSON = JSON.stringify(args);
                var fnLit = JSON.stringify(fnName);
                var argsLit = JSON.stringify(argsJSON);
                // The LAST top-level statement of each snippet must be an
                // expression statement (`ast.Expr`) — that's the only shape
                // Pyodide's `eval_code` extracts and returns to JS in
                // `last_expr` mode.  An `if/else` or `with` as the final
                // top-level statement causes `runPythonAsync` to resolve
                // with `undefined` and `JSON.parse(undefined)` to throw,
                // which silently breaks auto-compute.  Pre-v0.4.125 the
                // value-mode snippet did exactly that.  We now compute the
                // payload into `_payload` and put a bare `_json.dumps(...)`
                // on the last line.  The regression test in
                // PatternFamilyEditorJSTests asserts this structurally —
                // do not move work below that final dumps line.
                var pyCode;
                if (captureStdout) {
                    // PYODIDE_SNIPPET_BEGIN: stdout
                    pyCode = [
                        'import json as _json',
                        'import io as _io',
                        'import contextlib as _contextlib',
                        'import inspect as _inspect',
                        '_fn = globals().get(' + fnLit + ')',
                        'if _fn is None:',
                        '    raise NameError(' + fnLit + ' + " not defined in solution notebook")',
                        '_args = _json.loads(' + argsLit + ')',
                        '_buf = _io.StringIO()',
                        'with _contextlib.redirect_stdout(_buf):',
                        '    _ret = _fn(*_args)',
                        // An async function used by mistake: `_fn(*_args)`
                        // returns a coroutine without ever entering the
                        // body, so `_buf` is empty and the instructor
                        // would see a blank Expected.  Surface it.
                        'if _inspect.iscoroutine(_ret):',
                        '    _payload = {"__chickadee_kind__": "unsupported", "reason": "coroutine"}',
                        'elif _inspect.isasyncgen(_ret):',
                        '    _payload = {"__chickadee_kind__": "unsupported", "reason": "async-generator"}',
                        'else:',
                        '    _captured = _buf.getvalue()',
                        // Mirror the renderer-side normalisation so the
                        // auto-computed Expected matches what the
                        // generated test will compare against.
                        '    if _captured.endswith("\\n"):',
                        '        _captured = _captured[:-1]',
                        '    _payload = {"__chickadee_kind__": "value", "value": _captured}',
                        '_json.dumps(_payload)'
                    ].join('\n');
                    // PYODIDE_SNIPPET_END: stdout
                } else {
                    // PYODIDE_SNIPPET_BEGIN: value
                    pyCode = [
                        'import json as _json',
                        'import inspect as _inspect',
                        '_fn = globals().get(' + fnLit + ')',
                        'if _fn is None:',
                        '    raise NameError(' + fnLit + ' + " not defined in solution notebook")',
                        '_args = _json.loads(' + argsLit + ')',
                        '_result = _fn(*_args)',
                        // Non-JSON-native return types silently round-tripped
                        // pre-v0.4.130 via `default=str`, landing the repr
                        // string in the Expected cell as if the instructor
                        // typed it.  Detect each common shape and surface a
                        // specific reason so the instructor sees what
                        // happened instead of a stringified "<coroutine ...>".
                        'if _inspect.iscoroutine(_result):',
                        '    _payload = {"__chickadee_kind__": "unsupported", "reason": "coroutine"}',
                        'elif _inspect.isasyncgen(_result):',
                        '    _payload = {"__chickadee_kind__": "unsupported", "reason": "async-generator"}',
                        'elif _inspect.isgenerator(_result):',
                        '    _payload = {"__chickadee_kind__": "unsupported", "reason": "generator"}',
                        'elif isinstance(_result, (set, frozenset)):',
                        '    _payload = {"__chickadee_kind__": "unsupported", "reason": "set"}',
                        // Tuples ARE JSON-serialisable but the runner-side
                        // test compares with `==` against a Python tuple,
                        // and a JSON array round-trips back as a `list`,
                        // so `(1,2) == [1,2]` is False — silent miscompare.
                        'elif isinstance(_result, tuple):',
                        '    _payload = {"__chickadee_kind__": "unsupported", "reason": "tuple"}',
                        'elif isinstance(_result, (bytes, bytearray)):',
                        '    _payload = {"__chickadee_kind__": "unsupported", "reason": "bytes"}',
                        'elif isinstance(_result, complex):',
                        '    _payload = {"__chickadee_kind__": "unsupported", "reason": "complex"}',
                        'elif _result is None:',
                        '    _payload = {"__chickadee_kind__": "none"}',
                        'else:',
                        '    _payload = {"__chickadee_kind__": "value", "value": _result}',
                        '_json.dumps(_payload, default=str)'
                    ].join('\n');
                    // PYODIDE_SNIPPET_END: value
                }
                return workerSend({ type: 'run', code: pyCode }, TIMEOUT_MS).then(function (data) {
                    var parsed = JSON.parse(data.result);
                    if (parsed && parsed.__chickadee_kind__ === 'none') {
                        return { ok: true, value: null, returnedNone: true };
                    }
                    if (parsed && parsed.__chickadee_kind__ === 'unsupported') {
                        return { ok: false, unsupported: parsed.reason || 'unknown' };
                    }
                    return { ok: true, value: parsed.value, returnedNone: false };
                }).catch(function (err) {
                    if (err && err.message === '__chickadee_timeout__') {
                        return { ok: false, timedOut: true,
                                 error: 'timed out after ' + (TIMEOUT_MS / 1000) + 's' };
                    }
                    var msg = (err && err.message)
                        ? String(err.message).split('\n').filter(function (l) { return l.trim(); }).pop()
                        : String(err);
                    // When the function isn't found, fold the first
                    // solution-load error into the message so the
                    // instructor sees *why* the function never landed
                    // in globals — typical case: an earlier cell raised.
                    if (msg && msg.indexOf('not defined') >= 0 && cellErrors.length > 0) {
                        var first = cellErrors[0];
                        msg += ' (cell ' + (first.index + 1) + ' failed: ' + first.message + ')';
                    }
                    return { ok: false, error: msg || 'error' };
                });
            }).catch(function (err) {
                // Solution-load failures (no-solution, empty-solution,
                // network, load-timeout).  These come *before* any
                // callSolution-specific error wrapping, so cellErrors
                // is not in scope.  v0.4.137: translate the
                // load-timeout sentinel into the same {timedOut: true}
                // shape the run-timeout produces, so the UI's
                // `res.timedOut` branch handles both — pre-fix the
                // load timeout leaked the literal '__chickadee_timeout__'
                // string into the Expected cell.
                if (err && err.message === '__chickadee_timeout__') {
                    return { ok: false, timedOut: true,
                             error: 'solution notebook load timed out after ' + (LOAD_TIMEOUT_MS / 1000) + 's' };
                }
                var msg = (err && err.message) ? String(err.message) : String(err);
                return { ok: false, error: msg || 'error' };
            });
        }

        var _autoComputeTimer = null;
        // Pending rows to auto-compute on the next debounce tick.  Pre-
        // v0.4.101 this was a single-slot `_autoComputeRow` — calling
        // `scheduleAutoCompute(row2)` while row1 was still pending
        // silently overwrote row1, so only the LAST row in a rapid
        // sequence got computed.  That's why re-using a section variable
        // across multiple case rows didn't fill the Expected on all of
        // them (the `rescheduleAutoComputeForVariableRefCases` loop
        // queued every affected row but only the last survived).
        // Using a Set lets every scheduled row compute on the single
        // shared tick without spawning a timer per row.
        var _autoComputePending = new Set();

        function scheduleAutoCompute(row) {
            if (!row) return;
            _autoComputePending.add(row);
            if (_autoComputeTimer) clearTimeout(_autoComputeTimer);
            _autoComputeTimer = setTimeout(function () {
                var rows = Array.from(_autoComputePending);
                _autoComputePending = new Set();
                _autoComputeTimer = null;
                rows.forEach(autoComputeRow);
            }, 400);
        }

        /// When a variable is declared / renamed / retyped, kick off
        /// auto-compute on every case row that references *any* variable
        /// (i.e. has an arg cell starting with `$`).  Cheap enough: one
        /// Pyodide call per such row, debounced the same way as typing.
        function rescheduleAutoComputeForVariableRefCases() {
            if (!casesBody) return;
            Array.from(casesBody.querySelectorAll('tr')).forEach(function (row) {
                var hasVarRef = Array.from(row.querySelectorAll('.pf-case-arg'))
                    .some(function (cell) {
                        var v = (cell.value || '').trim();
                        return /^\$[A-Za-z_][A-Za-z0-9_]*$/.test(v);
                    });
                if (!hasVarRef) return;
                // Don't clobber the instructor's manual expected value.
                var expectedEl = row.querySelector('.pf-case-expected');
                if (expectedEl && expectedEl.dataset.manual === '1' && expectedEl.value.trim() !== '') return;
                scheduleAutoCompute(row);
            });
        }

        function autoComputeRow(row) {
            if (!row || !row.parentElement) return;
            // A language with no expression driver cannot answer this at all,
            // and the failure would be silent in the worst direction: the row
            // sits empty, or the server refuses and the instructor reads it as
            // a bug in their solution.  True for all six languages today —
            // every one has an interpreter on the server image — so this reads
            // the fact rather than assuming it, which is the whole point of the
            // fact existing.
            if (!ChickadeeLanguage.canEvaluateExpressions()) return;
            // Variable-equality families don't call a function — skip.
            if (kindInput && kindInput.value === 'variable_equality') return;
            // Return-type-check expected is a type name (e.g. "DataFrame"),
            // not the function's actual return value — auto-compute would
            // write the value, which is wrong.  Instructor types the
            // type name directly.
            if (kindInput && kindInput.value === 'return_type_check') return;
            // Exception-expected and performance-threshold are also
            // instructor-typed (an exception class name and a
            // millisecond budget respectively); skip auto-compute.
            if (kindInput && kindInput.value === 'exception_expected') return;
            if (kindInput && kindInput.value === 'performance_threshold') return;
            var fnName = (fnInput.value || '').trim();
            if (!fnName) return;
            var paramNames = paramsInput.value.split(',').map(function (s) { return s.trim(); }).filter(Boolean);
            if (!paramNames.length) return;  // fallback JSON-args mode: no auto-compute

            var expectedEl = row.querySelector('.pf-case-expected');
            if (!expectedEl) return;
            if (expectedEl.dataset.manual === '1' && expectedEl.value.trim() !== '') return;
            // A per-student `$name` Expected is resolved server-side per
            // student — never auto-compute/overwrite it.
            if (/^\$[A-Za-z_][A-Za-z0-9_]*$/.test(expectedEl.value.trim())) return;

            // Pull the latest variable values straight from the DOM so
            // `$name` refs in arg cells resolve to what the instructor
            // typed in the Variables table without needing a click Save
            // first.  Section-level variables come in FIRST; family-level
            // overrides (same name) win to match render-time semantics.
            var varsNow = {};
            (currentSectionVariables || []).forEach(function (v) {
                if (v && v.name && isValidServerIdentifier(v.name)) {
                    varsNow[v.name] = v.value;
                }
            });
            if (variablesBody) {
                Array.from(variablesBody.querySelectorAll('tr')).forEach(function (vrow) {
                    var n = (vrow.querySelector('.pf-var-name') || {}).value;
                    var v = (vrow.querySelector('.pf-var-value') || {}).value;
                    if (!n) return;
                    n = n.trim();
                    if (!isValidServerIdentifier(n)) return;
                    var parsed = tryParseVarValue(v);
                    if (parsed.kind === 'empty') return;
                    varsNow[n] = parsed.value;
                });
            }

            var args = [];
            for (var i = 0; i < paramNames.length; i++) {
                var cell = row.querySelector('.pf-case-arg[data-arg-index="' + i + '"]');
                var raw = cell ? cell.value : '';
                if (raw.trim() === '') {
                    // Optional param with a default: skip it so the
                    // solution picks up its own default value, the same
                    // way the runner-side test will.
                    if (currentParamHasDefault && currentParamHasDefault[i]) continue;
                    return;
                }
                var varMatch = raw.trim().match(/^\$([A-Za-z_][A-Za-z0-9_]*)$/);
                if (varMatch) {
                    if (!(varMatch[1] in varsNow)) return; // unresolved ref — skip until valid
                    args.push(varsNow[varMatch[1]]);
                    continue;
                }
                var paramTypeHint = currentParamTypes ? currentParamTypes[i] : null;
                args.push(coerceByType(raw, paramTypeHint));
            }

            expectedEl.placeholder = 'computing…';
            var captureStdout = (kindInput && kindInput.value === 'stdout_equality');
            callSolution(fnName, args, { captureStdout: captureStdout }).then(function (res) {
                if (!row.parentElement) return;
                if (expectedEl.dataset.manual === '1' && expectedEl.value.trim() !== '') return;
                if (res.ok && res.returnedNone) {
                    // The solution function returned None.  Don't write
                    // the string "null" to the cell — that used to
                    // round-trip as a literal value and confuse
                    // instructors.  Instead leave it empty with a
                    // clear hint, and suggest stdout_equality (which
                    // is the most common reason a function returns
                    // None: it print()s instead of returning).
                    expectedEl.value = '';
                    expectedEl.placeholder = '⚠ solution returned None';
                    expectedEl.title = 'The solution function returned None. Did you mean to print() and use the Stdout equality kind?';
                    expectedEl.style.borderColor = 'var(--amber)';
                    expectedEl.style.color = '';
                    delete expectedEl.dataset.autoComputed;
                } else if (res.ok) {
                    expectedEl.placeholder = 'e.g. underweight';
                    expectedEl.value = renderTypedCellValue(res.value);
                    expectedEl.dataset.autoComputed = '1';
                    expectedEl.title = 'Auto-computed from solution notebook';
                    expectedEl.style.color = 'var(--gray-500)';
                    expectedEl.style.borderColor = '';
                } else if (res.timedOut) {
                    expectedEl.value = '';
                    expectedEl.placeholder = '⚠ ' + res.error;
                    // v0.4.137: distinguish load-phase timeouts (a
                    // top-level cell hung — e.g. `while True: pass`
                    // outside the function under test) from run-phase
                    // timeouts (the function itself hung).  Pre-fix
                    // both surfaced the run-phase tooltip, which
                    // pointed instructors at the wrong cell.
                    expectedEl.title = res.error.indexOf('notebook load') >= 0
                        ? 'A top-level cell in the solution notebook ran longer than ' + (LOAD_TIMEOUT_MS / 1000) + ' seconds. Look for an infinite loop, a slow I/O call, or a blocking input() OUTSIDE the function under test (e.g. in a setup cell that runs at notebook open).'
                        : 'Solution call did not return within ' + (TIMEOUT_MS / 1000) + ' seconds. Check for an infinite loop or blocking I/O in the solution notebook.';
                    expectedEl.style.borderColor = 'var(--red)';
                } else if (res.unsupported) {
                    // The solution returned a value of a type that
                    // doesn't round-trip through JSON in a way the
                    // runner-side test will accept.  Show the specific
                    // reason so the instructor can decide whether to
                    // change the solution or type Expected manually.
                    var reasonText = ({
                        'coroutine':       'an async function (returned a coroutine without awaiting it)',
                        'async-generator': 'an async generator',
                        'generator':       'a generator',
                        'set':             'a set',
                        'tuple':           'a tuple',
                        'bytes':           'bytes',
                        'complex':         'a complex number'
                    })[res.unsupported] || res.unsupported;
                    expectedEl.value = '';
                    expectedEl.placeholder = '⚠ solution returned ' + reasonText;
                    expectedEl.title = "Auto-compute can't represent " + reasonText + ". Type the Expected value manually, or change the solution to return a JSON-friendly type (str, int, float, bool, list, dict).";
                    expectedEl.style.borderColor = 'var(--amber)';
                    expectedEl.style.color = '';
                    delete expectedEl.dataset.autoComputed;
                } else {
                    // v0.4.112: surface the failure in the cell itself
                    // (not just the title tooltip) — typical user
                    // doesn't think to hover.  "computing…" → "⚠ <err>"
                    // is enough to flag malformed input / undefined
                    // function / etc.
                    expectedEl.placeholder = '⚠ ' + (res.error || 'auto-compute failed');
                    expectedEl.title = 'Solution raised: ' + res.error;
                    expectedEl.style.borderColor = 'var(--red)';
                }
            });
        }

        casesBody.addEventListener('input', function (e) {
            var t = e.target;
            if (!t || !t.classList) return;
            if (t.classList.contains('pf-case-arg')) {
                // Live-highlight the `$name` binding state so the instructor
                // can see whether their ref resolves (family + section vars +
                // Global Inputs / `=` expressions).
                refreshArgCellHighlight(t, collectDeclaredInputNames());
                scheduleAutoCompute(t.closest('tr'));
            } else if (t.classList.contains('pf-case-expected')) {
                // Live-highlight a per-student `$name` Expected ref; mark the
                // cell manual so auto-compute won't clobber an author value.
                // Clearing the cell re-enables auto-compute.
                refreshExpectedCellHighlight(t, collectDeclaredInputNames());
                if (/^\$[A-Za-z_][A-Za-z0-9_]*$/.test(t.value.trim())) {
                    t.dataset.manual = '1';
                    delete t.dataset.autoComputed;
                } else if (t.value.trim() === '') {
                    t.style.color = '';
                    t.title = '';
                    delete t.dataset.manual;
                    delete t.dataset.autoComputed;
                    scheduleAutoCompute(t.closest('tr'));
                } else {
                    t.style.color = '';
                    t.title = '';
                    t.dataset.manual = '1';
                    delete t.dataset.autoComputed;
                }
            }
        });

        // Suite table: handle Edit/Delete on family rows (script rows are
        // handled by the suite-table IIFE elsewhere on the page).  The
        // container changed from `#suite-config-body` (a single tbody) to
        // `#suite-sections` (the multi-tbody sections mount) in v0.4.96 —
        // either id is accepted so older pages still work if this module
        // loads first.
        var suiteBody = document.getElementById('suite-sections')
                     || document.getElementById('suite-config-body');
        if (suiteBody) {
            suiteBody.addEventListener('click', function (e) {
                var editBtn = e.target && e.target.closest('.family-edit-btn');
                var delBtn  = e.target && e.target.closest('.family-delete-btn');
                if (editBtn) {
                    var fid = editBtn.getAttribute('data-family-id');
                    var idx = familiesState.findIndex(function (f) { return f.id === fid; });
                    if (idx >= 0) {
                        // Edit inline (accordion row) when the suite table is on
                        // the page; fall back to the modal shell.
                        if (typeof window.chickadeeExpandInlineEditor === 'function') {
                            window.chickadeeExpandInlineEditor(
                                { mechanism: 'family', editing: { item: familiesState[idx] }, afterRowID: 'family:' + fid });
                        } else if (window.__chickadeeTestEditorModal) {
                            window.__chickadeeTestEditorModal.open(
                                { editing: { mechanism: 'family', id: fid, item: familiesState[idx] } });
                        }
                    }
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
                    persistFamilies(next).catch(function () {});
                }
            });
        }

        // Read the family spec from the form, throwing a clean message on any
        // validation failure.  The Test Editor shell's `readSpec` hook.
        function readFamilySpec() {
            var family = readFamilyFromEditor();   // may throw (cases / vars)
            if (!family.functionName) throw new Error('Pick a function from the dropdown first.');
            if (!family.id) throw new Error('Family id could not be derived from the function name.');
            if (!family.name) throw new Error('Family name is required.');
            if (!family.cases.length) throw new Error('Add at least one case.');
            return family;
        }

        // Upsert `family` into the list and persist via PUT /suite.  Returns the
        // persist promise; rejects with a clean Error on a duplicate-id create.
        function persistFamilySpec(family) {
            var next = familiesState.slice();
            if (editingIndex >= 0) {
                next[editingIndex] = family;
            } else if (next.some(function (f) { return f.id === family.id; })) {
                return Promise.reject(new Error('A family for "' + family.functionName + '" already exists.'));
            } else {
                next.push(family);
            }
            return persistFamilies(next);
        }

        // Body renderer for the unified Test Editor modal.  The shell owns the
        // chrome + the type `<select>` (which supplies `kind`); this renderer
        // owns the family form (function/cases/variables/Pyodide compute),
        // relocated into the shell panel by mount().
        var familyRenderer = {
            mechanism: 'family',
            title: function (isEditing) { return isEditing ? 'Edit Pattern Family' : 'Add Test'; },
            mount: function (shellBody) {
                if (bodyEl && bodyEl.parentNode !== shellBody) {
                    bodyEl.hidden = false;
                    bodyEl.style.display = 'flex';
                    shellBody.appendChild(bodyEl);
                }
            },
            reset: function (kind) { openEditor(-1, kind); },
            populate: function (item) {
                var idx = familiesState.findIndex(function (f) { return f.id === (item && item.id); });
                openEditor(idx >= 0 ? idx : -1, item && item.kind);
            },
            readSpec: readFamilySpec,
            persistAndSync: persistFamilySpec,
            cleanup: function () { killWorker(); }
        };
        if (bodyEl) {
            window.ChickadeeTestRenderers = window.ChickadeeTestRenderers || {};
            window.ChickadeeTestRenderers.family = familyRenderer;
        }

        return {
            getFamilies: function () { return familiesState.slice(); }
        };
    }

    function noopAPI() {
        return {
            getFamilies: function () { return []; }
        };
    }

    /// Reads a `/instructor/scan-notebook` response into
    /// `{ functions, unsupportedReason }`.
    ///
    /// Shared because BOTH authoring pages call that endpoint, and the create
    /// page's copy lived inline in the template where nothing lints or tests it
    /// — the fork that let its JS go stale three separate ways (#1269). A bare
    /// array is still accepted so a cached older page does not break.
    function readScanPayload(payload) {
        if (Array.isArray(payload)) return { functions: payload, unsupportedReason: null };
        return {
            functions: (payload && payload.functions) || [],
            unsupportedReason: (payload && payload.unsupportedReason) || null
        };
    }

    /// Applies a scan response to the create page's status line and function
    /// checklist.
    ///
    /// Lives here rather than inline in `assignment-new.leaf` for the reason
    /// the inline-script guard exists: template JS is neither linted nor
    /// tested, and this page's inline copy is exactly the fork that went stale
    /// three ways in #1269. `els` carries the three elements it touches.
    function applyScanPayload(payload, els) {
        // Module scope, so the escapers come from ChickadeeUI directly rather
        // than the aliases bound inside initPatternFamilyEditor.
        var escHtml = ChickadeeUI.escapeHtml;
        var escAttr = ChickadeeUI.escapeAttr;
        var read = readScanPayload(payload);
        var status = els && els.status;
        var checklist = els && els.checklist;
        var results = els && els.results;
        if (read.unsupportedReason) {
            if (status) status.textContent = read.unsupportedReason;
            if (checklist) checklist.innerHTML = '';
            return [];
        }
        var functions = read.functions || [];
        if (status) {
            status.textContent = functions.length === 0
                ? 'No functions found.'
                : functions.length + ' function(s) found.';
        }
        if (checklist) {
            checklist.innerHTML = functions.map(function (fn) {
                var label = fn.name + '(' + ((fn.paramNames || []).join(', ')) + ')';
                return '<label class="fn-check-item">'
                    + '<input type="checkbox" id="' + escAttr('fn-chk-' + fn.name) + '"'
                    + ' value="' + escAttr(fn.name) + '" checked>'
                    + '<code>' + escHtml(label) + '</code></label>';
            }).join('');
        }
        if (functions.length > 0 && results) results.style.display = '';
        return functions;
    }

    global.chickadeeApplyScanPayload = applyScanPayload;
    global.chickadeeReadScanPayload = readScanPayload;
    global.initPatternFamilyEditor = initPatternFamilyEditor;
})(window);
