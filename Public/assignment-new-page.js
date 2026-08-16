// Page wiring for the Create Assignment page (assignment-new.leaf).
// Extracted from the page's inline script blocks so every URL builder and
// event hook is linted and testable; the template carries data only — the
// JSON seeds plus the #new-assignment-config island this file reads
// ({draftID, hasSolutionNotebook}).
//
// The page shares its editor modules with the edit surface
// (suite-table.js, pattern-family-editor.js, test-editor-modal.js,
// support-files.js); only the wiring here differs, because draft endpoints
// are query-scoped (?draftID=…) where the edit page's are path-scoped.
// Load after those modules, at the end of the page body.
(function () {
    'use strict';

    var config = {};
    var island = document.getElementById('new-assignment-config');
    if (island) {
        try { config = JSON.parse(island.textContent || '{}') || {}; }
        catch (e) { config = {}; }
    }
    var draftID = config.draftID || null;
    var csrfToken = ChickadeeUI.getCsrfToken();

    // ── Pattern family editor (Public/pattern-family-editor.js) ─────────────
    // Wired to draft-scoped URLs; after a save the page reloads so the
    // server-rendered suite table picks up the newly generated scripts.
    // No draft yet (the user hasn't uploaded a solution notebook) → no-op.
    if (draftID) {
        var seed = document.getElementById('pattern-families-seed');
        var initialFamilies = [];
        if (seed) {
            try { initialFamilies = JSON.parse(seed.textContent || '[]') || []; }
            catch (e) { initialFamilies = []; }
        }
        window.chickadeePatternFamilyEditor = window.initPatternFamilyEditor({
            draftID: draftID,
            csrfToken: csrfToken,
            initialFamilies: initialFamilies,
            urls: {
                solutionNotebook: function () {
                    return '/instructor/new/draft/solution-notebook?draftID=' + encodeURIComponent(draftID);
                },
                scanNotebook: function () { return '/instructor/scan-notebook'; }
            }
        });
    }

    // ── Unified suite table (Public/suite-table.js) ─────────────────────────
    // The module itself is only loaded once a draft exists (the template's
    // conditional include), so guard on both facts.
    if (draftID && typeof window.initSuiteTable === 'function') {
        var suiteTable = window.initSuiteTable({
            assignmentID: 'draft:' + draftID,  // diagnostics-only; URL builders below ignore
            csrfToken: csrfToken,
            formSelector: 'form#new-assignment-form',
            urls: {
                putSuite: function () {
                    return '/instructor/new/draft/suite?draftID=' + encodeURIComponent(draftID);
                },
                deleteScript: function (name) {
                    return '/instructor/new/draft/scripts/' + encodeURIComponent(name)
                         + '?draftID=' + encodeURIComponent(draftID);
                },
                uploadScript: function () {
                    return '/instructor/new/draft/scripts?draftID=' + encodeURIComponent(draftID);
                },
                reorderSections: function () {
                    return '/instructor/new/draft/suite-sections/reorder?draftID='
                         + encodeURIComponent(draftID);
                }
            }
        });
        // Window globals the Test Editor renderers call to persist through the
        // single PUT /suite write path.
        window.chickadeeAddExistingSuiteScript = suiteTable.addExistingScript;
        window.chickadeeSaveFamiliesViaSuite   = suiteTable.saveFamiliesViaSuite;
        window.chickadeeSaveChecksViaSuite     = suiteTable.saveChecksViaSuite;
        window.chickadeeSaveScriptViaSuite     = suiteTable.saveScriptViaSuite;
        window.chickadeeGetSuiteItems          = suiteTable.getItems;
    }

    // ── Notebook upload buttons ─────────────────────────────────────────────
    // Open hidden file pickers, then submit the main form to the draft
    // endpoint with a `draftAction` field so the server saves the file bytes
    // and reloads the page on the same draft.
    function wireNotebookUpload(btnID, inputID, draftActionValue) {
        var btn       = document.getElementById(btnID);
        var fileInput = document.getElementById(inputID);
        if (!btn || !fileInput) return;
        btn.addEventListener('click', function () { fileInput.value = ''; fileInput.click(); });
        fileInput.addEventListener('change', function () {
            if (fileInput.files.length === 0) return;
            var form = document.getElementById('new-assignment-form');
            var inp = document.createElement('input');
            inp.type = 'hidden';
            inp.name = 'draftAction';
            inp.value = draftActionValue;
            form.appendChild(inp);
            form.action = '/instructor/new/draft';
            form.requestSubmit();
        });
    }
    wireNotebookUpload('upload-assignment-notebook-btn', 'assignment-notebook-file-input', 'upload-assignment-notebook');
    wireNotebookUpload('upload-solution-notebook-btn',   'solution-notebook-file-input',   'upload-solution-notebook');

    // ── Support files (Public/support-files.js) ─────────────────────────────
    // Draft-scoped endpoints; a reload picks up the changed file rows.
    // Without a draft there are no rows and no working upload target, so the
    // flow stays unwired (the buttons only do something once a draft exists).
    if (draftID) {
        window.initSupportFiles({
            csrfToken: csrfToken,
            uploadURL: function () {
                return '/instructor/new/draft/scripts?draftID=' + encodeURIComponent(draftID);
            },
            deleteURL: function (name) {
                return '/instructor/new/draft/scripts/' + encodeURIComponent(name)
                     + '?draftID=' + encodeURIComponent(draftID);
            },
            datasetsURL: function () {
                return '/instructor/new/draft/datasets?draftID=' + encodeURIComponent(draftID);
            },
            onChange: function () { window.location.reload(); }
        });
    }

    // ── Generate Starter Tests (Public/generated-starter-tests.js) ──────────
    // Runs whether or not a draft exists yet — with no draft it reports that
    // one is needed.
    window.initGeneratedStarterTests({
        csrfToken: csrfToken,
        draftID: draftID,
        solutionNotebookURL: (draftID && config.hasSolutionNotebook)
            ? '/instructor/new/draft/solution-notebook?draftID=' + encodeURIComponent(draftID)
            : null
    });

    // ── UWaterloo important-date proximity warning ──────────────────────────
    (function () {
        var dueAtInput = document.getElementById('dueAt');
        var warning    = document.getElementById('uw-date-warning');
        if (!dueAtInput || !warning) return;
        dueAtInput.addEventListener('change', function () { ChickadeeUI.checkUWDates(dueAtInput.value, warning); });
    })();

    // ── Grading mode hint ───────────────────────────────────────────────────
    (function () {
        var sectionSelect = document.getElementById('sectionID');
        var hint = document.getElementById('grading-mode-hint');
        if (!sectionSelect || !hint) return;
        function updateHint() {
            var selected = sectionSelect.options[sectionSelect.selectedIndex];
            var mode = selected ? selected.getAttribute('data-grading-mode') : null;
            if (mode === 'browser') { hint.textContent = 'ⓘ This section uses Student Browser grading by default.'; hint.style.display = ''; }
            else if (mode === 'worker') { hint.textContent = 'ⓘ This section uses Chickadee grading by default.'; hint.style.display = ''; }
            else { hint.style.display = 'none'; }
        }
        sectionSelect.addEventListener('change', updateHint);
        updateHint();
    })();

    // ── Test Editor modal (shell + script renderer config) ──────────────────
    // New-assignment draft: creating scripts only (editing a saved script is
    // not a draft-page flow → no content URL); the body persists via
    // PUT /suite (suite-table's saveScriptViaSuite).  Editing an existing
    // notebook-check row is delegated by the shell itself.
    window.ChickadeeScriptRendererConfig = {
        csrfToken: csrfToken,
        scriptContentURL: null,
        uploadFilesInputID: null
    };
    window.initTestEditorModal({ csrfToken: csrfToken });
})();
