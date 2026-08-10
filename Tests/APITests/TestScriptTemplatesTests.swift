import Core
import Fluent
// Tests/CoreTests/TestScriptTemplatesTests.swift
import Foundation
import Testing

@testable import APIServer

//
// Unit tests for TestScriptTemplates.
// These tests import the server module because templates live in APIServer, not Core.

@Suite(.timeLimit(.minutes(3))) struct TestScriptTemplatesTests {

    // MARK: - Python templates

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

    @Test func differentialTemplate_containsFunctionName() {
        let s = pythonTestScript(type: .differential, functionName: "square", paramNames: ["n"])
        #expect(s.contains("square"))
        #expect(s.contains("_reference_square"))

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
        for type in PythonTestTemplateType.allCases {
            let s = pythonTestScript(type: type, functionName: "mySpecialFunc", paramNames: ["a"])
            #expect(
                s.contains("mySpecialFunc"),
                "Template \(type.rawValue) should contain the function name")
        }

    }

    /// Parses every Python template through python3's `ast.parse` to catch
    /// any indentation / syntax regression in the generated source.  Silently
    /// skipped on machines with no `python3` (expected on a bare dev laptop;
    /// CI images always install it, so the check runs everywhere it matters).
    @Test func allPythonTemplateTypes_parseAsValidPython() throws {
        guard
            FileManager.default.fileExists(atPath: "/usr/bin/python3")
                || FileManager.default.fileExists(atPath: "/opt/homebrew/bin/python3")
                || FileManager.default.fileExists(atPath: "/usr/local/bin/python3")
        else {
            return
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

    /// The three shell templates are offered on EVERY language, and named
    /// Python in their bodies: `FILE="solution.py"` and
    /// `python3 -c "import solution; …"`. A non-Python author was handed three
    /// templates, all wrong for them — worse than being handed none.
    @Test(arguments: AssignmentLanguage.allCases)
    func shellTemplatesNameTheAssignmentsLanguage(_ language: AssignmentLanguage) {
        let fileExists = shellTestScript(type: .fileExists, language: language)
        #expect(fileExists.contains("solution.\(language.sourceFileExtension)"))

        let commandOutput = shellTestScript(type: .commandOutput, language: language)
        #expect(commandOutput.contains(language.descriptor.interpreterProbe.command))
        #expect(commandOutput.contains("solution.\(language.sourceFileExtension)"))

        guard language != .python else { return }
        // No Python left anywhere in another language's scaffold.
        for template in [fileExists, commandOutput] {
            #expect(!template.contains("solution.py"))
            #expect(!template.contains("python3"))
        }
    }

    /// A compiled language builds before it runs, so its scaffold compiles
    /// first. Chosen by `capabilityRequiresExecutableOutput` — the fact that
    /// already means exactly this — rather than by naming C++.
    @Test func aCompiledLanguagesShellTemplateCompilesBeforeRunning() {
        let cpp = shellTestScript(type: .commandOutput, language: .cpp)
        #expect(cpp.contains("g++"))
        #expect(cpp.contains("-o ./ck_solution"))
        #expect(cpp.contains("./ck_solution"))
        // And an interpreted one does not.
        #expect(!shellTestScript(type: .commandOutput, language: .lua).contains("-o "))
    }

    /// No declared language keeps the previous bytes exactly.
    @Test(arguments: ShellTestTemplateType.allCases)
    func aLanguagelessSuiteGetsThePythonScaffoldUnchanged(_ type: ShellTestTemplateType) {
        #expect(shellTestScript(type: type) == shellTestScript(type: type, language: .python))
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
        // Every remaining Python template is function-scoped. `variable_equality`
        // was the one exception and it is gone — the `variableEquality` pattern
        // kind does that job, in all six languages.
        let pythonInfos = infos.filter { $0.language == "python" }
        for info in pythonInfos {
            #expect(
                info.content.contains("special_fn"),
                "Python template \(info.id) should contain function name")
        }

    }
}
