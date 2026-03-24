// APIServer/Utilities/TestScriptTemplates.swift
//
// Python and shell test script templates for the in-browser script editor.
// Templates use the test_runtime builtins injected by the runner:
//   passed(message)          — exit 0 with short result
//   failed(message)          — exit 1 with short result
//   errored(message)         — exit 2 with short result
//   require_function(name[, num_args]) — exit 2 if function not found

import Foundation

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

    // Placeholder call args — use "*args" form so the template compiles without filling in values.
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
        let argTuple = paramNames.isEmpty ? "()"
            : paramNames.count == 1 ? "(\(paramNames[0]),)"
            : "(\(argList))"
        return """
        # Test: \(functionName) returns the correct output for known inputs
        #
        # Each entry is  (args_tuple, expected_output).
        # Replace None with the actual expected output for each case.
        test_cases = [
            (\(argTuple), None),  # TODO: replace None with expected output
        ]
        failures = []
        for args, expected in test_cases:
            result = student_module.\(functionName)(*args)
            if result != expected:
                failures.append(f"  \(functionName){args} = {result!r}, expected {expected!r}")
        if failures:
            failed("\\n".join(failures))
        else:
            passed(f"All {len(test_cases)} case(s) passed")
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
            try:
                result = student_module.\(functionName)(*args)
                if expected is not None and result != expected:
                    failures.append(f"  \(functionName){args} = {result!r}, expected {expected!r}")
            except Exception as e:
                failures.append(f"  \(functionName){args} raised {type(e).__name__}: {e}")
        if failures:
            failed("\\n".join(failures))
        else:
            passed(f"All {len(corner_cases)} corner case(s) handled")
        """

    case .exception:
        return """
        # Test: \(functionName) raises the expected exception
        #
        # Replace ValueError with the exception you expect, and fill in
        # the arguments that should trigger it.
        expected_exc = ValueError  # TODO: change to expected exception type
        try:
            student_module.\(functionName)(\(placeholderCallArgs))
            failed(f"Expected {expected_exc.__name__} but no exception was raised")
        except expected_exc:
            passed(f"Correctly raises {expected_exc.__name__}")
        except Exception as e:
            failed(f"Wrong exception: expected {expected_exc.__name__}, got {type(e).__name__}: {e}")
        """

    case .typeCheck:
        return """
        # Test: \(functionName) returns the expected type
        #
        # Replace `list` with the type you expect (int, str, dict, bool, …).
        expected_type = list  # TODO: change to the expected return type
        result = student_module.\(functionName)(\(placeholderCallArgs))
        if not isinstance(result, expected_type):
            failed(f"\(functionName)() returned {type(result).__name__}, expected {expected_type.__name__}")
        else:
            passed(f"\(functionName)() returned {type(result).__name__} as expected")
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
