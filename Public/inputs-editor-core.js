// Public/inputs-editor-core.js
//
// The shared core of the two "inputs" panels (#1126): the Global Inputs
// editor (global-inputs-editor.js) and the per-section inputs editor
// (section-inputs-editor.js) were ~64% identical and drifting — value
// classification, literal parsing, row validation/rendering, payload
// collection, and the debounced auto-save machinery now live here once.
// The two editor files keep only what genuinely differs: their CSS class
// names, their persistence endpoint, and how they report save results.
//
// A row's Value cell is one of two kinds, picked by prefix:
//   - "literal"     : `42`, `"hello"`, `[1, 2, 3]`, `{"k": 1}`, and the
//                     assignment language's own spelling of true/false/null.
//                     Parsed via tryParseLiteral (JSON + that language's
//                     scalar spellings), shared with the pattern-family editor
//                     through Public/authoring-language.js.
//   - "expression"  : starts with `=`, e.g. `= seed % 26`.
//                     Evaluated server-side per-student with `seed` bound —
//                     IN THE ASSIGNMENT'S LANGUAGE, by the driver
//                     PersonalizationEvaluator spawns for it. An expression is
//                     not Python unless the assignment is.
//
// Both editors persist `{ variables: [...], expressions: [...] }`.

(function () {
    'use strict';

    var RESERVED_NAMES = { 'seed': true };

    /// Is `s` a name the SERVER will accept for an input?
    ///
    /// Still Python's grammar, deliberately: `GlobalInputsService` and
    /// `SectionInputsService` call `isValidPythonIdentifier` for every language,
    /// so widening the client alone would let a name through that the save then
    /// rejects. The name of this function is the only Python-specific thing that
    /// should remain visible, and it is not shown to anyone.
    ///
    /// (A per-language identifier dispatch does exist server-side —
    /// `isValidRIdentifier` and friends — but it is private to
    /// `NotebookCheckKindHandler` and reaches notebook checks only. Extending it
    /// to inputs is a real behaviour change: `my.df` becomes a legal R name, and
    /// `$name` reference parsing has to be checked against a dot first.)
    function isValidPyIdent(s) {
        return /^[A-Za-z_][A-Za-z0-9_]*$/.test(s);
    }

    /// Classifies a row's Value cell.  Returns one of:
    ///   { kind: 'empty' }
    ///   { kind: 'expression', expression: '<source in the assignment's language>' }
    ///                                       (+ empty: true when bare `=`)
    ///   { kind: 'literal',    value: <JSON-able>, strict: true|false }
    function classifyValue(raw) {
        var t = String(raw == null ? '' : raw);
        var trimmed = t.trim();
        if (!trimmed) return { kind: 'empty' };
        if (trimmed.charAt(0) === '=') {
            var body = trimmed.slice(1).trim();
            if (!body) return { kind: 'expression', expression: '', empty: true };
            return { kind: 'expression', expression: body };
        }
        var lit = tryParseLiteral(trimmed);
        if (!lit.ok) return { kind: 'empty' };
        return { kind: 'literal', value: lit.value, strict: lit.strict };
    }

    /// Parses a literal value cell.  Returns { ok, value, strict } or
    /// { ok: false }.  One implementation for both panels so the on-disk
    /// JSON shape is identical.
    ///
    /// The scalar spellings are the ASSIGNMENT'S, not Python's. This accepted
    /// `True` / `False` / `None` on every language, so an R instructor typing
    /// the boolean true fell through to the bare-string branch and stored the
    /// STRING — silently, in a value a generated test then compares. Python's
    /// spellings still parse when the assignment is Python (or declares no
    /// language), so nothing that worked before stops working.
    function tryParseLiteral(t) {
        if (!t) return { ok: false };
        var scalar = ChickadeeLanguage.matchScalarToken(t);
        if (scalar) return { ok: true, value: scalar.value, strict: true };
        try { return { ok: true, value: JSON.parse(t), strict: true }; }
        catch (_) { /* fall through */ }
        if (t.indexOf('"') === -1) {
            try { return { ok: true, value: JSON.parse(ChickadeeLanguage.reprToJSON(t)), strict: false }; }
            catch (_) { /* fall through */ }
        }
        return { ok: true, value: t, strict: false };
    }

    /// Creates the panel-specific editor helpers.  `classes` names the CSS
    /// hooks: { row, name, value, valid, remove }; `rowOptions` tunes the
    /// generated row markup: { inputFontSize, removeCell: 'class'|'inline' }.
    function createEditor(classes, rowOptions) {
        rowOptions = rowOptions || {};

        function refreshRow(tr, tbody) {
            var nameEl  = tr.querySelector('.' + classes.name);
            var valueEl = tr.querySelector('.' + classes.value);
            var check   = tr.querySelector('.' + classes.valid);
            var name    = (nameEl.value || '').trim();
            var rawVal  = valueEl.value || '';

            var nameOk = name && isValidPyIdent(name) && !RESERVED_NAMES[name];
            // Duplicate check across all rows in this panel.
            if (nameOk && tbody) {
                var others = Array.from(tbody.querySelectorAll('.' + classes.name))
                    .map(function (el) { return (el.value || '').trim(); });
                if (others.filter(function (n) { return n === name; }).length > 1) {
                    nameOk = false;
                }
            }
            nameEl.classList.toggle('input-invalid', !(!name || nameOk));
            nameEl.title = (name && RESERVED_NAMES[name])
                ? "'" + name + "' is reserved for Chickadee's personalization seed."
                : '';

            var classified = classifyValue(rawVal);
            var valueOk = false;
            var hint = '';
            if (classified.kind === 'empty') {
                valueOk = false;
            } else if (classified.kind === 'expression') {
                // Expression mode: green tint to signal "per-student"; no
                // local syntax check — server validates at save time.
                valueOk = !classified.empty;
                hint = classified.empty
                    ? 'Expression body is empty after the leading `=`.'
                    : 'Per-student expression. Server evaluates with `seed` bound and substitutes the result.';
            } else {
                valueOk = classified.strict;
                hint = classified.strict
                    ? ''
                    : 'Treated as a bare string. Wrap in quotes for a JSON string, or check syntax for list/dict.';
            }

            // Classification cues are classes (styles.css: .input-expression
            // tints per-student rows green on both themes, .input-attention is
            // the amber needs-a-look border); toggling both every pass means
            // switching modes cannot leave stale cues.
            valueEl.title = hint;
            valueEl.classList.toggle('input-expression', classified.kind === 'expression');
            valueEl.classList.toggle('input-attention',
                (classified.kind === 'expression' && !valueOk) || (classified.kind !== 'expression' && !!rawVal && !valueOk));

            if (check) check.textContent = (nameOk && valueOk) ? '✓' : '';
        }

        function refreshAllRows(tbody) {
            Array.from(tbody.querySelectorAll('tr.' + classes.row)).forEach(function (tr) {
                refreshRow(tr, tbody);
            });
        }

        var TRASH_SVG =
            '<svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" '
            + 'fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" '
            + 'stroke-linejoin="round" aria-hidden="true"><polyline points="3 6 5 6 21 6"></polyline>'
            + '<path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6"></path>'
            + '<path d="M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2"></path>'
            + '<line x1="10" y1="11" x2="10" y2="17"></line>'
            + '<line x1="14" y1="11" x2="14" y2="17"></line></svg>';

        function addEmptyRow(tbody) {
            var fontSize = rowOptions.inputFontSize ? 'font-size:' + rowOptions.inputFontSize + ';' : '';
            var removeCellOpen = rowOptions.removeCell === 'inline'
                ? '<td style="width:2.5rem;text-align:right">'
                : '<td class="time">'; // right-aligned utility cell
            var removeBtnStyle = rowOptions.removeCell === 'inline'
                ? ' style="padding:.2rem .4rem;display:inline-flex;align-items:center"'
                : '';
            var tr = document.createElement('tr');
            tr.className = classes.row;
            tr.innerHTML =
                '<td style="width:14rem;white-space:nowrap">'
              +   '<span class="' + classes.valid + '" style="display:inline-block;width:1rem;color:var(--green);font-size:.95rem;text-align:center"></span>'
              +   '<input type="text" class="form-input ' + classes.name + '" value="" placeholder="Input Name" style="width:calc(100% - 1.5rem);padding:.2rem .4rem;' + fontSize + 'font-family:monospace">'
              + '</td>'
              + '<td><input type="text" class="form-input ' + classes.value + '" value="" placeholder=\'12, "hello", [1, 2, 3], or = seed % 26\' style="width:100%;padding:.2rem .4rem;' + fontSize + 'font-family:monospace"></td>'
              + removeCellOpen
              +   '<button type="button" class="btn action-btn action-danger ' + classes.remove + '" title="Remove input" aria-label="Remove input"' + removeBtnStyle + '>'
              +   TRASH_SVG + '</button></td>';
            tbody.appendChild(tr);
            refreshRow(tr, tbody);
            var input = tr.querySelector('.' + classes.name);
            if (input) input.focus();
        }

        /// Collects `{ variables, expressions }` from the panel's rows, or
        /// null when any non-blank row is invalid (bad name, empty value,
        /// duplicate name across both kinds — one Python namespace).
        function buildPayload(tbody) {
            var rows = Array.from(tbody.querySelectorAll('tr.' + classes.row));
            var variables = [];
            var expressions = [];
            var valid = true;
            for (var i = 0; i < rows.length; i++) {
                var tr = rows[i];
                var name = (tr.querySelector('.' + classes.name).value || '').trim();
                var rawVal = tr.querySelector('.' + classes.value).value || '';
                if (!name && !rawVal.trim()) continue;
                if (!isValidPyIdent(name) || RESERVED_NAMES[name]) { valid = false; continue; }
                var classified = classifyValue(rawVal);
                if (classified.kind === 'empty') { valid = false; continue; }
                if (classified.kind === 'expression') {
                    if (classified.empty) { valid = false; continue; }
                    expressions.push({ name: name, expression: classified.expression });
                } else {
                    variables.push({ name: name, value: classified.value });
                }
            }
            var seen = {};
            var all = variables.concat(expressions);
            for (var k = 0; k < all.length; k++) {
                if (seen[all[k].name]) { valid = false; break; }
                seen[all[k].name] = true;
            }
            return valid ? { variables: variables, expressions: expressions } : null;
        }

        return {
            refreshRow: refreshRow,
            refreshAllRows: refreshAllRows,
            addEmptyRow: addEmptyRow,
            buildPayload: buildPayload
        };
    }

    /// Debounced auto-save with in-flight coalescing, shared by both panels.
    /// `doSave()` must return a Promise.  Returns { schedule, flush }; flush
    /// fires immediately (used by the main-form submit hooks).
    function makeDebouncedSaver(doSave, delayMs) {
        var timer = null;
        var inFlight = null;
        var pending = false;

        function run() {
            inFlight = doSave().finally(function () {
                inFlight = null;
                if (pending) { pending = false; run(); }
            });
            return inFlight;
        }
        function schedule() {
            if (timer) clearTimeout(timer);
            timer = setTimeout(function () { timer = null; flush(); }, delayMs || 500);
        }
        function flush() {
            if (timer) { clearTimeout(timer); timer = null; }
            if (inFlight) { pending = true; return inFlight; }
            return run();
        }
        return { schedule: schedule, flush: flush };
    }

    var api = {
        RESERVED_NAMES: RESERVED_NAMES,
        isValidPyIdent: isValidPyIdent,
        classifyValue: classifyValue,
        tryParseLiteral: tryParseLiteral,
        createEditor: createEditor,
        makeDebouncedSaver: makeDebouncedSaver
    };

    var root = typeof window !== 'undefined' ? window : globalThis;
    root.ChickadeeInputsCore = api;
    // Node export for the .mjs unit tests.
    if (typeof module === 'object' && module.exports) {
        module.exports = api;
    }
}());
