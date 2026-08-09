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
        functionScanning: true,
        expressionEvaluation: true,
        unsupportedCheckKinds: {}
    };

    var _cached = null;

    /// The assignment's authoring facts. Cached per page load; the seed is
    /// static once rendered.
    function facts() {
        if (_cached) return _cached;
        var el = global.document && global.document.getElementById('assignment-language-seed');
        if (!el) { _cached = PYTHON_FALLBACK; return _cached; }
        var parsed;
        try { parsed = JSON.parse(el.textContent || '{}'); } catch (_) { parsed = null; }
        if (!parsed || !parsed.name) { _cached = PYTHON_FALLBACK; return _cached; }
        _cached = {
            name: parsed.name,
            displayName: parsed.displayName || null,
            trueLiteral: parsed.trueLiteral || PYTHON_FALLBACK.trueLiteral,
            falseLiteral: parsed.falseLiteral || PYTHON_FALLBACK.falseLiteral,
            // No null token at all is a legitimate answer — C++ has no null
            // value, and its renderer emits a poison identifier rather than one.
            nullLiteral: parsed.nullLiteral || null,
            functionScanning: parsed.functionScanning !== false,
            expressionEvaluation: parsed.expressionEvaluation !== false,
            unsupportedCheckKinds: parsed.unsupportedCheckKinds || {}
        };
        return _cached;
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

    global.ChickadeeLanguage = {
        isPython: isPython,
        facts: facts,
        checkKindUnsupportedReason: checkKindUnsupportedReason,
        label: label,
        scalarTokens: scalarTokens,
        matchScalarToken: matchScalarToken,
        reprToJSON: reprToJSON
    };
})(typeof globalThis !== 'undefined' ? globalThis : this);
