import Fluent
// Tests/CoreTests/TestScriptTemplatesTests.swift
import Foundation
import Testing

@testable import APIServer

//
// Unit tests for TestScriptTemplates.
// These tests import the server module because templates live in APIServer, not Core.

@Suite struct TestScriptTemplatesTests {

    // MARK: - Python templates

    @Test func existsTemplate_containsFunctionName() {
        let s = pythonTestScript(type: .exists, functionName: "myFunc", paramNames: ["x", "y"])
        #expect(s.contains("myFunc"))
        #expect(s.contains("require_function"))
        #expect(s.contains("passed"))

    }

    @Test func existsTemplate_numArgsIncluded_whenParamsPresent() {
        let s = pythonTestScript(type: .exists, functionName: "f", paramNames: ["a", "b"])
        #expect(s.contains("num_args=2"))

    }

    @Test func existsTemplate_noNumArgs_whenNoParams() {
        let s = pythonTestScript(type: .exists, functionName: "f", paramNames: [])
        #expect(s.contains("num_args") == false)

    }

    @Test func correctnessTemplate_containsFunctionName() {
        let s = pythonTestScript(type: .correctness, functionName: "add", paramNames: ["a", "b"])
        #expect(s.contains("add"))
        #expect(s.contains("passed"))
        #expect(s.contains("failed"))

    }

    @Test func correctnessTemplate_nonEmpty() {
        let s = pythonTestScript(type: .correctness, functionName: "f")
        #expect(s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)

    }

    @Test func correctnessTemplate_richFeedback_withParams() {
        let s = pythonTestScript(type: .correctness, functionName: "bmi_category", paramNames: ["bmi"])
        // Single-case rich-feedback shape: an input variable declaration, an
        // `expected` placeholder, a try/except + value-comparison, each failed()
        // call with labeled input/expected/got lines and a Hint line.
        #expect(s.contains("bmi = None"), "Should declare the input variable")
        #expect(s.contains("expected = None"))
        #expect(s.contains("student_module.bmi_category(bmi)"))
        #expect(s.contains("raised an unexpected exception"))
        #expect(s.contains("returned the wrong value"))
        #expect(s.contains("input:    bmi={bmi!r}"))
        #expect(s.contains("Hint:"))

    }

    @Test func correctnessTemplate_richFeedback_noParams() {
        let s = pythonTestScript(type: .correctness, functionName: "get_answer", paramNames: [])
        #expect(s.contains("student_module.get_answer()"))
        #expect(s.contains("(no input)"))
        #expect(
            s.contains("= None   # TODO: replace with input value") == false,
            "No input declarations when there are no params")

    }

    @Test func cornerCasesTemplate_containsFunctionName() {
        let s = pythonTestScript(type: .cornerCases, functionName: "check", paramNames: ["n"])
        #expect(s.contains("check"))
        #expect(s.contains("corner_cases"))

    }

    @Test func cornerCasesTemplate_richPerCaseMessages() {
        let s = pythonTestScript(type: .cornerCases, functionName: "check", paramNames: ["n"])
        #expect(s.contains("args_preview"))
        #expect(s.contains("expected:"))
        #expect(s.contains("got:"))
        #expect(s.contains("raised:"))

    }

    @Test func exceptionTemplate_containsFunctionName() {
        let s = pythonTestScript(type: .exception, functionName: "divide", paramNames: ["a", "b"])
        #expect(s.contains("divide"))
        #expect(s.contains("ValueError"))

    }

    @Test func exceptionTemplate_richFeedback() {
        let s = pythonTestScript(type: .exception, functionName: "divide", paramNames: ["a", "b"])
        #expect(s.contains("a = None"))
        #expect(s.contains("b = None"))
        #expect(s.contains("expected_exc = ValueError"))
        #expect(s.contains("raised the wrong exception"))
        #expect(s.contains("did not raise"))
        #expect(s.contains("input:    a={a!r}, b={b!r}"))

    }

    @Test func typeCheckTemplate_containsFunctionName() {
        let s = pythonTestScript(type: .typeCheck, functionName: "items", paramNames: [])
        #expect(s.contains("items"))
        #expect(s.contains("isinstance"))

    }

    @Test func typeCheckTemplate_richFeedback() {
        let s = pythonTestScript(type: .typeCheck, functionName: "get_name", paramNames: ["user_id"])
        #expect(s.contains("user_id = None"))
        #expect(s.contains("expected_type = list"))
        #expect(s.contains("Return type error"))
        #expect(s.contains("raised an unexpected exception"))
        #expect(s.contains("input:    user_id={user_id!r}"))

    }

    // MARK: - Drift guards

    /// Fails if any template passes a kwarg to `require_function` that the
    /// Python test_runtime helpers do not accept.  Prevents the 0.4.x-era bug
    /// where `num_args` was emitted by templates but the runtime's signature
    /// was `require_function(name)` only.
    @Test func templates_useOnlyKnownRequireFunctionKwargs() {
        let knownKwargs: Set<String> = ["num_args"]
        // One call with "real" params, one with none, to exercise both arms of
        // each template branch.
        let renderings: [(String, String)] = [
            ("with-params", /* any type with params */ ""),
            ("no-params", ""),
        ]
        _ = renderings
        for type in PythonTestTemplateType.allCases {
            for params in [["a", "b"], [] as [String]] {
                let s = pythonTestScript(type: type, functionName: "f", paramNames: params)
                for kwarg in kwargsInRequireFunctionCalls(source: s) {
                    let msg: Comment = """
                        Template \(type.rawValue) (params=\(params)) passes unknown kwarg \
                        '\(kwarg)' to require_function(). Add it to the runtime helpers \
                        in TestRuntimeSources.swift + Tools/runner-support/test_runtime.py + \
                        Public/browser-runner.js, or drop it from the template.
                        """
                    #expect(knownKwargs.contains(kwarg), msg)
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
                    !trimmed.contains("==")
                {
                    let name = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty && !name.hasPrefix("\"") {
                        kwargs.append(name)
                    }
                }
            }
            remaining = remaining[callEnd...]
            remaining = remaining.dropFirst()  // step past the ')'
        }
        return kwargs
    }

    @Test func performanceTemplate_containsFunctionName() {
        let s = pythonTestScript(type: .performance, functionName: "sort_it", paramNames: ["lst"])
        #expect(s.contains("sort_it"))
        #expect(s.contains("time_limit_ms"))

    }

    @Test func differentialTemplate_containsFunctionName() {
        let s = pythonTestScript(type: .differential, functionName: "square", paramNames: ["n"])
        #expect(s.contains("square"))
        #expect(s.contains("_reference_square"))

    }

    @Test func variableEqualityTemplate_hasExpectedShape() {
        let s = pythonTestScript(type: .variableEquality)
        // Bare builtins from the injected test runtime — NOT imported from a
        // `chickadee` module (which doesn't exist on the Python path).
        #expect(
            s.contains("from chickadee") == false,
            "Template must not import from a `chickadee` module — passed()/failed() are injected as builtins.")
        #expect(s.contains("import chickadee") == false, "Template must not import `chickadee` — builtins only.")
        #expect(s.contains("passed"))
        #expect(s.contains("failed"))
        // Reads a module-level attribute off `student_module` with a
        // sentinel default so "not defined" is distinguishable from
        // "defined as None".
        #expect(s.contains("getattr(student_module, variable_name"))
        #expect(s.contains("_MISSING"))
        // Placeholder variable name + expected value the instructor edits.
        #expect(s.contains("variable_name = \"target_variable\""))
        #expect(s.contains("expected"))
        // Rich-feedback shape matches the other single-case templates.
        #expect(s.contains("is not defined"))
        #expect(s.contains("wrong value"))
        #expect(s.contains("Hint:"))

    }

    @Test func structuralCheckTemplate_hasExpectedShape() {
        let s = pythonTestScript(
            type: .structuralCheck, functionName: "compute_bmi", paramNames: ["weight_kg", "height_m"])
        // AST-based template — no function call.
        #expect(s.contains("import ast"))
        #expect(s.contains("inspect.getsource(student_module)"))
        #expect(s.contains("ast.parse(source)"))
        // All the knobs are present as TODO-friendly placeholders.
        #expect(s.contains("parameter_count"))
        #expect(s.contains("typed_parameters"))
        #expect(s.contains("return_type_hint"))
        #expect(s.contains("has_docstring"))
        #expect(s.contains("min_asserts_in_body"))
        #expect(s.contains("min_module_asserts"))
        // Per-function check uses the provided functionName.
        #expect(s.contains("target_function     = \"compute_bmi\""))
        // Rich-feedback shape.
        #expect(s.contains("Structural check(s) failed"))
        #expect(s.contains("passed"))
        // Counts module-level asserts even when quarantined.
        #expect(s.contains("ast.iter_child_nodes"))

    }

    @Test func allPythonTemplateTypes_nonEmpty() {
        for type in PythonTestTemplateType.allCases {
            let s = pythonTestScript(type: type, functionName: "f", paramNames: ["x"])
            #expect(
                s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                "Template \(type.rawValue) should not be empty")
        }

    }

    @Test func allPythonTemplateTypes_startWithPythonShebang() {
        // Instructors sometimes name test scripts without a `.py` extension
        // (e.g. "beats").  Without a shebang the runner falls through to
        // `/bin/sh` and the Python body blows up as shell.  Per v0.4.73 a
        // `#!/usr/bin/env python3` shebang routes the script through the
        // Python runtime regardless of filename.
        for type in PythonTestTemplateType.allCases {
            let s = pythonTestScript(type: type, functionName: "f", paramNames: ["x"])
            #expect(
                s.hasPrefix("#!/usr/bin/env python3"),
                "Template \(type.rawValue) must begin with a `#!/usr/bin/env python3` shebang")
        }

    }

    @Test func allPythonTemplateTypes_doNotImportChickadee() {
        // passed(), failed(), errored(), require_function() are injected as
        // builtins by the test runtime — they are NOT importable from a
        // `chickadee` module (which doesn't exist on sys.path).  Guard
        // against a future template regressing to `from chickadee import …`.
        for type in PythonTestTemplateType.allCases {
            let s = pythonTestScript(type: type, functionName: "f", paramNames: ["x"])
            #expect(
                s.contains("from chickadee") == false,
                "Template \(type.rawValue) must not import from a `chickadee` module")
            #expect(s.contains("import chickadee") == false, "Template \(type.rawValue) must not import `chickadee`")
        }

    }

    @Test func allPythonTemplateTypes_containFunctionName() {
        // `.variableEquality` is the one template that isn't function-scoped —
        // it tests a module-level variable by name, so `functionName` is not
        // relevant.  Every other template should echo the function name.
        for type in PythonTestTemplateType.allCases where type != .variableEquality {
            let s = pythonTestScript(type: type, functionName: "mySpecialFunc", paramNames: ["a"])
            #expect(
                s.contains("mySpecialFunc"),
                "Template \(type.rawValue) should contain the function name")
        }

    }

    /// Parses every Python template through python3's `ast.parse` to catch
    /// any indentation / syntax regression in the generated source.  Skipped
    /// on machines where `python3` isn't on PATH (rare in CI but possible
    /// locally — the test reports a clear skip message rather than failing).
    @Test func allPythonTemplateTypes_parseAsValidPython() throws {
        guard
            FileManager.default.fileExists(atPath: "/usr/bin/python3")
                || FileManager.default.fileExists(atPath: "/opt/homebrew/bin/python3")
                || FileManager.default.fileExists(atPath: "/usr/local/bin/python3")
        else {
            throw IssueRecorded("python3 not available on PATH — skipping syntax check.")
        }
        for type in PythonTestTemplateType.allCases {
            let source = pythonTestScript(type: type, functionName: "sample_fn", paramNames: ["x", "y"])
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["python3", "-c", "import ast, sys; ast.parse(sys.stdin.read())"]
            let stdin = Pipe()
            let stderr = Pipe()
            p.standardInput = stdin
            p.standardError = stderr
            p.standardOutput = Pipe()
            try p.run()
            stdin.fileHandleForWriting.write(Data(source.utf8))
            try stdin.fileHandleForWriting.close()
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                Issue.record("Template \(type.rawValue) generated invalid Python:\n\(err)\n--- source ---\n\(source)")
            }
        }

    }

    @Test func defaultFunctionName_usedWhenNotSpecified() {
        let s = pythonTestScript(type: .exists)
        #expect(s.contains("my_function"))

    }

    // MARK: - Shell templates

    @Test func shellAlwaysPass() {
        let s = shellTestScript(type: .alwaysPass)
        #expect(s.contains("exit 0"))
        #expect(s.contains("#!/bin/sh"))

    }

    @Test func shellFileExists() {
        let s = shellTestScript(type: .fileExists)
        #expect(s.contains("#!/bin/sh"))
        #expect(s.contains("exit 0"))
        #expect(s.contains("exit 1"))
        #expect(s.contains("-f"))

    }

    @Test func shellCommandOutput() {
        let s = shellTestScript(type: .commandOutput)
        #expect(s.contains("#!/bin/sh"))
        #expect(s.contains("exit 0"))
        #expect(s.contains("exit 1"))
        #expect(s.contains("EXPECTED"))
        #expect(s.contains("ACTUAL"))

    }

    @Test func allShellTemplateTypes_nonEmpty() {
        for type in ShellTestTemplateType.allCases {
            let s = shellTestScript(type: type)
            #expect(
                s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                "Shell template \(type.rawValue) should not be empty")
        }

    }

    // MARK: - allTemplateInfos

    @Test func allTemplateInfos_countMatchesTypes() {
        let infos = allTemplateInfos(functionName: "foo", paramNames: ["x"])
        let expectedCount = PythonTestTemplateType.allCases.count + ShellTestTemplateType.allCases.count
        #expect(infos.count == expectedCount)

    }

    @Test func allTemplateInfos_eachHasContent() {
        let infos = allTemplateInfos(functionName: "bar", paramNames: [])
        for info in infos {
            #expect(
                info.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                "Template \(info.id) content should not be empty")
        }

    }

    @Test func allTemplateInfos_pythonContainFunctionName() {
        let infos = allTemplateInfos(functionName: "special_fn", paramNames: ["x"])
        // `variable_equality` is the one template that isn't function-scoped —
        // it checks a module-level variable by name, so the function name is
        // never substituted into its body.  Every other Python template
        // should echo it.
        let pythonInfos = infos.filter {
            $0.language == "python" && $0.id != PythonTestTemplateType.variableEquality.rawValue
        }
        for info in pythonInfos {
            #expect(
                info.content.contains("special_fn"),
                "Python template \(info.id) should contain function name")
        }

    }
}
