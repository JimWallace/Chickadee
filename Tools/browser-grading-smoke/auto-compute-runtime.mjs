// Tools/browser-grading-smoke/auto-compute-runtime.mjs
//
// Reads the auto-compute runtime a language's in-page eval worker is seeded
// with, out of the Swift constants that define it.
//
// `AssignmentLanguage.autoComputeRuntimeSource` is what the server actually
// sends the worker. Anything testing that worker has to send the same bytes, or
// it proves a runtime nobody runs — so this extracts them rather than restating
// them. Two consumers: the browser-grading smoke (which boots a real kernel)
// and Tests/BrowserRunnerJSTests (which runs the snippets under a plain
// interpreter).
//
// The COMPOSITION — which constants, in what order — is still written twice,
// here and in the Swift switch. `LuaAutoComputeRuntimeTests` is the guard: it
// fails if the Swift arm stops being exactly this list, naming this file.

import fs from 'node:fs/promises';
import path from 'node:path';

/// Which Swift constants compose each language's runtime, in order.
/// Mirrors the arms of `AssignmentLanguage.autoComputeRuntimeSource`.
const COMPOSITION = {
    r: {
        file: 'Sources/Core/RPersonalizationRuntime.swift',
        constants: ['chickadeeJSONStringRSource'],
    },
    octave: {
        file: 'Sources/Core/OctavePersonalizationRuntime.swift',
        constants: [
            'chickadeeSerializeOctaveSource',
            'chickadeeEscapeStringOctaveSource',
        ],
    },
    lua: {
        file: 'Sources/Core/LuaPersonalizationRuntime.swift',
        constants: [
            'chickadeeNullTableLuaSource',
            'chickadeeSerializeLuaSource',
            'chickadeeJSONStringLuaSource',
            'chickadeeAutoComputeExportsLuaSource',
        ],
    },
};

/// The text of one multi-line Swift string constant, dedented as the compiler
/// dedents it (by the closing delimiter's own indentation) and with any
/// `\(otherConstant)` interpolation resolved from the same file.
///
/// The interpolation step is not decoration: the Lua null sentinel is defined
/// once and spliced into the table that binds it, so an extractor that took the
/// raw text would seed `chickadee.NULL = chickadee.NULL or \(…)` — a syntax
/// error, and one that only shows up when a case actually contains a null.
function extractConstant(swift, name, seen = new Set()) {
    if (seen.has(name)) {
        throw new Error(`circular Swift constant interpolation at ${name}`);
    }
    seen.add(name);
    const assignment = String.raw`\b${name}\s*(?::\s*String\s*)?=\s*`;
    const multiline = new RegExp(assignment + String.raw`#?"""\n([\s\S]*?)\n([ \t]*)"""#?`);
    // A one-line RAW literal (`#"…"#`), which is how the null sentinel is
    // written. Only the raw form is read: a plain `"…"` would need Swift's
    // escape processing, and no runtime constant is written that way.
    const singleLine = new RegExp(assignment + String.raw`#"([^\n]*)"#`);
    const match = multiline.exec(swift) || singleLine.exec(swift);
    if (!match) {
        throw new Error(
            `could not find the Swift constant ${name} — the auto-compute runtime `
            + 'cannot be probed with the bytes the server actually seeds');
    }
    const [, body, closingIndent] = match;
    const dedented = closingIndent
        ? body.split('\n').map(
            (line) => (line.startsWith(closingIndent) ? line.slice(closingIndent.length) : line)
        ).join('\n')
        : body;
    return dedented.replace(/\\\((\w+)\)/g, (_, reference) =>
        extractConstant(swift, reference, seen));
}

/// The runtime source for `language`, exactly as the server composes it.
export async function readAutoComputeRuntimeSource(language, repoRoot) {
    const composition = COMPOSITION[language];
    if (!composition) {
        throw new Error(`no auto-compute runtime composition recorded for ${language}`);
    }
    const swift = await fs.readFile(path.resolve(repoRoot, composition.file), 'utf8');
    return composition.constants
        .map((name) => extractConstant(swift, name))
        .join('\n\n');
}
