// Public/section-inputs-editor.js
//
// Slice 4 of issue #461 — extracted from the inline `<script>` block in
// assignment-edit.leaf and extended with `=` prefix support so section
// inputs can carry per-student expressions (parity with the global-
// inputs editor shipped in Slice 2).
//
// A section row is one of two kinds, picked by the Value cell's prefix:
//   - "literal"     : `42`, `"hello"`, `[1, 2, 3]`, `True`, ...
//                     Parsed via tryParseLiteral; inlined at save time
//                     into pattern-family case args (`$name`),
//                     prepended to raw `.py` scripts in this section,
//                     and substituted into starter-notebook `{{name}}`
//                     markers as a literal.
//   - "expression"  : starts with `=`, e.g. `= seed % 26`.
//                     Evaluated server-side per-student at notebook
//                     first-open; the result substitutes into
//                     `{{name}}` markers.  Doesn't participate in
//                     `$name` references or raw-script inlining
//                     (matches Slice 2's notebooks-only constraint).
//
// Persists to POST /instructor/:id/suite-sections/:sectionID/variables
// with a JSON body `{ variables: [...], expressions: [...] }`.  Old
// editor builds sending only `variables` keep working server-side.

(function () {
    'use strict';

    var RESERVED_NAMES = { 'seed': true };

    function csrf() {
        var m = document.querySelector('meta[name="csrf-token"]');
        return m ? m.getAttribute('content') : '';
    }

    function isValidPyIdent(s) {
        return /^[A-Za-z_][A-Za-z0-9_]*$/.test(s);
    }

    /// Classifies a row's Value cell.  Returns one of:
    ///   { kind: 'empty' }
    ///   { kind: 'expression', expression: '<python>' }
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
    /// { ok: false }.  Matches global-inputs-editor.js byte-for-byte so
    /// the on-disk JSON shape is identical across the two panels.
    function tryParseLiteral(t) {
        if (!t) return { ok: false };
        if (t === 'True')  return { ok: true, value: true,  strict: true };
        if (t === 'False') return { ok: true, value: false, strict: true };
        if (t === 'None')  return { ok: true, value: null,  strict: true };
        try { return { ok: true, value: JSON.parse(t), strict: true }; }
        catch (_) { /* fall through */ }
        if (t.indexOf('"') === -1) {
            var pyish = t.replace(/'/g, '"')
                         .replace(/\bTrue\b/g, 'true')
                         .replace(/\bFalse\b/g, 'false')
                         .replace(/\bNone\b/g, 'null');
            try { return { ok: true, value: JSON.parse(pyish), strict: false }; }
            catch (_) { /* fall through */ }
        }
        return { ok: true, value: t, strict: false };
    }

    function refreshRow(tr, tbody) {
        var nameEl  = tr.querySelector('.section-var-name');
        var valueEl = tr.querySelector('.section-var-value');
        var check   = tr.querySelector('.section-var-row-valid');
        var name    = (nameEl.value || '').trim();
        var rawVal  = valueEl.value || '';

        var nameOk = name && isValidPyIdent(name) && !RESERVED_NAMES[name];
        if (nameOk && tbody) {
            var others = Array.from(tbody.querySelectorAll('.section-var-name'))
                .map(function (el) { return (el.value || '').trim(); });
            if (others.filter(function (n) { return n === name; }).length > 1) {
                nameOk = false;
            }
        }
        nameEl.style.borderColor = (!name || nameOk) ? '' : 'var(--red,#c0392b)';
        nameEl.title = (name && RESERVED_NAMES[name])
            ? "'" + name + "' is reserved for Chickadee's personalization seed."
            : '';

        var classified = classifyValue(rawVal);
        var valueOk = false;
        var hint = '';
        if (classified.kind === 'empty') {
            valueOk = false;
        } else if (classified.kind === 'expression') {
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

        // Reset cues then apply current.
        valueEl.style.borderColor = '';
        valueEl.style.backgroundColor = '';
        valueEl.title = hint;
        if (classified.kind === 'expression') {
            valueEl.style.backgroundColor = 'rgba(45, 143, 71, .07)';
            if (!valueOk) valueEl.style.borderColor = 'var(--amber,#b38600)';
        } else if (rawVal && !valueOk) {
            valueEl.style.borderColor = 'var(--amber,#b38600)';
        }

        if (check) check.textContent = (nameOk && valueOk) ? '✓' : '';
    }

    function refreshAllRows(tbody) {
        Array.from(tbody.querySelectorAll('tr.section-var-row')).forEach(function (tr) {
            refreshRow(tr, tbody);
        });
    }

    function addEmptyRow(tbody) {
        var tr = document.createElement('tr');
        tr.className = 'section-var-row';
        tr.innerHTML =
            '<td style="width:14rem;white-space:nowrap">'
          +   '<span class="section-var-row-valid" style="display:inline-block;width:1rem;color:var(--green,#2d8f47);font-size:.95rem;text-align:center"></span>'
          +   '<input type="text" class="form-input section-var-name" value="" placeholder="Input Name" style="width:calc(100% - 1.5rem);padding:.2rem .4rem;font-size:.78rem;font-family:monospace">'
          + '</td>'
          + '<td><input type="text" class="form-input section-var-value" value="" placeholder=\'12, "hello", [1, 2, 3], or = seed % 26\' style="width:100%;padding:.2rem .4rem;font-size:.78rem;font-family:monospace"></td>'
          + '<td style="width:2.5rem;text-align:right"><button type="button" class="btn action-btn action-danger section-var-remove" title="Remove input" aria-label="Remove input" style="padding:.2rem .4rem;display:inline-flex;align-items:center"><svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="3 6 5 6 21 6"></polyline><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6"></path><path d="M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2"></path><line x1="10" y1="11" x2="10" y2="17"></line><line x1="14" y1="11" x2="14" y2="17"></line></svg></button></td>';
        tbody.appendChild(tr);
        refreshRow(tr, tbody);
        var input = tr.querySelector('.section-var-name');
        if (input) input.focus();
    }

    function buildPayload(form) {
        var tbody = form.querySelector('tbody.section-vars-body');
        if (!tbody) return null;
        var rows = Array.from(tbody.querySelectorAll('tr.section-var-row'));
        var variables = [];
        var expressions = [];
        var valid = true;
        for (var i = 0; i < rows.length; i++) {
            var tr = rows[i];
            var name = (tr.querySelector('.section-var-name').value || '').trim();
            var rawVal = tr.querySelector('.section-var-value').value || '';
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
        // Cross-kind dedupe (same Python namespace at runtime).
        var seen = {};
        var all = variables.concat(expressions);
        for (var k = 0; k < all.length; k++) {
            if (seen[all[k].name]) { valid = false; break; }
            seen[all[k].name] = true;
        }
        return valid ? { variables: variables, expressions: expressions } : null;
    }

    /// Per-form auto-save with debounce + in-flight coalescing.  Returns
    /// a public { flush } object that the main-form submit handler can
    /// await before letting the assignment save through.
    function wireAutoSave(form) {
        var tbody = form.querySelector('tbody.section-vars-body');
        if (!tbody) return { flush: function () { return Promise.resolve(); } };

        var timer = null;
        var inFlight = null;
        var pending = false;

        function doPost() {
            var payload = buildPayload(form);
            if (!payload) return Promise.resolve();
            inFlight = fetch(form.action, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json', 'x-csrf-token': csrf() },
                redirect: 'manual',
                body: JSON.stringify(payload)
            }).then(function (r) {
                if (!r.ok && r.type !== 'opaqueredirect') {
                    return r.text().catch(function () { return ''; }).then(function (t) {
                        throw new Error('section-vars save failed: HTTP ' + r.status + ' ' + t.slice(0, 200));
                    });
                }
            }).catch(function (err) {
                console.error('section-vars auto-save failed:', err);
            }).finally(function () {
                inFlight = null;
                if (pending) { pending = false; doPost(); }
            });
            return inFlight;
        }

        function schedule() {
            if (timer) clearTimeout(timer);
            timer = setTimeout(function () { timer = null; flushNow(); }, 500);
        }
        function flushNow() {
            if (timer) { clearTimeout(timer); timer = null; }
            if (inFlight) { pending = true; return inFlight; }
            return doPost() || Promise.resolve();
        }

        refreshAllRows(tbody);

        form.addEventListener('input', function (e) {
            var tr = e.target.closest && e.target.closest('tr.section-var-row');
            if (tr) {
                refreshAllRows(tbody);
                schedule();
            }
        });
        form.addEventListener('click', function (e) {
            var btn = e.target.closest && e.target.closest('.section-var-remove');
            if (btn && form.contains(btn)) {
                var tr = btn.closest('tr.section-var-row');
                if (tr) { tr.remove(); refreshAllRows(tbody); schedule(); }
            }
        });
        form.addEventListener('submit', function (e) { e.preventDefault(); flushNow(); });

        return { flush: flushNow };
    }

    function init() {
        var forms = Array.from(document.querySelectorAll('form.section-vars-form'))
            .map(wireAutoSave);

        window.chickadeeFlushSectionVars = function () {
            return Promise.all(forms.map(function (f) { return f.flush(); }));
        };

        // "+ Add Input" buttons (one per section).  Buttons live in the
        // section header, not inside the form, so look up the form by
        // data-section-id.
        document.querySelectorAll('button.section-var-add').forEach(function (btn) {
            btn.addEventListener('click', function () {
                var sid = btn.getAttribute('data-section-id') || '';
                var form = document.querySelector('form.section-vars-form[data-section-id="' + sid + '"]');
                if (!form) return;
                var tbody = form.querySelector('tbody.section-vars-body');
                if (tbody) addEmptyRow(tbody);
            });
        });
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
