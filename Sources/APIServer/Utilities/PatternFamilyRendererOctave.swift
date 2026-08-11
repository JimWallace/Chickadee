// APIServer/Utilities/PatternFamilyRendererOctave.swift
//
// The Octave half of the pattern-family renderer: every `PatternKind` rendered
// as a `.m` test script. Structured like PatternFamilyRendererR.swift — one
// switch, one small body per kind — with the field labels taken from
// GeneratedMessage, per the runbook's sharing rule.
//
// Generated Octave leans on the injected runtime (`test_runtime.m`, obtained
// with `chickadee = test_runtime();`):
//   * `chickadee.load_student()` / `chickadee.require_fn()` locate and load the
//     submission (evaluating its text behind a `1;` script guard, so function
//     files and flattened notebooks both register their definitions);
//   * `chickadee.equal` / `chickadee.unordered_equal` / `chickadee.format`
//     give the same comparison + failure-message shape as the other languages —
//     equality is isequaln-based, so an authored `NA` (JSON null) matches a
//     missing value and 1 == 1.0 == true, matching what a student can observe
//     with Octave's own operators;
//   * `chickadee.inputs()` supplies per-student values from `_ck_inputs.m`.
//
// Octave-specific decisions worth noticing:
//   * stdout capture uses `evalc`, a stream-level capture like Python's
//     `redirect_stdout` (and unlike Lua's defeatable `print` shadowing) — the
//     called expression carries a trailing `;` so the capture holds only what
//     the student PRINTS, never an `ans = …` echo of the return value;
//   * uncaught errors are reported through `try`/`catch err` with
//     `err.message`, and the harness's own failure text goes to stdout via
//     `failed()` exactly as in R and Lua;
//   * `[65, "bc"]`-style silent char coercion cannot arise here because every
//     literal comes from `JSONValue.octaveLiteral`, which renders mixed arrays
//     as cells — see that property's comment for the rule.

// THE PER-KIND RENDERERS ARE NOT HERE. Each one moved to
// `PatternFamilyRenderer+<Kind>.swift`, beside the other five languages'
// rendering of the same kind, so a kind can be reviewed across languages in one
// file. What remains is what is genuinely per-language: the kind dispatcher
// below, the call-context builder, the case header, the personalization
// preamble and the identifier/comment helpers.

import Core
import Foundation

// MARK: - Per-case Octave rendering

/// Renders one enabled case of `family` as an Octave test script.
func renderOctavePatternCase(
    family: PatternFamily,
    case c: PatternCase,
    sectionVariables: [FamilyVariable],
    specHash: String,
    perStudentNames: Set<String> = []
) -> String {
    let header = octaveGeneratedCaseHeader(family: family, case: c, specHash: specHash)
    let variableBlock = octaveCombinedVariableDecls(
        sectionVariables: sectionVariables, family: family)
    let preamble = octavePersonalizationPreambleForCase(c, perStudentNames: perStudentNames)
    let prelude = [header, variableBlock, preamble].filter { !$0.isEmpty }
        .joined(separator: "\n\n")

    switch family.kind {
    case .boundaryEquality:
        return octaveEqualityCase(family: family, case: c, prelude: prelude, unordered: false)
    case .unorderedEquality:
        return octaveEqualityCase(family: family, case: c, prelude: prelude, unordered: true)
    case .approximateEquality:
        return octaveApproximateCase(family: family, case: c, prelude: prelude)
    case .variableEquality:
        return octaveVariableEqualityCase(family: family, case: c, prelude: prelude)
    case .returnTypeCheck:
        return octaveReturnTypeCase(family: family, case: c, prelude: prelude)
    case .exceptionExpected:
        return octaveExceptionCase(family: family, case: c, prelude: prelude)
    case .performanceThreshold:
        return octavePerformanceCase(family: family, case: c, prelude: prelude)
    case .stdoutEquality:
        return octaveStdoutCase(family: family, case: c, prelude: prelude)
    case .differential:
        return octaveDifferentialCase(family: family, case: c, prelude: prelude)
    }
}

/// The Octave existence guard: the cases `dependsOn` it, so a missing or
/// non-function target fails once here and the cases skip through the runner's
/// dependency gate. Mirrors the R guard's `failed()` (not `errored()`)
/// semantics so the gate behaves identically across languages.
func renderOctaveExistenceGuard(family: PatternFamily, specHash: String) -> String {
    let name = family.functionName
    return """
        % Test: \(octaveComment(name)) is defined
        % Generated from pattern family "\(octaveComment(family.name))" [\(family.id)] spec_hash=\(specHash) — edit the family, not this file.
        % Existence guard: the family's cases depend on this test, so a missing
        % or non-function target fails once here and the cases skip instead of
        % erroring one by one.
        chickadee = test_runtime();

        function_name = \(JSONValue.string(name).octaveLiteral);

        student = chickadee.load_student();
        if chickadee.has_var(student, function_name)
            candidate = chickadee.get_var(student, function_name);
            if !is_function_handle(candidate)
                chickadee.failed(["`" function_name "` is defined but is not a function (got " ...
                    class(candidate) ")."]);
            end
        elseif !any(exist(function_name) == [2, 3, 5, 103])
            chickadee.failed(["`" function_name "` is not defined — define a function named `" ...
                function_name "()` in your submission."]);
        end
        chickadee.passed(["`" function_name "` is defined"]);
        """
}

// MARK: - Kind bodies

// MARK: - Octave template helpers

/// Per-case call context, the Octave analogue of `RCallContext`. Octave has no
/// keyword arguments, so an omitted defaulted parameter simply truncates the
/// argument list — a gap in the middle cannot be expressed and later values
/// are still passed positionally, which matches how an Octave function with
/// `nargin` checks reads its inputs.
struct OctaveCallContext {
    /// `name = <octaveLiteral>;` lines plus a trailing blank line, or "" when
    /// the case takes no arguments.
    let declBlock: String
    /// The argument list as it appears inside `target(<here>)`.
    let callArgs: String
    /// Octave fragment for the `input:` line of a failure message, already
    /// terminated with `...` so it drops into a `[ ... ]` concatenation.
    let inputLine: String
}

func octaveCallContext(for family: PatternFamily, case c: PatternCase) -> OctaveCallContext {
    let argNames: [String] = {
        if !family.paramNames.isEmpty { return family.paramNames }
        return c.args.indices.map { "arg_\($0 + 1)" }
    }()
    let provided: [Bool] = {
        guard !c.argsProvided.isEmpty else { return Array(repeating: true, count: argNames.count) }
        return (0..<argNames.count).map { i in i < c.argsProvided.count ? c.argsProvided[i] : true }
    }()
    let varRefs: [String?] = {
        guard !c.argVarRefs.isEmpty else { return Array(repeating: nil, count: argNames.count) }
        return (0..<argNames.count).map { i in i < c.argVarRefs.count ? c.argVarRefs[i] : nil }
    }()

    var declLines: [String] = []
    var callParts: [String] = []
    var previewParts: [String] = []
    for (idx, name) in argNames.enumerated() {
        guard idx < provided.count ? provided[idx] : true else {
            // Octave passes arguments positionally with no keyword form, so an
            // omission ends the argument list: the callee sees the shorter
            // `nargin` exactly as it would from a student's own partial call.
            break
        }
        if let refName = idx < varRefs.count ? varRefs[idx] : nil {
            declLines.append("\(octaveIdentifier(name)) = \(octaveIdentifier(refName));")
        } else if idx < c.args.count {
            declLines.append("\(octaveIdentifier(name)) = \(c.args[idx].octaveLiteral);")
        }
        callParts.append(octaveIdentifier(name))
        previewParts.append("\"\(name)=\" chickadee.format(\(octaveIdentifier(name)))")
    }

    let inputLine: String
    if previewParts.isEmpty {
        inputLine = "\"\(GeneratedMessage.input)(no input)\\n\" ..."
    } else {
        let joined = previewParts.joined(separator: " \", \" ")
        inputLine = "\"\(GeneratedMessage.input)\" \(joined) \"\\n\" ..."
    }

    return OctaveCallContext(
        declBlock: declLines.isEmpty ? "" : declLines.joined(separator: "\n") + "\n\n",
        callArgs: callParts.joined(separator: ", "),
        inputLine: inputLine
    )
}

/// Scope + family variables as `name = <octaveLiteral>;` lines. Octave
/// evaluates top to bottom, so the family's own variables come last and shadow
/// section/global ones — the same `family > section > global` precedence as
/// the other languages.
func octaveCombinedVariableDecls(
    sectionVariables: [FamilyVariable], family: PatternFamily
) -> String {
    let all = sectionVariables + family.variables
    guard !all.isEmpty else { return "" }
    return all.map { "\(octaveIdentifier($0.name)) = \($0.value.octaveLiteral);" }
        .joined(separator: "\n")
}

/// Two-line provenance header plus the runtime handle every generated Octave
/// script opens with. The `% Test:` line MUST come first so the runner's label
/// extraction agrees across languages.
func octaveGeneratedCaseHeader(
    family: PatternFamily, case c: PatternCase, specHash: String
) -> String {
    """
    % Test: \(octaveComment(c.label))
    % Generated from pattern family "\(octaveComment(family.name))" [\(family.id)] spec_hash=\(specHash) — edit the family, not this file.
    chickadee = test_runtime();
    """
}

/// The Octave expression bound to `expected`: a bare identifier when the case
/// pins `expectedVarRef` (supplied per student via `_ck_inputs.m`), else the
/// literal.
func octaveExpectedExpression(for c: PatternCase) -> String {
    if let ref = c.expectedVarRef, !ref.isEmpty { return octaveIdentifier(ref) }
    return c.expected.octaveLiteral
}

/// The call-argument list embedded inside the evalc string of `.stdoutEquality`.
/// Arguments are plain identifiers (declared just above the call), so the only
/// transformation needed is none — but routed through one place so a future
/// argument shape cannot silently break the quoting.
func octaveEvalcArgs(_ callArgs: String) -> String {
    callArgs
}

/// Per-student preamble: pulls the case's referenced names out of
/// `chickadee.inputs()` (which reads `_ck_inputs.m`, written by the runner from
/// the server-resolved values) and fails closed with a clear message when a
/// value is missing — the Octave mirror of `personalizationPreambleForCase`.
func octavePersonalizationPreambleForCase(
    _ c: PatternCase, perStudentNames: Set<String>
) -> String {
    let names = perStudentRefsForCase(c, perStudentNames: perStudentNames)
    guard !names.isEmpty else { return "" }
    let bindings = names.map { name in
        """
        if !isKey(ck_inputs_values, \(JSONValue.string(name).octaveLiteral))
            chickadee.failed("Personalization input '\(octaveComment(name))' is unavailable — is the assignment seed set?");
        end
        \(octaveIdentifier(name)) = ck_inputs_values(\(JSONValue.string(name).octaveLiteral));
        """
    }.joined(separator: "\n")
    return """
        % Per-student personalization inputs, resolved at grading time from the
        % assignment seed (see _ck_inputs.m, written by the runner). Do not edit.
        ck_inputs_values = chickadee.inputs();
        \(bindings)
        """
}
