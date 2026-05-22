// Chickadee — Add Test dispatcher
//
// Unifies the three "add a test item" entry points (raw script, pattern
// family, notebook check) behind a single "+ Add Test" button per suite
// section.  The instructor picks a test *type* from one flat, intent-
// grouped catalog; the dispatcher then opens the existing specialised
// editor pre-seeded with the chosen kind.  The script / family / check
// distinction is an implementation detail the instructor never sees.
//
// This module owns its own modal DOM — it builds the overlay on init, so
// the host pages don't need to inline (and duplicate) the markup.  It
// drives the existing editors purely through window hooks set up by each
// page:
//
//   window.chickadeePatternFamilyEditor.open(-1, kind)   // function tests
//   window.chickadeeNotebookCheckEditor.open(null, sid, kind)
//   window.chickadeeOpenScriptCreator()                   // custom script
//
// Per-section "+ Add Test" buttons (`.section-add-test-btn[data-section-id]`)
// are wired via body-level delegation: a click stashes the section id on
// `window.__chickadeeTargetSection` (the same flag the editors already read
// to place a new item in the clicked section) and opens the picker.
//
// Host page wires the module via `window.initAddTestDispatcher()`.

(function (global) {
    'use strict';

    // The catalog.  `mechanism` decides which editor handles the type;
    // `value` is the underlying PatternKind / NotebookCheckKind string
    // ("script" for the custom raw-script flow).  Labels are written in
    // the instructor's mental model — no "family" / "check" jargon.
    var CATALOG = [
        {
            group: 'Test a function',
            items: [
                { value: 'boundary_equality',      mechanism: 'family', label: 'Returns the right value' },
                { value: 'approximate_equality',   mechanism: 'family', label: 'Returns the right value (within tolerance)' },
                { value: 'return_type_check',      mechanism: 'family', label: 'Returns the right type' },
                { value: 'exception_expected',     mechanism: 'family', label: 'Raises the right error' },
                { value: 'stdout_equality',        mechanism: 'family', label: 'Prints the right output' },
                { value: 'performance_threshold',  mechanism: 'family', label: 'Runs within a time budget' }
            ]
        },
        {
            group: 'Test a value or data structure',
            items: [
                { value: 'variable_exists',     mechanism: 'check',  label: 'Variable is defined' },
                { value: 'variable_equality',   mechanism: 'family', label: 'Variable equals a value' },
                { value: 'function_exists',     mechanism: 'check',  label: 'Function is defined' },
                { value: 'data_frame_shape',    mechanism: 'check',  label: 'DataFrame has the right shape' },
                { value: 'data_frame_columns',  mechanism: 'check',  label: 'DataFrame has the right columns' },
                { value: 'data_frame_equality', mechanism: 'check',  label: 'DataFrame matches expected' },
                { value: 'series_equality',     mechanism: 'check',  label: 'Series matches expected' },
                { value: 'numeric_array_close', mechanism: 'check',  label: 'Array is close to expected' }
            ]
        },
        {
            group: 'Test notebook structure & output',
            items: [
                { value: 'figure_count',   mechanism: 'check', label: 'Produces enough figures' },
                { value: 'cell_contains',  mechanism: 'check', label: 'Code contains specific text' },
                { value: 'ast_structure',  mechanism: 'check', label: 'Code uses / avoids constructs' }
            ]
        },
        {
            group: 'Custom',
            items: [
                { value: 'script', mechanism: 'script', label: 'Write a custom script' }
            ]
        }
    ];

    // One-line hints shown beneath the picker so the type names stay short.
    var DESCRIPTIONS = {
        boundary_equality:     'Call the student’s function with a table of inputs and check each return value.',
        approximate_equality:  'Like “Returns the right value”, but compares floats within a tolerance.',
        return_type_check:     'Check that the function returns a value of the expected type.',
        exception_expected:    'Check that the function raises the expected exception for given inputs.',
        stdout_equality:       'Check what the function prints to stdout for given inputs.',
        performance_threshold: 'Check that the function completes within a millisecond budget.',
        variable_exists:       'Check that a notebook variable is defined (optionally of a given type).',
        variable_equality:     'Check that a notebook variable equals an expected value.',
        function_exists:       'Check that a function is defined and callable (optionally with a given arity).',
        data_frame_shape:      'Check that a DataFrame has an expected number of rows and columns.',
        data_frame_columns:    'Check that a DataFrame has the expected columns.',
        data_frame_equality:   'Check that a DataFrame matches an expected table.',
        series_equality:       'Check that a Series matches an expected column of values.',
        numeric_array_close:   'Check that a numeric array is element-wise close to an expected array.',
        figure_count:          'Check that the notebook produces at least N matplotlib figures.',
        cell_contains:         'Check that the submission source contains a given substring or regex.',
        ast_structure:         'Check that the code uses (or avoids) constructs like loops, recursion, imports.',
        script:                'Write a raw .py / .sh / .r test script by hand in the code editor.'
    };

    function initAddTestDispatcher(config) {
        config = config || {};

        // ── Build the modal DOM ────────────────────────────────────────────
        // Bail if a previous init already mounted it (two pages never share
        // a document, but guard anyway).
        if (document.getElementById('add-test-overlay')) {
            return { open: openPicker, close: closePicker };
        }

        var overlay = document.createElement('div');
        overlay.id = 'add-test-overlay';
        overlay.setAttribute('role', 'dialog');
        overlay.setAttribute('aria-modal', 'true');
        overlay.setAttribute('aria-labelledby', 'add-test-title');
        overlay.style.cssText =
            'display:none;position:fixed;inset:0;z-index:1000;align-items:center;' +
            'justify-content:center;background:rgba(0,0,0,.4)';

        var card = document.createElement('div');
        card.className = 'card';
        card.style.cssText =
            'width:min(34rem,92vw);max-height:90vh;overflow:auto;padding:1.25rem;' +
            'border-radius:.6rem;box-shadow:0 8px 32px rgba(0,0,0,.25)';

        var optionsHTML = CATALOG.map(function (g) {
            var opts = g.items.map(function (it) {
                return '<option value="' + escAttr(it.value) + '" data-mechanism="' +
                    escAttr(it.mechanism) + '">' + escHtml(it.label) + '</option>';
            }).join('');
            return '<optgroup label="' + escAttr(g.group) + '">' + opts + '</optgroup>';
        }).join('');

        card.innerHTML =
            '<div style="display:flex;align-items:center;justify-content:space-between;gap:.75rem;margin-bottom:.75rem">' +
            '  <h2 id="add-test-title" style="margin:0;font-size:1.15rem">Add Test</h2>' +
            '  <button type="button" id="add-test-close" class="btn-link" aria-label="Close" title="Close" style="font-size:1.1rem;color:var(--gray-500);padding:.1rem .3rem">✕</button>' +
            '</div>' +
            '<label class="form-label" for="add-test-type" style="display:block;margin-bottom:.35rem">What do you want to test?</label>' +
            '<select class="form-input" id="add-test-type" style="width:100%">' + optionsHTML + '</select>' +
            '<p id="add-test-desc" class="card-meta" style="margin:.6rem 0 1rem;min-height:2.4em;font-size:.82rem;line-height:1.3"></p>' +
            '<div style="display:flex;justify-content:flex-end;gap:.5rem">' +
            '  <button type="button" id="add-test-cancel" class="btn action-btn">Cancel</button>' +
            '  <button type="button" id="add-test-continue" class="btn btn-primary">Continue</button>' +
            '</div>';

        overlay.appendChild(card);
        document.body.appendChild(overlay);

        var typeSelect  = document.getElementById('add-test-type');
        var descEl      = document.getElementById('add-test-desc');
        var continueBtn = document.getElementById('add-test-continue');
        var cancelBtn   = document.getElementById('add-test-cancel');
        var closeBtn    = document.getElementById('add-test-close');

        function refreshDescription() {
            descEl.textContent = DESCRIPTIONS[typeSelect.value] || '';
        }

        // ── Open / close ────────────────────────────────────────────────────
        function openPicker() {
            refreshDescription();
            overlay.style.display = 'flex';
            setTimeout(function () { typeSelect.focus(); }, 0);
        }

        function closePicker() {
            overlay.style.display = 'none';
        }

        function proceed() {
            var opt = typeSelect.options[typeSelect.selectedIndex];
            if (!opt) return;
            var mechanism = opt.getAttribute('data-mechanism');
            var kind = typeSelect.value;
            closePicker();

            var sid = (typeof global.__chickadeeTargetSection === 'string')
                ? global.__chickadeeTargetSection
                : null;

            if (mechanism === 'family') {
                if (global.chickadeePatternFamilyEditor &&
                    typeof global.chickadeePatternFamilyEditor.open === 'function') {
                    global.chickadeePatternFamilyEditor.open(-1, kind);
                }
            } else if (mechanism === 'check') {
                if (global.chickadeeNotebookCheckEditor &&
                    typeof global.chickadeeNotebookCheckEditor.open === 'function') {
                    global.chickadeeNotebookCheckEditor.open(null, sid, kind);
                }
            } else if (mechanism === 'script') {
                if (typeof global.chickadeeOpenScriptCreator === 'function') {
                    global.chickadeeOpenScriptCreator();
                }
            }
        }

        // ── Events ──────────────────────────────────────────────────────────
        typeSelect.addEventListener('change', refreshDescription);
        continueBtn.addEventListener('click', proceed);
        cancelBtn.addEventListener('click', closePicker);
        closeBtn.addEventListener('click', closePicker);
        overlay.addEventListener('click', function (e) {
            if (e.target === overlay) closePicker();
        });
        document.addEventListener('keydown', function (e) {
            if (e.key === 'Escape' && overlay.style.display !== 'none') closePicker();
        });

        // Per-section "+ Add Test" buttons.  Body-level delegation matches
        // how the legacy per-section buttons were wired; the clicked
        // button's section id is stashed so the downstream editor places
        // the new item in that section.
        document.body.addEventListener('click', function (e) {
            var btn = e.target && e.target.closest && e.target.closest('.section-add-test-btn');
            if (!btn) return;
            e.preventDefault();
            var sid = btn.getAttribute('data-section-id') || '';
            global.__chickadeeTargetSection = sid || null;
            openPicker();
        });

        return { open: openPicker, close: closePicker };
    }

    function escHtml(s) {
        return String(s == null ? '' : s)
            .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    }
    function escAttr(s) {
        return escHtml(s).replace(/"/g, '&quot;');
    }

    global.initAddTestDispatcher = initAddTestDispatcher;
})(window);
