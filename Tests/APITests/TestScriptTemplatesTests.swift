// Tests/CoreTests/TestScriptTemplatesTests.swift
//
// Unit tests for TestScriptTemplates.
// These tests import the server module because templates live in APIServer, not Core.

import XCTest
@testable import chickadee_server
import Fluent

final class TestScriptTemplatesTests: XCTestCase {

    // MARK: - Python templates

    func testExistsTemplate_containsFunctionName() {
        let s = pythonTestScript(type: .exists, functionName: "myFunc", paramNames: ["x", "y"])
        XCTAssertTrue(s.contains("myFunc"))
        XCTAssertTrue(s.contains("require_function"))
        XCTAssertTrue(s.contains("passed"))
    }

    func testExistsTemplate_numArgsIncluded_whenParamsPresent() {
        let s = pythonTestScript(type: .exists, functionName: "f", paramNames: ["a", "b"])
        XCTAssertTrue(s.contains("num_args=2"))
    }

    func testExistsTemplate_noNumArgs_whenNoParams() {
        let s = pythonTestScript(type: .exists, functionName: "f", paramNames: [])
        XCTAssertFalse(s.contains("num_args"))
    }

    func testCorrectnessTemplate_containsFunctionName() {
        let s = pythonTestScript(type: .correctness, functionName: "add", paramNames: ["a", "b"])
        XCTAssertTrue(s.contains("add"))
        XCTAssertTrue(s.contains("passed"))
        XCTAssertTrue(s.contains("failed"))
    }

    func testCorrectnessTemplate_nonEmpty() {
        let s = pythonTestScript(type: .correctness, functionName: "f")
        XCTAssertFalse(s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testCorrectnessTemplate_richFeedback_withParams() {
        let s = pythonTestScript(type: .correctness, functionName: "bmi_category", paramNames: ["bmi"])
        // Single-case rich-feedback shape: an input variable declaration, an
        // `expected` placeholder, a try/except + value-comparison, each failed()
        // call with labeled input/expected/got lines and a Hint line.
        XCTAssertTrue(s.contains("bmi = None"), "Should declare the input variable")
        XCTAssertTrue(s.contains("expected = None"))
        XCTAssertTrue(s.contains("student_module.bmi_category(bmi)"))
        XCTAssertTrue(s.contains("raised an unexpected exception"))
        XCTAssertTrue(s.contains("returned the wrong value"))
        XCTAssertTrue(s.contains("input:    bmi={bmi!r}"))
        XCTAssertTrue(s.contains("Hint:"))
    }

    func testCorrectnessTemplate_richFeedback_noParams() {
        let s = pythonTestScript(type: .correctness, functionName: "get_answer", paramNames: [])
        XCTAssertTrue(s.contains("student_module.get_answer()"))
        XCTAssertTrue(s.contains("(no input)"))
        XCTAssertFalse(s.contains("= None   # TODO: replace with input value"),
                       "No input declarations when there are no params")
    }

    func testCornerCasesTemplate_containsFunctionName() {
        let s = pythonTestScript(type: .cornerCases, functionName: "check", paramNames: ["n"])
        XCTAssertTrue(s.contains("check"))
        XCTAssertTrue(s.contains("corner_cases"))
    }

    func testCornerCasesTemplate_richPerCaseMessages() {
        let s = pythonTestScript(type: .cornerCases, functionName: "check", paramNames: ["n"])
        XCTAssertTrue(s.contains("args_preview"))
        XCTAssertTrue(s.contains("expected:"))
        XCTAssertTrue(s.contains("got:"))
        XCTAssertTrue(s.contains("raised:"))
    }

    func testExceptionTemplate_containsFunctionName() {
        let s = pythonTestScript(type: .exception, functionName: "divide", paramNames: ["a", "b"])
        XCTAssertTrue(s.contains("divide"))
        XCTAssertTrue(s.contains("ValueError"))
    }

    func testExceptionTemplate_richFeedback() {
        let s = pythonTestScript(type: .exception, functionName: "divide", paramNames: ["a", "b"])
        XCTAssertTrue(s.contains("a = None"))
        XCTAssertTrue(s.contains("b = None"))
        XCTAssertTrue(s.contains("expected_exc = ValueError"))
        XCTAssertTrue(s.contains("raised the wrong exception"))
        XCTAssertTrue(s.contains("did not raise"))
        XCTAssertTrue(s.contains("input:    a={a!r}, b={b!r}"))
    }

    func testTypeCheckTemplate_containsFunctionName() {
        let s = pythonTestScript(type: .typeCheck, functionName: "items", paramNames: [])
        XCTAssertTrue(s.contains("items"))
        XCTAssertTrue(s.contains("isinstance"))
    }

    func testTypeCheckTemplate_richFeedback() {
        let s = pythonTestScript(type: .typeCheck, functionName: "get_name", paramNames: ["user_id"])
        XCTAssertTrue(s.contains("user_id = None"))
        XCTAssertTrue(s.contains("expected_type = list"))
        XCTAssertTrue(s.contains("Return type error"))
        XCTAssertTrue(s.contains("raised an unexpected exception"))
        XCTAssertTrue(s.contains("input:    user_id={user_id!r}"))
    }

    // MARK: - Drift guards

    /// Fails if any template passes a kwarg to `require_function` that the
    /// Python test_runtime helpers do not accept.  Prevents the 0.4.x-era bug
    /// where `num_args` was emitted by templates but the runtime's signature
    /// was `require_function(name)` only.
    func testTemplates_useOnlyKnownRequireFunctionKwargs() {
        let knownKwargs: Set<String> = ["num_args"]
        // One call with "real" params, one with none, to exercise both arms of
        // each template branch.
        let renderings: [(String, String)] = [
            ("with-params", /* any type with params */ ""),
            ("no-params",   "")
        ]
        _ = renderings
        for type in PythonTestTemplateType.allCases {
            for params in [["a", "b"], [] as [String]] {
                let s = pythonTestScript(type: type, functionName: "f", paramNames: params)
                for kwarg in kwargsInRequireFunctionCalls(source: s) {
                    XCTAssertTrue(
                        knownKwargs.contains(kwarg),
                        "Template \(type.rawValue) (params=\(params)) passes unknown kwarg " +
                        "'\(kwarg)' to require_function(). Add it to the runtime helpers " +
                        "in TestRuntimeSources.swift + Tools/runner-support/test_runtime.py + " +
                        "Public/browser-runner.js, or drop it from the template."
                    )
                }
            }
        }
    }

    /// Extract kwarg names used in any `require_function(...)` call in the
    /// given Python source.  Intentionally conservative: only handles the
    /// simple-call forms our templates produce (no nested parens).
    private func kwargsInRequireFunctionCalls(source: String) -> [String] {
        var kwargs: [String] = []
        var remaining = source[...]
        while let callStart = remaining.range(of: "require_function(") {
            let afterOpen = callStart.upperBound
            guard let callEnd = remaining[afterOpen...].firstIndex(of: ")") else { break }
            let body = remaining[afterOpen..<callEnd]
            for part in body.split(separator: ",") {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                if let eq = trimmed.firstIndex(of: "="),
                   !trimmed.contains("==") {
                    let name = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty && !name.hasPrefix("\"") {
                        kwargs.append(name)
                    }
                }
            }
            remaining = remaining[callEnd...]
            remaining = remaining.dropFirst() // step past the ')'
        }
        return kwargs
    }

    func testPerformanceTemplate_containsFunctionName() {
        let s = pythonTestScript(type: .performance, functionName: "sort_it", paramNames: ["lst"])
        XCTAssertTrue(s.contains("sort_it"))
        XCTAssertTrue(s.contains("time_limit_ms"))
    }

    func testDifferentialTemplate_containsFunctionName() {
        let s = pythonTestScript(type: .differential, functionName: "square", paramNames: ["n"])
        XCTAssertTrue(s.contains("square"))
        XCTAssertTrue(s.contains("_reference_square"))
    }

    func testVariableEqualityTemplate_hasExpectedShape() {
        let s = pythonTestScript(type: .variableEquality)
        // Bare builtins from the injected test runtime — NOT imported from a
        // `chickadee` module (which doesn't exist on the Python path).
        XCTAssertFalse(s.contains("from chickadee"),
                       "Template must not import from a `chickadee` module — passed()/failed() are injected as builtins.")
        XCTAssertFalse(s.contains("import chickadee"),
                       "Template must not import `chickadee` — builtins only.")
        XCTAssertTrue(s.contains("passed"))
        XCTAssertTrue(s.contains("failed"))
        // Reads a module-level attribute off `student_module` with a
        // sentinel default so "not defined" is distinguishable from
        // "defined as None".
        XCTAssertTrue(s.contains("getattr(student_module, variable_name"))
        XCTAssertTrue(s.contains("_MISSING"))
        // Placeholder variable name + expected value the instructor edits.
        XCTAssertTrue(s.contains("variable_name = \"target_variable\""))
        XCTAssertTrue(s.contains("expected"))
        // Rich-feedback shape matches the other single-case templates.
        XCTAssertTrue(s.contains("is not defined"))
        XCTAssertTrue(s.contains("wrong value"))
        XCTAssertTrue(s.contains("Hint:"))
    }

    func testAllPythonTemplateTypes_nonEmpty() {
        for type in PythonTestTemplateType.allCases {
            let s = pythonTestScript(type: type, functionName: "f", paramNames: ["x"])
            XCTAssertFalse(s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "Template \(type.rawValue) should not be empty")
        }
    }

    func testAllPythonTemplateTypes_startWithPythonShebang() {
        // Instructors sometimes name test scripts without a `.py` extension
        // (e.g. "beats").  Without a shebang the runner falls through to
        // `/bin/sh` and the Python body blows up as shell.  Per v0.4.73 a
        // `#!/usr/bin/env python3` shebang routes the script through the
        // Python runtime regardless of filename.
        for type in PythonTestTemplateType.allCases {
            let s = pythonTestScript(type: type, functionName: "f", paramNames: ["x"])
            XCTAssertTrue(s.hasPrefix("#!/usr/bin/env python3"),
                          "Template \(type.rawValue) must begin with a `#!/usr/bin/env python3` shebang")
        }
    }

    func testAllPythonTemplateTypes_doNotImportChickadee() {
        // passed(), failed(), errored(), require_function() are injected as
        // builtins by the test runtime — they are NOT importable from a
        // `chickadee` module (which doesn't exist on sys.path).  Guard
        // against a future template regressing to `from chickadee import …`.
        for type in PythonTestTemplateType.allCases {
            let s = pythonTestScript(type: type, functionName: "f", paramNames: ["x"])
            XCTAssertFalse(s.contains("from chickadee"),
                           "Template \(type.rawValue) must not import from a `chickadee` module")
            XCTAssertFalse(s.contains("import chickadee"),
                           "Template \(type.rawValue) must not import `chickadee`")
        }
    }

    func testAllPythonTemplateTypes_containFunctionName() {
        // `.variableEquality` is the one template that isn't function-scoped —
        // it tests a module-level variable by name, so `functionName` is not
        // relevant.  Every other template should echo the function name.
        for type in PythonTestTemplateType.allCases where type != .variableEquality {
            let s = pythonTestScript(type: type, functionName: "mySpecialFunc", paramNames: ["a"])
            XCTAssertTrue(s.contains("mySpecialFunc"),
                          "Template \(type.rawValue) should contain the function name")
        }
    }

    func testDefaultFunctionName_usedWhenNotSpecified() {
        let s = pythonTestScript(type: .exists)
        XCTAssertTrue(s.contains("my_function"))
    }

    // MARK: - Shell templates

    func testShellAlwaysPass() {
        let s = shellTestScript(type: .alwaysPass)
        XCTAssertTrue(s.contains("exit 0"))
        XCTAssertTrue(s.contains("#!/bin/sh"))
    }

    func testShellFileExists() {
        let s = shellTestScript(type: .fileExists)
        XCTAssertTrue(s.contains("#!/bin/sh"))
        XCTAssertTrue(s.contains("exit 0"))
        XCTAssertTrue(s.contains("exit 1"))
        XCTAssertTrue(s.contains("-f"))
    }

    func testShellCommandOutput() {
        let s = shellTestScript(type: .commandOutput)
        XCTAssertTrue(s.contains("#!/bin/sh"))
        XCTAssertTrue(s.contains("exit 0"))
        XCTAssertTrue(s.contains("exit 1"))
        XCTAssertTrue(s.contains("EXPECTED"))
        XCTAssertTrue(s.contains("ACTUAL"))
    }

    func testAllShellTemplateTypes_nonEmpty() {
        for type in ShellTestTemplateType.allCases {
            let s = shellTestScript(type: type)
            XCTAssertFalse(s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "Shell template \(type.rawValue) should not be empty")
        }
    }

    // MARK: - allTemplateInfos

    func testAllTemplateInfos_countMatchesTypes() {
        let infos = allTemplateInfos(functionName: "foo", paramNames: ["x"])
        let expectedCount = PythonTestTemplateType.allCases.count + ShellTestTemplateType.allCases.count
        XCTAssertEqual(infos.count, expectedCount)
    }

    func testAllTemplateInfos_eachHasContent() {
        let infos = allTemplateInfos(functionName: "bar", paramNames: [])
        for info in infos {
            XCTAssertFalse(info.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "Template \(info.id) content should not be empty")
        }
    }

    func testAllTemplateInfos_pythonContainFunctionName() {
        let infos = allTemplateInfos(functionName: "special_fn", paramNames: ["x"])
        let pythonInfos = infos.filter { $0.language == "python" }
        for info in pythonInfos {
            XCTAssertTrue(info.content.contains("special_fn"),
                          "Python template \(info.id) should contain function name")
        }
    }
}
