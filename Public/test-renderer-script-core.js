// Public/test-renderer-script-core.js
//
// The decisions behind the custom-script body renderer
// (test-renderer-script.js): which template groups an assignment may pick
// from, the extension a new file gets, how a filename follows a chosen
// template, which highlighting mode a file wants, how the time limit is
// validated, and the spec each editing mode saves. A classic script, loaded
// before the ES-module renderer, so it needs no CodeMirror import and runs
// under node (test-renderer-script-core.test.mjs).
//
// FAILURE_DETAIL_OPTIONS stays in the renderer: FailureDetailOptionCoverageTests
// reads it out of that file to pin it against FailureDetail.allCases.
(function () {
    'use strict';

    // Which template groups an assignment may pick from.
    //
    // The Python group is Python-only, and used not to be gated at all: an
    // Octave author opened "Write a custom script" and was offered Python
    // templates and a `test_correctness.py` filename. Applying one wrote
    // Python into an Octave suite.
    //
    // The Shell group is offered everywhere because it IS everywhere: `.sh`
    // is the universal test-script contract, and a shell test is a
    // legitimate thing to hand-write in any assignment.
    //
    // The Python group is down to ONE. The other eight duplicated a
    // pattern-family kind that renders in every language, in a better form.
    // `differential` survives because nothing supersedes it yet.
    var PYTHON_TEMPLATE_GROUP = { group: 'Python', items: [
        { value: 'py:differential', label: 'Differential (reference solution)' }
    ] };

    var SHELL_TEMPLATE_GROUP = { group: 'Shell', items: [
        { value: 'sh:always_pass', label: 'Always Pass (placeholder)' },
        { value: 'sh:file_exists', label: 'File Exists Check' },
        { value: 'sh:command_output', label: 'Command Output Check' }
    ] };

    var TIME_LIMIT_MESSAGE = 'Time limit must be between 1 and 600 seconds (or blank for the assignment default).';

    /// The groups this assignment may pick from, in menu order. `language`
    /// is the page's ChickadeeLanguage, or absent on a language-less page.
    function templateGroups(language) {
        if (!language || language.isPython()) {
            return [PYTHON_TEMPLATE_GROUP, SHELL_TEMPLATE_GROUP];
        }
        return [SHELL_TEMPLATE_GROUP];
    }

    /// The extension a new test file gets when the instructor has not named
    /// one, and the extension a chosen template forces. `sh:` templates are
    /// shell whatever the assignment is; everything else takes the
    /// assignment's own extension, which for C++ is `sh` too.
    function extensionFor(templateKey, language) {
        if ((templateKey || '').split(':')[0] === 'sh') return 'sh';
        return language ? language.scriptExtension() : 'py';
    }

    /// The highlighting mode for a file. Python, R and shell are the three
    /// modes the vendored CodeMirror bundle carries; `.lua`, `.m` and `.rkt`
    /// fall back to shell, which is wrong but harmless.
    function highlightModeFor(filename) {
        var ext = (filename || '').split('.').pop().toLowerCase();
        if (ext === 'py') return 'python';
        if (ext === 'r') return 'r';
        return 'shell';
    }

    /// The templates endpoint. The shell templates name a solution file and
    /// an interpreter, so the server needs the assignment's language.
    function templatesURL(languageName) {
        return '/instructor/script-templates'
            + (languageName ? '?language=' + encodeURIComponent(languageName) : '');
    }

    function templateContent(templates, key) {
        return (templates && templates[key]) || '';
    }

    /// The filename after the template changes, or null to leave it alone:
    /// an empty name has nothing to rename, and "Blank" carries no language
    /// of its own.
    function renamedForTemplate(currentName, templateKey, language) {
        var name = (currentName || '').trim();
        if (!name || templateKey === 'blank') return null;
        return name.replace(/\.[^.]*$/, '') + '.' + extensionFor(templateKey, language);
    }

    function defaultFilename(templateKey, language) {
        return 'test_new.' + extensionFor(templateKey, language);
    }

    /// The per-test time limit: blank inherits the assignment default (null);
    /// anything out of range is refused here so the server never sees it.
    function parseTimeLimit(text) {
        var raw = (text || '').trim();
        if (raw === '') return null;
        var seconds = parseInt(raw, 10);
        if (isNaN(seconds) || seconds < 1 || seconds > 600) {
            throw new Error(TIME_LIMIT_MESSAGE);
        }
        return seconds;
    }

    /// The spec a Save persists for the current mode, or a thrown reason.
    function buildSpec(form) {
        var content = form.content || '';
        var hint = (form.hint || '').trim();
        var timeLimitSeconds = parseTimeLimit(form.timeLimitText);
        if (form.mode === 'uploadEdit') {
            return { uploadEdit: true, name: form.uploadEditName, content: content };
        }
        var failureDetail = form.failureDetail ? form.failureDetail : null;
        if (form.mode === 'edit') {
            if (!form.filename) throw new Error('No script selected.');
            return { filename: form.filename, content: content, hint: hint, timeLimitSeconds: timeLimitSeconds, failureDetail: failureDetail };
        }
        var filename = (form.filename || '').trim();
        if (!filename) throw new Error('Enter a filename first.');
        return { filename: filename, content: content, hint: hint, timeLimitSeconds: timeLimitSeconds, failureDetail: failureDetail, tier: 'public', points: 1, isTest: true };
    }

    var api = {
        PYTHON_TEMPLATE_GROUP: PYTHON_TEMPLATE_GROUP,
        SHELL_TEMPLATE_GROUP: SHELL_TEMPLATE_GROUP,
        TIME_LIMIT_MESSAGE: TIME_LIMIT_MESSAGE,
        templateGroups: templateGroups,
        extensionFor: extensionFor,
        highlightModeFor: highlightModeFor,
        templatesURL: templatesURL,
        templateContent: templateContent,
        renamedForTemplate: renamedForTemplate,
        defaultFilename: defaultFilename,
        parseTimeLimit: parseTimeLimit,
        buildSpec: buildSpec
    };

    var root = typeof window !== 'undefined' ? window : globalThis;
    root.ChickadeeScriptRendererCore = api;
    // Node export for the .mjs unit tests.
    if (typeof module === 'object' && module.exports) {
        module.exports = api;
    }
}());
