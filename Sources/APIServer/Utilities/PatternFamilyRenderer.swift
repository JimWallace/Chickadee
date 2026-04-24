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
///
/// `sectionVariables` (v0.4.100+) are prepended to every generated test
/// before the family's own variables, so variables declared on the section
/// are visible to each case's Python assignments.  A family variable with
/// the same name as a section variable shadows it (standard Python "last
/// assignment wins"); the spec_hash reflects both lists.
func renderPatternFamily(
    _ family: PatternFamily,
    sectionVariables: [FamilyVariable] = []
) -> [GeneratedScript] {
    let hash = patternFamilySpecHash(family, sectionVariables: sectionVariables)
    return family.cases.compactMap { c in
        guard c.enabled else { return nil }
        return renderCase(family: family, case: c,
                          sectionVariables: sectionVariables, specHash: hash)
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
func patternFamilySpecHash(
    _ family: PatternFamily,
    sectionVariables: [FamilyVariable] = []
) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let familyData = (try? encoder.encode(family)) ?? Data()
    // Mix section variables into the hash so changing them busts the
    // manifest cache the same way changing the family itself does.
    let sectionVarsData = (try? encoder.encode(sectionVariables)) ?? Data()
    var buf = Data()
    buf.append(familyData)
    buf.append(sectionVarsData)
    let digest = SHA256.hash(data: buf)
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    return String(hex.prefix(16))
}

// MARK: - Per-kind dispatch

private func renderCase(
    family: PatternFamily,
    case c: PatternCase,
    sectionVariables: [FamilyVariable],
    specHash: String
) -> GeneratedScript {
    let source: String
    switch family.kind {
    case .boundaryEquality:
        source = renderBoundaryEquality(family: family, case: c,
                                         sectionVariables: sectionVariables, specHash: specHash)
    case .approximateEquality:
        source = renderApproximateEquality(family: family, case: c,
                                            sectionVariables: sectionVariables, specHash: specHash)
    case .variableEquality:
        source = renderVariableEquality(family: family, case: c,
                                         sectionVariables: sectionVariables, specHash: specHash)
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

/// Per-case call context: a bundle of the four Python fragments every kind
/// needs when rendering a function call with optional omitted parameters.
/// Empty cells on defaulted params are skipped in the declarations and
/// omitted from the call; the call switches from positional to keyword
/// form after the first gap so Python's argument-binding rules hold.
private struct CallContext {
    /// One line per provided arg: `name = <pythonLiteral>`.  Omitted args
    /// get no declaration.
    let declLines: String
    /// The parenthesised arg list as it appears inside
    /// `student_module.func(<here>)`.  Leading contiguous provided args are
    /// positional; anything after a gap becomes a kwarg.  Empty when the
    /// instructor provided no args at all.
    let callArgs: String
    /// Python expression interpolated into the `input: …` f-string at the
    /// top of every failure message.  Only provided args appear.
    let inputLineLiteral: String
    /// Expression interpolated into the `passed(...)` / `... returned`
    /// success message to echo the arg values back to the student.
    let callReprExpr: String
}

private func callContext(for family: PatternFamily, case c: PatternCase) -> CallContext {
    let argNames: [String] = {
        if !family.paramNames.isEmpty { return family.paramNames }
        return c.args.indices.map { "arg_\($0 + 1)" }
    }()

    // argsProvided == [] (empty) means pre-v0.4.94 behaviour: every arg
    // was provided.  Non-empty must match args.count (enforced by the
    // PatternCase initialiser).  Pad defensively to `argNames.count` in
    // case paramNames and args have drifted apart (validation would
    // normally catch that, but failing closed is cheaper than crashing).
    let provided: [Bool] = {
        guard !c.argsProvided.isEmpty else {
            return Array(repeating: true, count: argNames.count)
        }
        if c.argsProvided.count == argNames.count { return c.argsProvided }
        return (0..<argNames.count).map { i in
            i < c.argsProvided.count ? c.argsProvided[i] : true
        }
    }()

    // argVarRefs == [] (empty) means "no variable references" — the
    // pre-v0.4.94 shape where every arg is a literal.  A non-nil entry
    // at position `i` names a family variable to pass instead of the
    // literal.  Padded defensively for the same reason as `provided`.
    let varRefs: [String?] = {
        guard !c.argVarRefs.isEmpty else {
            return Array(repeating: nil, count: argNames.count)
        }
        if c.argVarRefs.count == argNames.count { return c.argVarRefs }
        return (0..<argNames.count).map { i in
            i < c.argVarRefs.count ? c.argVarRefs[i] : nil
        }
    }()

    var declLineList:     [String] = []
    var callArgsParts:    [String] = []
    var previewParts:     [String] = []
    var reprParts:        [String] = []
    var sawOmission = false
    for (idx, name) in argNames.enumerated() {
        let isProvided = idx < provided.count ? provided[idx] : true
        if !isProvided {
            sawOmission = true
            continue
        }
        // Variable reference: assign the param name directly from the
        // family variable (no local literal declaration needed — the
        // variable already lives at module scope, prepended by
        // `familyVariableDecls()`).
        let varRef = idx < varRefs.count ? varRefs[idx] : nil
        if let refName = varRef {
            declLineList.append("\(name) = \(refName)")
        } else if idx < c.args.count {
            declLineList.append("\(name) = \(c.args[idx].pythonLiteral)")
        }
        // Switch to kwargs the moment we pass any omitted arg — Python
        // forbids positional-after-keyword, and `fn(a, c=...)` is how we
        // tell Python "pass a positionally, skip b, fill c".
        callArgsParts.append(sawOmission ? "\(name)=\(name)" : name)
        previewParts.append("\(name)={\(name)!r}")
        reprParts.append("{\(name)!r}")
    }

    let inputLineLiteral: String
    if previewParts.isEmpty {
        inputLineLiteral = #""  input:    (no input)\n""#
    } else {
        inputLineLiteral = "f\"  input:    \(previewParts.joined(separator: ", "))\\n\""
    }

    return CallContext(
        declLines:        declLineList.joined(separator: "\n"),
        callArgs:         callArgsParts.joined(separator: ", "),
        inputLineLiteral: inputLineLiteral,
        callReprExpr:     reprParts.joined(separator: ", ")
    )
}

/// Renders the `name = <pythonLiteral>` preamble for every variable in
/// scope for this generated test: section variables first, then family
/// variables.  Python's last-assignment-wins semantics means a family
/// variable with the same name shadows the section variable — that's
/// the intended precedence ("family > section").  Empty string when
/// neither list has entries.
private func combinedVariableDecls(
    sectionVariables: [FamilyVariable],
    family: PatternFamily
) -> String {
    let sectionLines = sectionVariables.map { "\($0.name) = \($0.value.pythonLiteral)" }
    let familyLines  = family.variables.map { "\($0.name) = \($0.value.pythonLiteral)" }
    return (sectionLines + familyLines).joined(separator: "\n")
}

private func renderBoundaryEquality(
    family: PatternFamily,
    case c: PatternCase,
    sectionVariables: [FamilyVariable],
    specHash: String
) -> String {
    let ctx = callContext(for: family, case: c)

    let resolvedHint = c.resolvedHint(defaults: family.defaults)
    let hintLine = resolvedHint.map { "\"Hint: \(escapeForPythonStringLiteral($0))\"" } ?? "\"\""

    let variableDecls = combinedVariableDecls(sectionVariables: sectionVariables, family: family)
    let variableBlock = variableDecls.isEmpty ? "" : variableDecls + "\n\n"

    // The `# Test:` line comes FIRST so test_runtime's _first_comment_label()
    // picks up the case label.  Provenance comes second — a reader opening
    // this file sees which family produced it, but the runtime label stays
    // student-readable.
    return """
    # Test: \(c.label)
    # Generated from pattern family \"\(escapeForPythonStringLiteral(family.name))\" [\(family.id)] spec_hash=\(specHash) — edit the family, not this file.

    \(variableBlock)\(ctx.declLines.isEmpty ? "# (no input arguments)" : ctx.declLines)
    expected = \(c.expected.pythonLiteral)

    try:
        result = student_module.\(family.functionName)(\(ctx.callArgs))
    except Exception as ex:
        failed(
            "unexpected exception\\n"
            \(ctx.inputLineLiteral)
            f"  expected: {expected!r}\\n"
            f"  error:    {type(ex).__name__}: {ex}\\n"
            \(hintLine)
        )

    if result != expected:
        failed(
            "wrong value\\n"
            \(ctx.inputLineLiteral)
            f"  expected: {expected!r}\\n"
            f"  got:      {result!r}\\n"
            \(hintLine)
        )

    passed(f"\(family.functionName)(\(ctx.callReprExpr)) returned {result!r}")
    """
}

// MARK: - approximateEquality

/// Default tolerance when the family spec leaves `defaults.tolerance` nil.
/// 1e-6 matches Python's `math.isclose` default `abs_tol=0.0` / `rel_tol=1e-9`
/// in spirit but is permissive enough for typical student arithmetic.
private let defaultApproxTolerance: Double = 1e-6

/// Renders an approximate-equality case.  Shape mirrors
/// `renderBoundaryEquality` — same header, input echo, rich failure
/// messages — with the comparison replaced by
/// `abs(result - expected) > tolerance` guarded by an `isinstance` check
/// that rejects non-numeric returns cleanly.  The failure message
/// includes the tolerance and the actual delta so students see exactly
/// how far off they are.
private func renderApproximateEquality(
    family: PatternFamily,
    case c: PatternCase,
    sectionVariables: [FamilyVariable],
    specHash: String
) -> String {
    let ctx = callContext(for: family, case: c)

    let resolvedHint = c.resolvedHint(defaults: family.defaults)
    let hintLine = resolvedHint.map { "\"Hint: \(escapeForPythonStringLiteral($0))\"" } ?? "\"\""

    let tolerance = family.defaults.tolerance ?? defaultApproxTolerance
    // Use JSONValue's Python rendering so whole-number tolerances come out
    // as floats (e.g. 1.0, not 1) — keeps the comparison well-typed.
    let toleranceLiteral = JSONValue.double(tolerance).pythonLiteral

    let variableDecls = combinedVariableDecls(sectionVariables: sectionVariables, family: family)
    let variableBlock = variableDecls.isEmpty ? "" : variableDecls + "\n\n"

    return """
    # Test: \(c.label)
    # Generated from pattern family \"\(escapeForPythonStringLiteral(family.name))\" [\(family.id)] spec_hash=\(specHash) — edit the family, not this file.

    \(variableBlock)\(ctx.declLines.isEmpty ? "# (no input arguments)" : ctx.declLines)
    expected = \(c.expected.pythonLiteral)
    tolerance = \(toleranceLiteral)

    try:
        result = student_module.\(family.functionName)(\(ctx.callArgs))
    except Exception as ex:
        failed(
            "unexpected exception\\n"
            \(ctx.inputLineLiteral)
            f"  expected: {expected!r} (±{tolerance})\\n"
            f"  error:    {type(ex).__name__}: {ex}\\n"
            \(hintLine)
        )

    if not isinstance(result, (int, float)) or isinstance(result, bool):
        failed(
            "wrong return type\\n"
            \(ctx.inputLineLiteral)
            f"  expected: a number close to {expected!r}\\n"
            f"  got:      {result!r} (type {type(result).__name__})\\n"
            \(hintLine)
        )

    delta = abs(result - expected)
    if delta > tolerance:
        failed(
            "value outside tolerance\\n"
            \(ctx.inputLineLiteral)
            f"  expected: {expected!r} (±{tolerance})\\n"
            f"  got:      {result!r}\\n"
            f"  delta:    {delta}\\n"
            \(hintLine)
        )

    passed(f"\(family.functionName)(\(ctx.callReprExpr)) returned {result!r} (within ±{tolerance})")
    """
}

// MARK: - variableEquality

/// Renders a single-variable equality check.  `family.functionName` and
/// `family.paramNames` are ignored for this kind — the variable name lives
/// in `case.args[0]` (validated by `ManifestValidation` to be a non-empty
/// string) and the expected value in `case.expected`.  A sentinel default
/// on `getattr` distinguishes "not defined at all" from "defined as None"
/// so students get a useful error message in both cases.
private func renderVariableEquality(
    family: PatternFamily,
    case c: PatternCase,
    sectionVariables: [FamilyVariable],
    specHash: String
) -> String {
    // Section + family variables are declared as module-level globals in
    // the generated test.  `variableEquality` is checking a STUDENT-module
    // attribute (not a declared-in-this-file one), so the section/family
    // variables don't interact with the check itself — but we still emit
    // them so the Variables row (e.g. a shared `patients` list) is
    // available if a future kind / hint references it.
    _ = sectionVariables  // currently unused by this kind; keep the signature consistent
    // Validation guarantees args.count == 1 and args[0] is a non-empty
    // string, but fall back to a sentinel name if somehow absent so the
    // generated Python is still syntactically valid.
    let variableName: String = {
        guard let first = c.args.first, case .string(let name) = first else {
            return "<unset>"
        }
        return name
    }()
    let nameLiteral = "\"" + escapeForPythonStringLiteral(variableName) + "\""
    let resolvedHint = c.resolvedHint(defaults: family.defaults)
    let hintLine = resolvedHint.map { "\"Hint: \(escapeForPythonStringLiteral($0))\"" } ?? "\"\""

    return """
    # Test: \(c.label)
    # Generated from pattern family \"\(escapeForPythonStringLiteral(family.name))\" [\(family.id)] spec_hash=\(specHash) — edit the family, not this file.

    variable_name = \(nameLiteral)
    expected      = \(c.expected.pythonLiteral)

    _MISSING = object()
    actual = getattr(student_module, variable_name, _MISSING)
    if actual is _MISSING:
        failed(
            f"Variable `{variable_name}` is not defined\\n"
            f"  expected: {expected!r}\\n"
            \(hintLine)
        )

    if actual != expected:
        failed(
            f"Variable `{variable_name}` has the wrong value\\n"
            f"  expected: {expected!r}\\n"
            f"  got:      {actual!r}\\n"
            \(hintLine)
        )

    passed(f"{variable_name} == {actual!r}")
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
