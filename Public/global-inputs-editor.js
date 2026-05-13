// Public/global-inputs-editor.js
//
// Slice 1 of issue #461 — wires the "Global Inputs" panel at the top of
// the assignment edit page.  Mirrors the section-vars editor in
// assignment-edit.leaf (parses bare-typed JSON + Python-ish shortcuts,
// debounced auto-save) but persists to PUT /instructor/:id/global-variables
// with a JSON response (no 303 redirect — the server returns the
// reconciled list plus warnings, which we render into the status pill).
//
// Validation locally rejects bad rows so the save isn't fired with
// known-broken data.  Server validates again and surfaces server-side
// errors (e.g. unknown {{name}} in the starter notebook) into the
// status pill below the panel.

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

    /// Parses a value cell.  Returns:
    ///   { ok: true,  value: <JSON-able>, strict: true|false }
    ///   { ok: false, empty: true }
    /// Matches the section-vars editor's `tryParseValue` byte-for-byte so
    /// the on-disk shape is identical across the two panels.
    function tryParseValue(raw) {
        var t = String(raw == null ? '' : raw).trim();
        if (!t) return { ok: false, empty: true };
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
        return { ok: true, value: String(raw), strict: false };
    }

    function refreshRow(tr, tbody) {
        var nameEl  = tr.querySelector('.global-input-name');
        var valueEl = tr.querySelector('.global-input-value');
        var check   = tr.querySelector('.global-input-row-valid');
        var name    = (nameEl.value || '').trim();
        var rawVal  = valueEl.value || '';

        var nameOk = name && isValidPyIdent(name) && !RESERVED_NAMES[name];
        // Duplicate check across all rows in the global-inputs panel.
        if (nameOk && tbody) {
            var others = Array.from(tbody.querySelectorAll('.global-input-name'))
                .map(function (el) { return (el.value || '').trim(); });
            if (others.filter(function (n) { return n === name; }).length > 1) {
                nameOk = false;
            }
        }
        nameEl.style.borderColor = (!name || nameOk) ? '' : 'var(--red,#c0392b)';
        nameEl.title = (name && RESERVED_NAMES[name])
            ? "'" + name + "' is reserved for Chickadee's personalization seed."
            : '';

        var parsed = tryParseValue(rawVal);
        var valueOk = parsed.ok && !parsed.empty && parsed.strict;
        valueEl.style.borderColor = (!rawVal || valueOk) ? '' : 'var(--amber,#b38600)';
        valueEl.title = (parsed.ok && !parsed.empty && !parsed.strict)
            ? 'Treated as a bare string. Wrap in quotes for a JSON string, or check syntax for list/dict.'
            : '';

        if (check) check.textContent = (nameOk && valueOk) ? '✓' : '';
    }

    function refreshAllRows(tbody) {
        Array.from(tbody.querySelectorAll('tr.global-input-row')).forEach(function (tr) {
            refreshRow(tr, tbody);
        });
    }

    function addEmptyRow(tbody) {
        var tr = document.createElement('tr');
        tr.className = 'global-input-row';
        tr.innerHTML =
            '<td style="width:14rem;white-space:nowrap">'
          +   '<span class="global-input-row-valid" style="display:inline-block;width:1rem;color:var(--green,#2d8f47);font-size:.95rem;text-align:center"></span>'
          +   '<input type="text" class="form-input global-input-name" value="" placeholder="Input Name" style="width:calc(100% - 1.5rem);padding:.2rem .4rem;font-size:.78rem;font-family:monospace">'
          + '</td>'
          + '<td><input type="text" class="form-input global-input-value" value="" placeholder=\'12, "hello", [1, 2, 3], {"k": 1}\' style="width:100%;padding:.2rem .4rem;font-size:.78rem;font-family:monospace"></td>'
          + '<td style="width:2.5rem;text-align:right"><button type="button" class="btn action-btn action-danger global-input-remove" title="Remove input" aria-label="Remove input" style="padding:.2rem .4rem;display:inline-flex;align-items:center"><svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="3 6 5 6 21 6"></polyline><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6"></path><path d="M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2"></path><line x1="10" y1="11" x2="10" y2="17"></line><line x1="14" y1="11" x2="14" y2="17"></line></svg></button></td>';
        tbody.appendChild(tr);
        refreshRow(tr, tbody);
        var input = tr.querySelector('.global-input-name');
        if (input) input.focus();
    }

    function buildPayload(tbody) {
        var rows = Array.from(tbody.querySelectorAll('tr.global-input-row'));
        var variables = [];
        var valid = true;
        for (var i = 0; i < rows.length; i++) {
            var tr = rows[i];
            var name = (tr.querySelector('.global-input-name').value || '').trim();
            var rawVal = tr.querySelector('.global-input-value').value || '';
            if (!name && !rawVal.trim()) continue;
            if (!isValidPyIdent(name) || RESERVED_NAMES[name]) { valid = false; continue; }
            var parsed = tryParseValue(rawVal);
            if (parsed.empty) { valid = false; continue; }
            variables.push({ name: name, value: parsed.value });
        }
        var seen = {};
        for (var k = 0; k < variables.length; k++) {
            if (seen[variables[k].name]) { valid = false; break; }
            seen[variables[k].name] = true;
        }
        return valid ? { variables: variables } : null;
    }

    function init() {
        var block = document.getElementById('global-inputs-block');
        if (!block) return;
        var tbody = block.querySelector('tbody.global-inputs-body');
        var addBtn = document.getElementById('global-input-add');
        var status = document.getElementById('global-inputs-status');
        var assignmentID = block.getAttribute('data-assignment-id') || '';
        if (!tbody || !assignmentID) return;

        var url = '/instructor/' + encodeURIComponent(assignmentID) + '/global-variables';
        var timer = null;
        var inFlight = null;
        var pending = false;

        function setStatus(text, kind) {
            if (!status) return;
            status.textContent = text || '';
            status.style.color = kind === 'error'
                ? 'var(--red,#c0392b)'
                : (kind === 'ok'
                    ? 'var(--green,#2d8f47)'
                    : 'var(--gray-500)');
        }

        function doSave() {
            var payload = buildPayload(tbody);
            if (!payload) {
                setStatus('Fix highlighted rows to save.', 'error');
                return Promise.resolve();
            }
            setStatus('Saving…', null);
            inFlight = fetch(url, {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json', 'x-csrf-token': csrf() },
                body: JSON.stringify(payload)
            }).then(function (r) {
                if (r.ok) {
                    return r.json().then(function (body) {
                        var warns = body && body.warnings;
                        if (warns && warns.length) {
                            setStatus('Saved. Warnings: ' + warns.join('; '), 'error');
                        } else {
                            setStatus('Saved.', 'ok');
                        }
                    }).catch(function () { setStatus('Saved.', 'ok'); });
                }
                return r.text().catch(function () { return ''; }).then(function (t) {
                    var msg = t || ('HTTP ' + r.status);
                    // Vapor Abort serialises as { error: true, reason: "..." }
                    try {
                        var parsed = JSON.parse(t);
                        if (parsed && parsed.reason) msg = parsed.reason;
                    } catch (_) { /* leave msg as text */ }
                    setStatus('Save failed: ' + msg.slice(0, 240), 'error');
                });
            }).catch(function (err) {
                setStatus('Save failed: ' + (err && err.message ? err.message : err), 'error');
            }).finally(function () {
                inFlight = null;
                if (pending) { pending = false; doSave(); }
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
            return doSave() || Promise.resolve();
        }

        refreshAllRows(tbody);

        block.addEventListener('input', function (e) {
            var tr = e.target.closest && e.target.closest('tr.global-input-row');
            if (tr) {
                refreshAllRows(tbody);
                schedule();
            }
        });
        block.addEventListener('click', function (e) {
            var btn = e.target.closest && e.target.closest('.global-input-remove');
            if (btn && block.contains(btn)) {
                var tr = btn.closest('tr.global-input-row');
                if (tr) { tr.remove(); refreshAllRows(tbody); schedule(); }
            }
        });

        if (addBtn) {
            addBtn.addEventListener('click', function () { addEmptyRow(tbody); });
        }

        // Expose a global flush hook so the main "Save & Validate"
        // submit can await any pending PUTs before reloading the page.
        window.chickadeeFlushGlobalInputs = flushNow;
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
