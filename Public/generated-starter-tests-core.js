// Public/generated-starter-tests-core.js
//
// The decisions behind the "Generate Starter Tests" panel
// (generated-starter-tests.js): where a scan reads its notebook from, the
// scan and draft endpoints, the refusals on a non-Python assignment, the
// script each checked function becomes, and the placeholder used when the
// scan carried no template. Nothing here touches the DOM or fetch, so the
// rules run under node (generated-starter-tests-core.test.mjs).
//
// Two of the rules were defects invisible from the template that used to
// hold them: the scan not naming the assignment's language, and the generate
// step reporting a count of files it had refused to write.
(function () {
    'use strict';

    /// Tell the server which language to read, as the family editor's scan
    /// does. Without it the endpoint falls back to the notebook's own
    /// kernelspec, which is not the assignment's declared answer.
    function scanURL(languageName) {
        return '/instructor/scan-notebook'
            + (languageName ? '?language=' + encodeURIComponent(languageName) : '');
    }

    function draftScriptsURL(draftID) {
        return '/instructor/new/draft/scripts?draftID=' + encodeURIComponent(draftID);
    }

    /// Where the scan reads the solution notebook: a file the instructor just
    /// picked wins, else the draft's saved solution, else nothing to scan.
    function scanSource(state) {
        if (state.hasUpload) return 'upload';
        if (state.solutionNotebookURL) return 'saved';
        return 'none';
    }

    /// The refusal for a non-Python assignment. Said up front for the scan,
    /// rather than running it and reporting "No functions found." (the same
    /// answer an empty solution gives); said out loud for the generate step,
    /// which used to filter its work to nothing and then report success.
    function pythonOnlyMessage(step, languageLabel) {
        var head = step === 'scan'
            ? 'Scanning a solution for functions is Python-only'
            : 'Generated starter tests are Python-only';
        var tail = step === 'scan'
            ? '. Use "+ Add Test" in a section to add a test by hand.'
            : '. Use "+ Add Test" in a section to add one by hand.';
        return head + (languageLabel ? ', and this is a ' + languageLabel + ' assignment' : '') + tail;
    }

    function placeholderTemplate(fnName) {
        return '# Test: ' + fnName + '\n# TODO: implement test\npassed("placeholder")\n';
    }

    /// The template the scan already rendered for this function, or the
    /// placeholder when the scan carried none. `type` is the menu value,
    /// `py:differential`, whose id is the part after the colon.
    function generatedTemplate(scannedFunctions, type, fnName) {
        var fn = (scannedFunctions || []).find(function (f) { return f.name === fnName; });
        if (fn && Array.isArray(fn.templates)) {
            var key = type.indexOf(':') === -1 ? type : type.split(':')[1];
            var tpl = fn.templates.find(function (t) { return t.id === key; });
            if (tpl && typeof tpl.content === 'string') return tpl.content;
        }
        return placeholderTemplate(fnName);
    }

    /// The draft-script write for one checked function. These templates ARE
    /// Python and land under a `.py` name, which is why the panel refuses
    /// them on any other language.
    function scriptPayload(fnName, content) {
        return { filename: 'test_' + fnName + '.py', content: content, tier: 'public', points: 1, isTest: true };
    }

    function savedMessage(count) {
        return count + ' test file(s) added to suite.';
    }

    var api = {
        scanURL: scanURL,
        draftScriptsURL: draftScriptsURL,
        scanSource: scanSource,
        pythonOnlyMessage: pythonOnlyMessage,
        placeholderTemplate: placeholderTemplate,
        generatedTemplate: generatedTemplate,
        scriptPayload: scriptPayload,
        savedMessage: savedMessage
    };

    var root = typeof window !== 'undefined' ? window : globalThis;
    root.ChickadeeStarterTestsCore = api;
    // Node export for the .mjs unit tests.
    if (typeof module === 'object' && module.exports) {
        module.exports = api;
    }
}());
