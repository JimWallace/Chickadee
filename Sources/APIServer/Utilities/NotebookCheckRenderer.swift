// APIServer/Utilities/NotebookCheckRenderer.swift
//
// Expands a NotebookCheck into a single deterministic Python test script,
// optionally with sidecar files (e.g. `_expected_<id>.csv` for
// `.dataFrameEquality`).  Mirrors PatternFamilyRenderer's contract:
// pure function, byte-stable output for byte-stable input, generated
// source uses test_runtime helpers so the runner can't tell it apart
// from a hand-authored script.

import Core
import Foundation

/// Stable filename for one check's test script.  Format:
/// `{tier}check_{checkID}.py`.  The "check_" infix distinguishes from
/// pattern-family files ("test_") so a glance at the zip listing tells
/// you which generator produced the file; the runner doesn't care.
func generatedCheckFilename(
    checkID: String, tier: TestTier, language: AssignmentLanguage
) -> String {
    "\(tierFilenamePrefix(tier))check_\(checkID).\(language.generatedScriptExtension)"
}

/// Stable filename for a check's expected-data sidecar CSV.  Used by
/// `.dataFrameEquality` and `.seriesEquality`.  Leading underscore keeps
/// it out of the way alphabetically and avoids collision with
/// instructor-bundled or student-uploaded data files.
func expectedCSVSidecarFilename(checkID: String) -> String {
    "_expected_\(checkID).csv"
}

/// One check's full output: the test script plus zero or more sidecar
/// files (filename → contents).  The apply path writes both into the
/// test setup zip in a single mutation pass and tracks all filenames
/// for the diff/delete cycle.
struct GeneratedCheck: Equatable {
    let script: GeneratedScript
    let sidecars: [String: String]
}

/// All filenames a check **would** produce (script + sidecars).  Used
/// when diffing old/new specs so stale sidecars get cleaned up alongside
/// the test scripts.  Mirrors `patternFamilyAllGeneratedFilenames`.
func notebookCheckAllGeneratedFilenames(
    _ check: NotebookCheck, language: AssignmentLanguage
) -> [String] {
    var out = [generatedCheckFilename(checkID: check.id, tier: check.tier, language: language)]
    // Sidecars are language-neutral data (the expected-values CSV), so the
    // same filenames apply either way.
    out.append(contentsOf: notebookCheckKindHandler(for: check.kind).sidecars(check).keys.sorted())
    return out
}

/// Top-level entry point.  Returns the test script plus any sidecar
/// files the kind needs.  Python routes through the per-kind handlers (whose
/// bytes are pinned by `spec_hash` / `TestSetupCache`); R has its own renderer
/// covering the data-frame kinds, with the rest gated at save time by
/// `notebookCheckKindSupportsR`.
func renderNotebookCheck(
    _ check: NotebookCheck, language: AssignmentLanguage
) -> GeneratedCheck {
    let hash = notebookCheckSpecHash(check)
    let handler = notebookCheckKindHandler(for: check.kind)
    let source: String
    switch language {
    case .python: source = handler.render(check, specHash: hash)
    case .r: source = renderRNotebookCheck(check, specHash: hash)
    case .lua: source = renderLuaNotebookCheck(check, specHash: hash)
    case .octave: source = renderOctaveNotebookCheck(check, specHash: hash)
    case .cpp:
        // Unreachable through authoring — `validateKindSupport` refuses every
        // kind for C++ (no notebook workflow to check). Kept total with a
        // script that errors loudly rather than grades, the same backstop
        // posture as the renderers' other unreachable arms.
        source = """
            #!/bin/sh
            echo "Notebook checks are not available for C++ assignments." 1>&2
            exit 2
            """
    case .racket:
        // Unreachable for the same reason as C++, and kept total the same
        // way — but as a `.rkt` module, since Racket's generated extension is
        // its own and the runner hands this file to `racket`.
        source = """
            #lang racket/base
            (eprintf "Notebook checks are not available for Racket assignments.\\n")
            (exit 2)
            """
    }
    let displayName = check.name ?? handler.defaultLabel(check)
    let sidecars = handler.sidecars(check)

    let script = GeneratedScript(
        filename: generatedCheckFilename(
            checkID: check.id, tier: check.tier, language: language),
        source: source,
        tier: check.tier,
        points: check.points,
        displayName: displayName,
        caseKey: "",  // unused for checks; one file per check
        familyID: "",  // unused for checks; the route field is generatedByCheck
        // The check's per-test limit (0/negative → nil = inherit the default).
        // The apply path re-derives this from `check.timeLimitSeconds` when it
        // builds the entry; carrying it here keeps GeneratedScript self-describing.
        timeLimitSeconds: normalizedGeneratedTimeLimit(check.timeLimitSeconds)
    )
    return GeneratedCheck(script: script, sidecars: sidecars)
}

/// 16-character hex prefix of a SHA-256 over the check spec.  Stable for a
/// given spec; bust the manifest cache when anything about the check
/// changes.  Mirrors `patternFamilySpecHash`.
func notebookCheckSpecHash(_ check: NotebookCheck) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = (try? encoder.encode(check)) ?? Data()
    return String(sha256HexDigest(data).prefix(16))
}

// MARK: - Helpers
//
// `tierFilenamePrefix(_:)` and `escapeForPythonStringLiteral(_:)` live in
// PythonScriptHelpers.swift — shared with PatternFamilyRenderer.
