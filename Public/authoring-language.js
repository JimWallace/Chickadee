// Public/authoring-language.js
//
// The assignment language, for every authoring editor in the browser.
//
// WHY THIS IS A SHARED MODULE AND NOT A HELPER IN EACH EDITOR. The
// pattern-family editor and the Global/Section Inputs editors both let an
// instructor type a value, and both parsed it by Python's rules — `True`,
// `False`, `None`, and a Python-repr rewrite — on all six languages. Fixing the
// family editor first and then writing the same logic again in the inputs core
// would be the exact duplication this whole pass has been removing: two copies
// of "how does this language spell true", free to disagree.
//
// The facts come from `#assignment-language-seed`, written by
// `AuthoringLanguageFacts` on the server. The scalar spellings there are
// COMPUTED by `JSONValue.literal(_:)` — the same call that renders the real
// generated test — so what an instructor is shown and what will actually be
// generated cannot drift.
//
// An assignment with no language, or a page with no seed, falls back to
// Python's spellings, which is exactly what these editors did before.

(function (global) {
    'use strict';

    var PYTHON_FALLBACK = {
        name: null,
        displayName: null,
        trueLiteral: 'True',
        falseLiteral: 'False',
        nullLiteral: 'None',
        scriptExtension: 'py',
        functionScanning: true,
        expressionEvaluation: true,
        // No worker of its own: which worker runs is the seed's answer, never
        // this file's, so a page without one computes on the server.
        autoComputeWorker: null,
        autoComputeRuntimeSource: null,
        unsupportedCheckKinds: {},
        languageByScriptExtension: {}
    };

    var _cached = null;
    var _cachedSeed = null;

    /// The assignment's authoring facts.
    ///
    /// Cached per seed ELEMENT, not per page load. The workbench swaps its edit
    /// half after an in-place save, and the new half carries a new seed. That
    /// save can change the language, so a new seed element is read again
    /// (#1957). One render keeps one seed element, so the cache still holds
    /// for the life of a render.
    function facts() {
        var el = (global.document && global.document.getElementById('assignment-language-seed')) || null;
        if (_cached && el === _cachedSeed) return _cached;
        _cachedSeed = el;
        if (!el) { _cached = PYTHON_FALLBACK; return _cached; }
        var parsed;
        try { parsed = JSON.parse(el.textContent || '{}'); } catch (_) { parsed = null; }
        // The extension map covers every language, so a language-less
        // assignment carries it too.
        var byExtension = (parsed && parsed.languageByScriptExtension) || {};
        if (!parsed || !parsed.name) {
            _cached = Object.assign({}, PYTHON_FALLBACK, { languageByScriptExtension: byExtension });
            return _cached;
        }
        _cached = {
            name: parsed.name,
            displayName: parsed.displayName || null,
            trueLiteral: parsed.trueLiteral || PYTHON_FALLBACK.trueLiteral,
            falseLiteral: parsed.falseLiteral || PYTHON_FALLBACK.falseLiteral,
            // No null token at all is a legitimate answer — C++ has no null
            // value, and its renderer emits a poison identifier rather than one.
            nullLiteral: parsed.nullLiteral || null,
            scriptExtension: parsed.scriptExtension || PYTHON_FALLBACK.scriptExtension,
            functionScanning: parsed.functionScanning !== false,
            expressionEvaluation: parsed.expressionEvaluation !== false,
            autoComputeWorker: parsed.autoComputeWorker || null,
            autoComputeRuntimeSource: parsed.autoComputeRuntimeSource || null,
            unsupportedCheckKinds: parsed.unsupportedCheckKinds || {},
            languageByScriptExtension: byExtension
        };
        return _cached;
    }

    /// The language token a file's own extension implies (R for
    /// `helper.R`), or null for an extension that implies none. Read from the
    /// seed, which derives it from the same mapping the runner uses.
    function scriptLanguageFor(filename) {
        var name = filename || '';
        var dot = name.lastIndexOf('.');
        if (dot < 0) return null;
        var map = facts().languageByScriptExtension || {};
        var ext = name.slice(dot + 1).toLowerCase();
        return Object.prototype.hasOwnProperty.call(map, ext) ? map[ext] : null;
    }

    /// "R" / "Lua" / …, or "" when the assignment declares no language.
    function label() {
        return facts().displayName || '';
    }

    /// The scalar spellings, as `{ token, value, kind }`.
    function scalarTokens() {
        var f = facts();
        return [
            { token: f.trueLiteral, value: true, kind: 'bool' },
            { token: f.falseLiteral, value: false, kind: 'bool' },
            { token: f.nullLiteral, value: null, kind: 'null' }
        ].filter(function (t) { return typeof t.token === 'string' && t.token !== ''; });
    }

    /// A scalar match for `trimmed`, or null.
    ///
    /// This is what an R author typing the boolean true needed and did not
    /// have: `TRUE` is not JSON, the repr rewrite only knew Python's
    /// case-sensitive spelling, and the bare-string branch caught it — so the
    /// stored value was the STRING, silently, in something that decides marks.
    function matchScalarToken(trimmed) {
        var tokens = scalarTokens();
        for (var i = 0; i < tokens.length; i++) {
            if (tokens[i].token === trimmed) {
                return { value: tokens[i].value, kind: tokens[i].kind };
            }
        }
        return null;
    }

    /// Rewrites a value pasted in the assignment language's own syntax to JSON.
    ///
    /// Tokens are rewritten BEFORE the quote swap, because Racket spells null
    /// `'null` — swapping first would turn it into `"null` and lose it. Word
    /// boundaries are applied only where the token actually starts or ends with
    /// a word character, since `#t` never matches under a leading `\b`.
    function reprToJSON(trimmed) {
        var out = String(trimmed);
        scalarTokens().forEach(function (t) {
            var esc = t.token.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
            var pre = /^\w/.test(t.token) ? '\\b' : '';
            var post = /\w$/.test(t.token) ? '\\b' : '';
            var json = (t.value === null) ? 'null' : String(t.value);
            out = out.replace(new RegExp(pre + esc + post, 'g'), json);
        });
        // Only when no double quotes exist already, so a string mixing an
        // apostrophe inside double quotes is not broken.
        if (out.indexOf('"') === -1) out = out.replace(/'/g, '"');
        return out;
    }

    /// The kind of a parsed value, for the editors' cues.
    function kindOf(v) {
        if (Array.isArray(v)) return 'list';
        if (v === null) return 'null';
        if (typeof v === 'object') return 'dict';
        if (typeof v === 'boolean') return 'bool';
        if (typeof v === 'number') return 'number';
        if (typeof v === 'string') return 'string';
        return 'scalar';
    }

    /// Parses a value an instructor typed, by the assignment language's rules:
    /// its own true/false/null spellings, then JSON, then a value pasted in the
    /// language's own syntax (rewritten by `reprToJSON`), then a bare string.
    ///
    /// Returns `{ ok, value, kind, strict }`. `ok` is false only for empty
    /// text. `strict` is true when the text parsed exactly, as a scalar
    /// spelling or as JSON, and false when it was rewritten or kept as a bare
    /// string, which the editors flag for a second look.
    ///
    /// The ONE parser for every authoring editor (#1958). There were three: the
    /// inputs editors and the family Variables table read the language's
    /// spellings but disagreed on whether a scalar is strict, and the case cells
    /// accepted only Python's `True` / `False` / `None`, so an R author typing
    /// `TRUE` as a case argument stored the STRING "TRUE".
    ///
    /// `options.rewriteRepr: false` skips the rewrite step. Case cells pass it:
    /// a stored string argument is shown back without quotes, so a string such
    /// as `'hello'` would silently become `hello` the next time the family was
    /// saved.
    function parseValue(raw, options) {
        var text = String(raw == null ? '' : raw);
        var trimmed = text.trim();
        if (trimmed === '') return { ok: false, value: undefined, kind: 'empty', strict: false };
        var scalar = matchScalarToken(trimmed);
        if (scalar) return { ok: true, value: scalar.value, kind: scalar.kind, strict: true };
        try {
            var v = JSON.parse(trimmed);
            return { ok: true, value: v, kind: kindOf(v), strict: true };
        } catch (_) { /* fall through */ }
        var rewrite = !(options && options.rewriteRepr === false);
        // Only when no double quotes exist already, so a string mixing an
        // apostrophe inside double quotes is not broken.
        if (rewrite && trimmed.indexOf('"') === -1) {
            try {
                var v2 = JSON.parse(reprToJSON(trimmed));
                return { ok: true, value: v2, kind: kindOf(v2), strict: false };
            } catch (_) { /* fall through */ }
        }
        return { ok: true, value: text, kind: 'string', strict: false };
    }

    /// The text a value cell shows for a STRING value, chosen so that reading
    /// the cell back gives the same string (#2381).
    ///
    /// A plain string shows without quotes, so the common case reads
    /// naturally. A string that the cell would read as something else shows
    /// JSON-quoted: one that parses as a number, a boolean, null or JSON
    /// (`"42"`, `"true"`), a string that looks like a `$name` reference, and a
    /// string with a newline or tab, which a single-line input cannot hold.
    /// An empty string stays empty; a caller whose empty cell means
    /// "omitted" quotes it itself.
    function stringCellText(s) {
        var text = String(s);
        if (text === '') return '';
        if (/[\n\r\t]/.test(text) || /^\$\S+$/.test(text.trim())) {
            return JSON.stringify(text);
        }
        var parsed = parseValue(text, { rewriteRepr: false });
        return (parsed.ok && parsed.value === text) ? text : JSON.stringify(text);
    }

    /// The title of a value cell that `parseValue` did not read exactly, or ''
    /// when it did. The editors give both loose readings the same amber cue,
    /// but they have different causes, so the title names which one (#1996):
    /// text that matched nothing is kept as a string, and a value pasted in
    /// the language's own syntax is rewritten to JSON. The bare-string
    /// fallback is the only reading that returns the text unchanged. A title
    /// is one phrase; docs/inputs.md ("The amber cue on a value") explains
    /// both, and the note under each editor links it.
    function looseValueTitle(raw) {
        var parsed = parseValue(raw);
        if (!parsed.ok || parsed.strict) return '';
        return parsed.value === String(raw == null ? '' : raw)
            ? 'Kept as text'
            : 'Read as a pasted literal';
    }

    /// Why this language cannot use notebook-check `kind`, or null when it can.
    ///
    /// Derived server-side from the SAME predicate the save-time refusal uses,
    /// so the "Add Test" menu and the rejection cannot disagree. Before it, the
    /// menu offered all ten kinds on every assignment and the instructor found
    /// out by being refused.
    function checkKindUnsupportedReason(kind) {
        var map = facts().unsupportedCheckKinds || {};
        return map[kind] || null;
    }

    /// True when this assignment is Python, or declares no language.
    ///
    /// Guards the create page's "add generated tests" button, whose templates
    /// ARE Python and which writes them under a `.py` name. The only way to
    /// reach that button is a successful function scan, which is Python-only —
    /// so this is an assertion, not a branch. It matters because a `.py` landing
    /// in another language's suite is what makes the whole assignment resolve as
    /// Python.
    function isPython() {
        var name = facts().name;
        return !name || name === 'python';
    }

    /// The extension a new hand-written test should get: `py`, `R`, `lua`,
    /// `m`, `rkt`, or `sh` for C++.
    function scriptExtension() {
        return facts().scriptExtension || 'py';
    }

    /// Whether scanning the solution notebook for function definitions can
    /// work here at all.
    ///
    /// Read this BEFORE offering the scan, not after running it. The scan does
    /// report its own reason when asked, but a control that invites a click and
    /// then explains itself is worse than one that explains itself first.
    function canScanFunctions() {
        return facts().functionScanning !== false;
    }

    /// Whether a case's expected value can be computed by running the solution.
    ///
    /// True for all six languages today — every one has an interpreter on the
    /// server image, so `PersonalizationEvaluator` can answer. It is read
    /// rather than assumed because the failure it guards is silent: a seventh
    /// language whose driver is not yet written reports false here, and an
    /// unread flag would leave the editor auto-filling Expected cells from a
    /// server that refuses.
    function canEvaluateExpressions() {
        return facts().expressionEvaluation !== false;
    }

    /// The in-page worker that computes a case's expected value, or null when
    /// the server computes it instead (C++, Racket, Java, or no language).
    ///
    /// The pattern-family editor called this from #1322 on, but it was never
    /// added here, so auto-compute threw a TypeError for every language and
    /// the cell stayed on "computing…" (#1956).
    function autoComputeWorker() {
        return facts().autoComputeWorker || null;
    }

    global.ChickadeeLanguage = {
        isPython: isPython,
        facts: facts,
        checkKindUnsupportedReason: checkKindUnsupportedReason,
        label: label,
        scalarTokens: scalarTokens,
        matchScalarToken: matchScalarToken,
        reprToJSON: reprToJSON,
        parseValue: parseValue,
        stringCellText: stringCellText,
        looseValueTitle: looseValueTitle,
        scriptExtension: scriptExtension,
        canScanFunctions: canScanFunctions,
        canEvaluateExpressions: canEvaluateExpressions,
        autoComputeWorker: autoComputeWorker,
        scriptLanguageFor: scriptLanguageFor
    };
})(typeof globalThis !== 'undefined' ? globalThis : this);
