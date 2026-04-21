// APIServer/Utilities/PatternFamilyRenderer.swift
//
// Expands a PatternFamily into a deterministic set of Python test scripts
// plus matching TestSuiteEntry metadata.  Rendering is pure: identical input
// produces byte-identical output so the same spec across regenerations
// yields stable diffs.
//
// The generated source uses the same test_runtime helpers and rich-feedback
// format as the hand-authored templates, so the runner cannot distinguish a
// generated script from one an instructor wrote by hand.

import Foundation
import Crypto
import Core

/// One rendered case: a filename, the Python source to write to the zip, and
/// enough metadata to construct a TestSuiteEntry that points back at the
/// family via `generatedBy`.
struct GeneratedScript: Equatable {
    let filename: String
    let source: String
    let tier: TestTier
    let points: Int
    let displayName: String
    let caseKey: String
    let familyID: String
}

/// Top-level entry point.  Returns one `GeneratedScript` per **enabled** case
/// in the family; disabled cases are skipped.  Ordering follows `family.cases`.
func renderPatternFamily(_ family: PatternFamily) -> [GeneratedScript] {
    let hash = patternFamilySpecHash(family)
    return family.cases.compactMap { c in
        guard c.enabled else { return nil }
        return renderCase(family: family, case: c, specHash: hash)
    }
}

/// All filenames this family **would** produce if every case were enabled.
/// Used when diffing old/new specs so we can detect stale files that need
/// deleting, even for cases that were previously disabled.
func patternFamilyAllGeneratedFilenames(_ family: PatternFamily) -> [String] {
    family.cases.map { c in
        generatedScriptFilename(
            familyID: family.id,
            caseKey: c.key,
            tier: c.resolvedTier(defaults: family.defaults)
        )
    }
}

/// Stable filename for one case.  Format: `{tier}test_{familyID}_{caseKey}.py`.
/// The tier prefix mirrors the convention used elsewhere in the codebase so
/// the runner's student-module loader correctly excludes generated test files.
func generatedScriptFilename(familyID: String, caseKey: String, tier: TestTier) -> String {
    "\(tierFilenamePrefix(tier))test_\(familyID)_\(caseKey).py"
}

/// 16-character hex prefix of a SHA-256 over the canonical JSON encoding of
/// the family (sorted keys).  Stable for a given spec; changes when anything
/// about the family changes.
func patternFamilySpecHash(_ family: PatternFamily) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = (try? encoder.encode(family)) ?? Data()
    let digest = SHA256.hash(data: data)
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    return String(hex.prefix(16))
}

// MARK: - Per-kind dispatch

private func renderCase(family: PatternFamily, case c: PatternCase, specHash: String) -> GeneratedScript {
    let source: String
    switch family.kind {
    case .boundaryEquality:
        source = renderBoundaryEquality(family: family, case: c, specHash: specHash)
    }

    let tier = c.resolvedTier(defaults: family.defaults)
    return GeneratedScript(
        filename:    generatedScriptFilename(familyID: family.id, caseKey: c.key, tier: tier),
        source:      source,
        tier:        tier,
        points:      c.resolvedPoints(defaults: family.defaults),
        displayName: c.label,
        caseKey:     c.key,
        familyID:    family.id
    )
}

// MARK: - boundaryEquality

private func renderBoundaryEquality(family: PatternFamily, case c: PatternCase, specHash: String) -> String {
    // Variable names: prefer paramNames when provided, fall back to arg_1,
    // arg_2, …  Validation guarantees args.count == paramNames.count when
    // paramNames is non-empty.
    let argNames: [String] = {
        if !family.paramNames.isEmpty { return family.paramNames }
        return c.args.indices.map { "arg_\($0 + 1)" }
    }()

    let declLines = zip(argNames, c.args)
        .map { "\($0.0) = \($0.1.pythonLiteral)" }
        .joined(separator: "\n")

    let callArgs = argNames.joined(separator: ", ")

    let inputLineLiteral: String
    if argNames.isEmpty {
        inputLineLiteral = #""  input:    (no input)\n""#
    } else {
        let preview = argNames.map { "\($0)={\($0)!r}" }.joined(separator: ", ")
        inputLineLiteral = "f\"  input:    \(preview)\\n\""
    }

    let callReprExpr = argNames.map { "{\($0)!r}" }.joined(separator: ", ")

    let resolvedHint = c.resolvedHint(defaults: family.defaults)
    let hintLine = resolvedHint.map { "\"Hint: \(escapeForPythonStringLiteral($0))\"" } ?? "\"\""

    // The `# Test:` line comes FIRST so test_runtime's _first_comment_label()
    // picks up the case label.  Provenance comes second — a reader opening
    // this file sees which family produced it, but the runtime label stays
    // student-readable.
    return """
    # Test: \(c.label)
    # Generated from pattern family \"\(escapeForPythonStringLiteral(family.name))\" [\(family.id)] spec_hash=\(specHash) — edit the family, not this file.

    \(declLines.isEmpty ? "# (no input arguments)" : declLines)
    expected = \(c.expected.pythonLiteral)

    try:
        result = student_module.\(family.functionName)(\(callArgs))
    except Exception as ex:
        failed(
            "unexpected exception\\n"
            \(inputLineLiteral)
            f"  expected: {expected!r}\\n"
            f"  error:    {type(ex).__name__}: {ex}\\n"
            \(hintLine)
        )

    if result != expected:
        failed(
            "wrong value\\n"
            \(inputLineLiteral)
            f"  expected: {expected!r}\\n"
            f"  got:      {result!r}\\n"
            \(hintLine)
        )

    passed(f"\(family.functionName)(\(callReprExpr)) returned {result!r}")
    """
}

// MARK: - Helpers

private func tierFilenamePrefix(_ tier: TestTier) -> String {
    switch tier {
    case .pub:     return "public"
    case .release: return "release"
    case .secret:  return "secret"
    }
}

/// Escapes a string for embedding inside a Python double-quoted literal in
/// rendered source.  Handles the characters that appear in family metadata
/// (backslash, double-quote, newline).
private func escapeForPythonStringLiteral(_ s: String) -> String {
    var out = ""
    for ch in s.unicodeScalars {
        switch ch {
        case "\\": out += #"\\"#
        case "\"": out += #"\""#
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if ch.value < 0x20 {
                out += String(format: "\\x%02x", ch.value)
            } else {
                out.unicodeScalars.append(ch)
            }
        }
    }
    return out
}
