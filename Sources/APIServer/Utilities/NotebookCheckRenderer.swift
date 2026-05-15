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
func generatedCheckFilename(checkID: String, tier: TestTier) -> String {
    "\(tierFilenamePrefix(tier))check_\(checkID).py"
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
func notebookCheckAllGeneratedFilenames(_ check: NotebookCheck) -> [String] {
    var out = [generatedCheckFilename(checkID: check.id, tier: check.tier)]
    switch check.kind {
    case .dataFrameShape, .dataFrameColumns, .numericArrayClose,
        .figureCount, .cellContains, .functionExists,
        .variableExists, .astStructure:
        break  // no sidecars
    case .dataFrameEquality, .seriesEquality:
        out.append(expectedCSVSidecarFilename(checkID: check.id))
    }
    return out
}

/// Top-level entry point.  Returns the test script plus any sidecar
/// files the kind needs.
func renderNotebookCheck(_ check: NotebookCheck) -> GeneratedCheck {
    let hash = notebookCheckSpecHash(check)
    let source: String
    let displayName: String
    var sidecars: [String: String] = [:]
    switch check.kind {
    case .dataFrameShape:
        source = renderDataFrameShape(check, specHash: hash)
        displayName = check.name ?? defaultDataFrameShapeLabel(check)
    case .dataFrameColumns:
        source = renderDataFrameColumns(check, specHash: hash)
        displayName = check.name ?? defaultDataFrameColumnsLabel(check)
    case .dataFrameEquality:
        source = renderDataFrameEquality(check, specHash: hash)
        displayName = check.name ?? defaultDataFrameEqualityLabel(check)
        sidecars[expectedCSVSidecarFilename(checkID: check.id)] =
            check.expectedCSV ?? ""
    case .seriesEquality:
        source = renderSeriesEquality(check, specHash: hash)
        displayName = check.name ?? defaultSeriesEqualityLabel(check)
        sidecars[expectedCSVSidecarFilename(checkID: check.id)] =
            check.expectedCSV ?? ""
    case .numericArrayClose:
        source = renderNumericArrayClose(check, specHash: hash)
        displayName = check.name ?? defaultNumericArrayCloseLabel(check)
    case .figureCount:
        source = renderFigureCount(check, specHash: hash)
        displayName = check.name ?? defaultFigureCountLabel(check)
    case .cellContains:
        source = renderCellContains(check, specHash: hash)
        displayName = check.name ?? defaultCellContainsLabel(check)
    case .functionExists:
        source = renderFunctionExists(check, specHash: hash)
        displayName = check.name ?? defaultFunctionExistsLabel(check)
    case .variableExists:
        source = renderVariableExists(check, specHash: hash)
        displayName = check.name ?? defaultVariableExistsLabel(check)
    case .astStructure:
        source = renderASTStructure(check, specHash: hash)
        displayName = check.name ?? defaultASTStructureLabel(check)
    }

    let script = GeneratedScript(
        filename: generatedCheckFilename(checkID: check.id, tier: check.tier),
        source: source,
        tier: check.tier,
        points: check.points,
        displayName: displayName,
        caseKey: "",  // unused for checks; one file per check
        familyID: ""  // unused for checks; the route field is generatedByCheck
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
