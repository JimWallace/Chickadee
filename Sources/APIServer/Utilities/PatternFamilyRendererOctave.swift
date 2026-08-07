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

/// `.boundaryEquality` / `.unorderedEquality` — call the function, compare the
/// return value (exactly, or ignoring order).
private func octaveEqualityCase(
    family: PatternFamily, case c: PatternCase, prelude: String, unordered: Bool
) -> String {
    let ctx = octaveCallContext(for: family, case: c)
    let comparator = unordered ? "chickadee.unordered_equal" : "chickadee.equal"
    let mismatchLabel = unordered ? GeneratedMessage.wrongElements : GeneratedMessage.wrongValue
    let expectedLabel = unordered ? "the same elements as " : ""
    return """
        \(prelude)

        \(ctx.declBlock)expected = \(octaveExpectedExpression(for: c));

        student = chickadee.load_student();
        target = chickadee.require_fn(student, \(JSONValue.string(family.functionName).octaveLiteral));

        try
            result = target(\(ctx.callArgs));
        catch err
            chickadee.failed(["\(GeneratedMessage.unexpectedException)\\n" ...
                \(ctx.inputLine)
                "\(GeneratedMessage.expected)\(expectedLabel)" chickadee.format(expected) "\\n" ...
                "\(GeneratedMessage.error)" err.message]);
        end

        if !\(comparator)(result, expected)
            chickadee.failed(["\(mismatchLabel)\\n" ...
                \(ctx.inputLine)
                "\(GeneratedMessage.expected)\(expectedLabel)" chickadee.format(expected) "\\n" ...
                "\(GeneratedMessage.got)" chickadee.format(result)]);
        end

        chickadee.passed(["Returned " chickadee.format(result)]);
        """
}

/// `.approximateEquality` — numeric return within a tolerance, reporting the
/// actual delta so a student sees how far off they are.
private func octaveApproximateCase(
    family: PatternFamily, case c: PatternCase, prelude: String
) -> String {
    let ctx = octaveCallContext(for: family, case: c)
    let tolerance = JSONValue.double(family.defaults.tolerance ?? 1e-6).octaveLiteral
    return """
        \(prelude)

        \(ctx.declBlock)expected = \(octaveExpectedExpression(for: c));
        tolerance = \(tolerance);

        student = chickadee.load_student();
        target = chickadee.require_fn(student, \(JSONValue.string(family.functionName).octaveLiteral));

        try
            result = target(\(ctx.callArgs));
        catch err
            chickadee.failed(["\(GeneratedMessage.unexpectedException)\\n" ...
                \(ctx.inputLine)
                "\(GeneratedMessage.expected)" chickadee.format(expected) " (±" num2str(tolerance) ")\\n" ...
                "\(GeneratedMessage.error)" err.message]);
        end

        if !isnumeric(result) || !isscalar(result)
            chickadee.failed(["\(GeneratedMessage.wrongReturnType)\\n" ...
                \(ctx.inputLine)
                "\(GeneratedMessage.expected)a single number close to " chickadee.format(expected) "\\n" ...
                "\(GeneratedMessage.got)" chickadee.format(result)]);
        end

        delta = abs(result - expected);
        if delta > tolerance
            chickadee.failed(["\(GeneratedMessage.outsideTolerance)\\n" ...
                \(ctx.inputLine)
                "\(GeneratedMessage.expected)" chickadee.format(expected) " (±" num2str(tolerance) ")\\n" ...
                "\(GeneratedMessage.got)" chickadee.format(result) "\\n" ...
                "\(GeneratedMessage.delta)" chickadee.format(delta)]);
        end

        chickadee.passed(["Returned " chickadee.format(result) " (within ±" num2str(tolerance) ")"]);
        """
}

/// `.variableEquality` — a module-level variable, not a function call. The
/// variable name lives in `args[0]`; `expected` holds its value.
private func octaveVariableEqualityCase(
    family: PatternFamily, case c: PatternCase, prelude: String
) -> String {
    let variableName: String = {
        guard let first = c.args.first, case .string(let name) = first else { return "<unset>" }
        return name
    }()
    return """
        \(prelude)

        variable_name = \(JSONValue.string(variableName).octaveLiteral);
        expected = \(octaveExpectedExpression(for: c));

        student = chickadee.load_student();

        if !chickadee.has_var(student, variable_name)
            chickadee.failed(["Variable `" variable_name "` is not defined\\n" ...
                "\(GeneratedMessage.expected)" chickadee.format(expected)]);
        end
        actual = chickadee.get_var(student, variable_name);

        if !chickadee.equal(actual, expected)
            chickadee.failed(["Variable `" variable_name "` has the \(GeneratedMessage.wrongValue)\\n" ...
                "\(GeneratedMessage.expected)" chickadee.format(expected) "\\n" ...
                "\(GeneratedMessage.got)" chickadee.format(actual)]);
        end

        chickadee.passed([variable_name " == " chickadee.format(actual)]);
        """
}

/// `.returnTypeCheck` — the return value's type, not its value.
private func octaveReturnTypeCase(
    family: PatternFamily, case c: PatternCase, prelude: String
) -> String {
    let ctx = octaveCallContext(for: family, case: c)
    let typeName: String = {
        if case .string(let s) = c.expected { return s }
        return "any"
    }()
    return """
        \(prelude)

        \(ctx.declBlock)expected_type_name = \(JSONValue.string(typeName).octaveLiteral);

        student = chickadee.load_student();
        target = chickadee.require_fn(student, \(JSONValue.string(family.functionName).octaveLiteral));

        try
            result = target(\(ctx.callArgs));
        catch err
            chickadee.failed(["\(GeneratedMessage.unexpectedException)\\n" ...
                \(ctx.inputLine)
                "\(GeneratedMessage.expected)a " expected_type_name " return value\\n" ...
                "\(GeneratedMessage.error)" err.message]);
        end

        if !(\(octaveTypeCheckExpression(typeName: typeName, valueExpr: "result")))
            chickadee.failed(["\(GeneratedMessage.wrongReturnType)\\n" ...
                \(ctx.inputLine)
                "\(GeneratedMessage.expected)" expected_type_name "\\n" ...
                "\(GeneratedMessage.got)" class(result) " (value: " chickadee.format(result) ")"]);
        end

        chickadee.passed(["Returned a " class(result)]);
        """
}

/// `.exceptionExpected` — the call must raise. Octave errors carry an
/// `identifier` (e.g. "Octave:undefined-function") and a `message`; `expected`
/// is matched case-insensitively as a substring of either, which covers both
/// `error("id:sub", ...)` styles and plain-message errors.
private func octaveExceptionCase(
    family: PatternFamily, case c: PatternCase, prelude: String
) -> String {
    let ctx = octaveCallContext(for: family, case: c)
    let expectedName: String = {
        if case .string(let s) = c.expected { return s }
        return ""
    }()
    let matchBlock =
        expectedName.isEmpty
        ? ""
        : """


            wanted = \(JSONValue.string(expectedName).octaveLiteral);
            hit = !isempty(strfind(lower(caught.identifier), lower(wanted))) ...
                || !isempty(strfind(lower(caught.message), lower(wanted)));
            if !hit
                chickadee.failed(["wrong error raised\\n" ...
                    \(ctx.inputLine)
                    "\(GeneratedMessage.expected)an error matching " wanted "\\n" ...
                    "\(GeneratedMessage.got)" caught.identifier ": " caught.message]);
            end
        """
    return """
        \(prelude)

        \(ctx.declBlock)student = chickadee.load_student();
        target = chickadee.require_fn(student, \(JSONValue.string(family.functionName).octaveLiteral));

        caught = [];
        try
            result = target(\(ctx.callArgs));
        catch err
            caught = err;
        end

        if isempty(caught)
            chickadee.failed(["expected an error, but the call succeeded\\n" ...
                \(ctx.inputLine)
                "\(GeneratedMessage.got)" chickadee.format(result)]);
        end\(matchBlock)

        chickadee.passed(["Raised an error as expected (" caught.message ")"]);
        """
}

/// `.performanceThreshold` — the call must finish inside a millisecond budget.
private func octavePerformanceCase(
    family: PatternFamily, case c: PatternCase, prelude: String
) -> String {
    let ctx = octaveCallContext(for: family, case: c)
    let budget: String = {
        switch c.expected {
        case .int(let i): return JSONValue.double(Double(i)).octaveLiteral
        case .double(let d): return JSONValue.double(d).octaveLiteral
        default: return "1000"
        }
    }()
    return """
        \(prelude)

        \(ctx.declBlock)budget_ms = \(budget);

        student = chickadee.load_student();
        target = chickadee.require_fn(student, \(JSONValue.string(family.functionName).octaveLiteral));

        started = tic();
        try
            result = target(\(ctx.callArgs));
        catch err
            chickadee.failed(["\(GeneratedMessage.unexpectedException)\\n" ...
                \(ctx.inputLine)
                "\(GeneratedMessage.error)" err.message]);
        end
        elapsed_ms = toc(started) * 1000;

        if elapsed_ms > budget_ms
            chickadee.failed(["too slow\\n" ...
                \(ctx.inputLine)
                "\(GeneratedMessage.budget)" num2str(budget_ms) " ms\\n" ...
                "\(GeneratedMessage.took)" num2str(round(elapsed_ms * 10) / 10) " ms\\n" ...
                "  Hint: look for repeated work that could be done once."]);
        end

        chickadee.passed(["Completed in " num2str(round(elapsed_ms * 10) / 10) ...
            " ms (budget " num2str(budget_ms) " ms)"]);
        """
}

/// `.stdoutEquality` — what the call prints, compared after trimming trailing
/// whitespace on each line (so a stray trailing space is not a failure).
///
/// Captured with `evalc`, which intercepts the interpreter's own output stream
/// — `printf`, `disp` and `fprintf(1, …)` alike — so unlike Lua's shadowed
/// `print` there is no idiomatic student spelling that escapes it. The
/// evaluated call ends in `;` so a non-suppressed return value cannot leak an
/// `ans = …` echo into the comparison.
private func octaveStdoutCase(
    family: PatternFamily, case c: PatternCase, prelude: String
) -> String {
    let ctx = octaveCallContext(for: family, case: c)
    return """
        \(prelude)

        \(ctx.declBlock)expected_output = \(octaveExpectedExpression(for: c));

        student = chickadee.load_student();
        target = chickadee.require_fn(student, \(JSONValue.string(family.functionName).octaveLiteral));

        function out = ck_normalize(text)
            lines = strsplit(text, sprintf("\\n"), "CollapseDelimiters", false);
            for i = 1:numel(lines)
                lines{i} = regexprep(lines{i}, '\\s+$', "");
            end
            while !isempty(lines) && isempty(lines{end})
                lines(end) = [];
            end
            out = strjoin(lines, sprintf("\\n"));
        end

        try
            captured = evalc("target(\(octaveEvalcArgs(ctx.callArgs)));");
        catch err
            chickadee.failed(["\(GeneratedMessage.unexpectedException)\\n" ...
                \(ctx.inputLine)
                "\(GeneratedMessage.error)" err.message]);
        end

        if !strcmp(ck_normalize(captured), ck_normalize(expected_output))
            chickadee.failed(["\(GeneratedMessage.wrongOutput)\\n" ...
                \(ctx.inputLine)
                "\(GeneratedMessage.expected)" chickadee.format(ck_normalize(expected_output)) "\\n" ...
                "\(GeneratedMessage.got)" chickadee.format(ck_normalize(captured))]);
        end

        chickadee.passed("Printed the expected output");
        """
}

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
private func octaveEvalcArgs(_ callArgs: String) -> String {
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
