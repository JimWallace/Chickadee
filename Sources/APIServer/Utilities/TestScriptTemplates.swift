// APIServer/Utilities/TestScriptTemplates.swift
//
// Python and shell test script templates for the in-browser script editor.
// Templates use the test_runtime builtins injected by the runner:
//   passed(message)                     — exit 0 with short result
//   failed(message)                     — exit 1; multi-line message becomes
//                                         stdout (rendered in longResult) and
//                                         its first line becomes shortResult
//   errored(message)                    — exit 2; same routing as failed()
//   require_function(name[, num_args])  — exit 2 if function is missing or
//                                         has the wrong positional-arg count
//
// When editing, keep these kwargs in sync with `require_function` in
// Sources/Worker/TestRuntimeSources.swift and Tools/runner-support/test_runtime.py
// (enforced by TestScriptTemplatesTests.testTemplates_useOnlyKnownRequireFunctionKwargs).

import Foundation

// MARK: - Rich-feedback argument rendering

/// Renders Python fragments describing a function's parameters for the
/// single-case rich-feedback templates (correctness, typeCheck, exception).
///
/// Given paramNames = ["bmi"] the fragments produce:
///   argDeclarations  → `bmi = None   # TODO: replace with input value`
///   callArgs         → `bmi`
///   inputLineLiteral → `f"  input:    bmi={bmi!r}\n"`
///   callReprExpr     → `{bmi!r}`
///
/// For empty paramNames the literals degrade gracefully to "(no input)"
/// and an empty call expression.
private struct RichTemplateArgs {
    let paramNames: [String]
    var hasArgs: Bool { !paramNames.isEmpty }
    var callArgs: String { paramNames.joined(separator: ", ") }

    var argDeclarations: String {
        paramNames
            .map { "\($0) = None   # TODO: replace with input value" }
            .joined(separator: "\n")
    }

    /// Python source fragment for the `input:` line inside a `failed(...)`
    /// concatenation — already quoted, with trailing `\n` escape.
    var inputLineLiteral: String {
        guard hasArgs else {
            return #""  input:    (no input)\n""#
        }
        let preview = paramNames.map { "\($0)={\($0)!r}" }.joined(separator: ", ")
        return "f\"  input:    \(preview)\\n\""
    }

    /// `{x!r}, {y!r}` — used inside an outer f-string to echo the call args.
    var callReprExpr: String {
        paramNames.map { "{\($0)!r}" }.joined(separator: ", ")
    }
}

// MARK: - Template type enumerations

/// Template types for Python test scripts.
enum PythonTestTemplateType: String, CaseIterable {
    case exists       = "exists"
    case correctness  = "correctness"
    case cornerCases  = "corner_cases"
    case exception    = "exception"
    case typeCheck    = "type_check"
    case performance  = "performance"
    case differential = "differential"

    var displayName: String {
        switch self {
        case .exists:       return "Function Exists"
        case .correctness:  return "Correctness (input/output pairs)"
        case .cornerCases:  return "Corner Cases"
        case .exception:    return "Exception Handling"
        case .typeCheck:    return "Return Type Check"
        case .performance:  return "Performance / Runtime"
        case .differential: return "Differential (reference solution)"
        }
    }

    var templateDescription: String {
        switch self {
        case .exists:       return "Checks that the function is defined and callable"
        case .correctness:  return "Calls the function with specific inputs and checks the output"
        case .cornerCases:  return "Tests edge cases: None, 0, empty list, empty string, negatives"
        case .exception:    return "Verifies the function raises an expected exception type"
        case .typeCheck:    return "Verifies the return type matches what is expected"
        case .performance:  return "Measures execution time and checks it is within a threshold"
        case .differential: return "Compares output against an inline reference implementation"
        }
    }
}

/// Template types for shell (`.sh`) test scripts.
enum ShellTestTemplateType: String, CaseIterable {
    case alwaysPass    = "always_pass"
    case fileExists    = "file_exists"
    case commandOutput = "command_output"

    var displayName: String {
        switch self {
        case .alwaysPass:    return "Always Pass (placeholder)"
        case .fileExists:    return "File Exists Check"
        case .commandOutput: return "Command Output Check"
        }
    }
}

// MARK: - Python template generation

/// Returns a Python test script for the given template type.
/// `functionName` and `paramNames` are used to personalise the template.
func pythonTestScript(
    type: PythonTestTemplateType,
    functionName: String = "my_function",
    paramNames: [String] = []
) -> String {
    let argList = paramNames.joined(separator: ", ")
    let rich = RichTemplateArgs(paramNames: paramNames)

    // Placeholder call args — use "None" form so the template compiles without filling in values.
    let placeholderCallArgs: String = {
        if paramNames.isEmpty { return "" }
        return paramNames.map { _ in "None  # TODO: replace" }.joined(separator: ", ")
    }()

    switch type {

    case .exists:
        let numArgsClause = paramNames.isEmpty ? "" : ", num_args=\(paramNames.count)"
        return """
        # Test: \(functionName) is defined and callable
        require_function("\(functionName)"\(numArgsClause))
        passed("\(functionName) is defined and callable")
        """

    case .correctness:
        let declsBlock = rich.argDeclarations.isEmpty ? "" : rich.argDeclarations + "\n"
        return """
        # Test: \(functionName) returns the correct output
        #
        # Fill in the input value(s) and expected output, then customise the hint.
        \(declsBlock)expected = None   # TODO: replace with expected output

        try:
            result = student_module.\(functionName)(\(rich.callArgs))
        except Exception as ex:
            failed(
                "\(functionName) raised an unexpected exception\\n"
                \(rich.inputLineLiteral)
                f"  expected: {expected!r}\\n"
                f"  error:    {type(ex).__name__}: {ex}\\n"
                "Hint: the function should return a value for this input, not raise."
            )

        if result != expected:
            failed(
                "\(functionName) returned the wrong value\\n"
                \(rich.inputLineLiteral)
                f"  expected: {expected!r}\\n"
                f"  got:      {result!r}\\n"
                "Hint: describe the correct behaviour here."
            )

        passed(f"Correct: \(functionName)(\(rich.callReprExpr)) returned {result!r}")
        """

    case .cornerCases:
        return """
        # Test: \(functionName) handles edge / corner cases
        #
        # Each entry is  (args_tuple, expected_output).
        # Use expected=None to only check that no exception is raised.
        corner_cases = [
            ((None,),   None),   # None input   -- TODO: fill in or remove
            ((0,),      None),   # zero          -- TODO: fill in or remove
            ((-1,),     None),   # negative      -- TODO: fill in or remove
            (([],),     None),   # empty list    -- TODO: fill in or remove
            (("",),     None),   # empty string  -- TODO: fill in or remove
        ]
        failures = []
        for args, expected in corner_cases:
            args_preview = ", ".join(repr(a) for a in args)
            try:
                result = student_module.\(functionName)(*args)
                if expected is not None and result != expected:
                    failures.append(
                        f"  \(functionName)({args_preview})\\n"
                        f"    expected: {expected!r}\\n"
                        f"    got:      {result!r}"
                    )
            except Exception as ex:
                failures.append(
                    f"  \(functionName)({args_preview})\\n"
                    f"    raised: {type(ex).__name__}: {ex}"
                )
        if failures:
            failed(
                f"\(functionName) mishandled {len(failures)} of {len(corner_cases)} corner case(s):\\n"
                + "\\n".join(failures)
                + "\\nHint: check that each corner case returns the right value and doesn't raise."
            )
        passed(f"All {len(corner_cases)} corner case(s) handled")
        """

    case .exception:
        let declsBlock = rich.argDeclarations.isEmpty ? "" : rich.argDeclarations + "\n"
        return """
        # Test: \(functionName) raises the expected exception on invalid input
        #
        # Fill in the input value(s) that should trigger the exception.
        \(declsBlock)expected_exc = ValueError   # TODO: change to expected exception type

        try:
            result = student_module.\(functionName)(\(rich.callArgs))
        except expected_exc:
            passed(f"\(functionName)(\(rich.callReprExpr)) correctly raised {expected_exc.__name__}")
        except Exception as ex:
            failed(
                f"\(functionName) raised the wrong exception\\n"
                \(rich.inputLineLiteral)
                f"  expected: {expected_exc.__name__}\\n"
                f"  got:      {type(ex).__name__}: {ex}\\n"
                "Hint: describe which inputs should trigger this exception."
            )
        else:
            failed(
                f"\(functionName) did not raise {expected_exc.__name__}\\n"
                \(rich.inputLineLiteral)
                f"  expected: raises {expected_exc.__name__}\\n"
                f"  got:      returned {result!r}\\n"
                "Hint: describe which inputs should trigger this exception."
            )
        """

    case .typeCheck:
        let declsBlock = rich.argDeclarations.isEmpty ? "" : rich.argDeclarations + "\n"
        return """
        # Test: \(functionName) returns the expected type
        #
        # Replace `list` with the type you expect (int, str, dict, bool, …).
        \(declsBlock)expected_type = list   # TODO: change to the expected return type

        try:
            result = student_module.\(functionName)(\(rich.callArgs))
        except Exception as ex:
            failed(
                f"\(functionName) raised an unexpected exception\\n"
                \(rich.inputLineLiteral)
                f"  expected: a {expected_type.__name__}\\n"
                f"  error:    {type(ex).__name__}: {ex}\\n"
                f"Hint: \(functionName) should return a {expected_type.__name__} for this input, not raise."
            )

        if not isinstance(result, expected_type):
            failed(
                "Return type error\\n"
                \(rich.inputLineLiteral)
                f"  expected: a {expected_type.__name__}\\n"
                f"  got:      {result!r} (type {type(result).__name__})\\n"
                f"Hint: \(functionName) should return a {expected_type.__name__}."
            )

        passed(f"\(functionName)(\(rich.callReprExpr)) returned a {type(result).__name__} as expected")
        """

    case .performance:
        return """
        # Test: \(functionName) completes within the time limit
        #
        # Use a large or realistic input to stress-test performance.
        import time
        time_limit_ms = 100  # TODO: adjust threshold (milliseconds)
        # TODO: replace with a meaningful, large input
        start = time.perf_counter()
        student_module.\(functionName)(\(placeholderCallArgs))
        elapsed_ms = (time.perf_counter() - start) * 1000
        if elapsed_ms < time_limit_ms:
            passed(f"Completed in {elapsed_ms:.1f} ms (limit: {time_limit_ms} ms)")
        else:
            failed(f"Too slow: {elapsed_ms:.1f} ms (limit: {time_limit_ms} ms)")
        """

    case .differential:
        let refParams = argList.isEmpty ? "*args, **kwargs" : argList
        return """
        # Test: \(functionName) matches a reference implementation
        #
        # 1. Implement _reference_\(functionName) below.
        # 2. Add test inputs (as tuples) to test_inputs.
        def _reference_\(functionName)(\(refParams)):
            pass  # TODO: implement reference solution

        test_inputs = []  # TODO: e.g. [(1, 2), (3, 4), ...]
        failures = []
        for args in test_inputs:
            args = args if isinstance(args, tuple) else (args,)
            expected = _reference_\(functionName)(*args)
            actual   = student_module.\(functionName)(*args)
            if actual != expected:
                failures.append(f"  \(functionName){args} = {actual!r}, expected {expected!r}")
        if failures:
            failed("\\n".join(failures))
        else:
            passed(f"All {len(test_inputs)} case(s) match reference")
        """
    }
}

// MARK: - Shell template generation

/// Returns a shell test script for the given template type.
func shellTestScript(type: ShellTestTemplateType) -> String {
    switch type {

    case .alwaysPass:
        return """
        #!/bin/sh
        # TODO: replace this placeholder with a real test
        echo "passed"
        exit 0
        """

    case .fileExists:
        return """
        #!/bin/sh
        # Test: a required file exists in the working directory
        FILE="solution.py"  # TODO: change to the expected filename
        if [ -f "$FILE" ]; then
            echo "File $FILE found"
            exit 0
        else
            echo "File $FILE not found" >&2
            exit 1
        fi
        """

    case .commandOutput:
        return """
        #!/bin/sh
        # Test: a command's stdout matches an expected value
        EXPECTED="expected output"  # TODO: replace with the expected output
        ACTUAL=$(python3 -c "import solution; print(solution.main())" 2>&1)
        if [ "$ACTUAL" = "$EXPECTED" ]; then
            echo "Output matches"
            exit 0
        else
            printf 'Expected: %s\\nActual:   %s\\n' "$EXPECTED" "$ACTUAL" >&2
            exit 1
        fi
        """
    }
}

// MARK: - JSON representation for the browser

/// Lightweight description of a template type, used to populate the template
/// picker in the browser.
struct TestTemplateInfo: Codable {
    let id: String
    let displayName: String
    let description: String
    let language: String     // "python" | "shell"
    let content: String
}

/// Returns all template types as `TestTemplateInfo` values for the given function.
/// Used by the scan-notebook and template-picker endpoints.
func allTemplateInfos(functionName: String, paramNames: [String]) -> [TestTemplateInfo] {
    let pyTypes = PythonTestTemplateType.allCases.map { t in
        TestTemplateInfo(
            id: t.rawValue,
            displayName: t.displayName,
            description: t.templateDescription,
            language: "python",
            content: pythonTestScript(type: t, functionName: functionName, paramNames: paramNames)
        )
    }
    let shTypes = ShellTestTemplateType.allCases.map { t in
        TestTemplateInfo(
            id: t.rawValue,
            displayName: t.displayName,
            description: t.displayName,
            language: "shell",
            content: shellTestScript(type: t)
        )
    }
    return pyTypes + shTypes
}
