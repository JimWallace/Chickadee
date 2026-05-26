import Foundation
import Testing

@testable import chickadee_runner

@Suite struct NotebookExtractorTests {
    private let extractor = NotebookExtractor()

    // MARK: - Helpers

    /// Returns the portion of the output before any `if __name__` guard block.
    private func moduleLevel(in output: String) -> String {
        if let range = output.range(of: "if __name__") {
            return String(output[output.startIndex..<range.lowerBound])
        }
        return output
    }

    /// Returns the `if __name__ == "__main__":` block, or empty string if absent.
    private func guardBlock(in output: String) -> String {
        guard let range = output.range(of: #"if __name__ == "__main__":"#) else { return "" }
        return String(output[range.lowerBound...])
    }

    // MARK: - Safe: definitions

    @Test func functionDefPreserved() {
        let output = extractor.sanitizeCellForModule("def add(a, b):\n    return a + b")
        #expect(moduleLevel(in: output).contains("def add(a, b):"))
        #expect(output.contains("if __name__") == false)
    }

    @Test func asyncFunctionDefPreserved() {
        let output = extractor.sanitizeCellForModule("async def fetch():\n    pass")
        #expect(moduleLevel(in: output).contains("async def fetch():"))
        #expect(output.contains("if __name__") == false)
    }

    @Test func classDefPreserved() {
        let output = extractor.sanitizeCellForModule("class Foo:\n    pass")
        #expect(moduleLevel(in: output).contains("class Foo:"))
        #expect(output.contains("if __name__") == false)
    }

    @Test func importPreserved() {
        let output = extractor.sanitizeCellForModule("import math")
        #expect(moduleLevel(in: output).contains("import math"))
        #expect(output.contains("if __name__") == false)
    }

    @Test func fromImportPreserved() {
        let output = extractor.sanitizeCellForModule("from math import sqrt")
        #expect(moduleLevel(in: output).contains("from math import sqrt"))
        #expect(output.contains("if __name__") == false)
    }

    @Test func decoratorPreserved() {
        let output = extractor.sanitizeCellForModule("@property\ndef value(self):\n    return self._v")
        #expect(moduleLevel(in: output).contains("@property"))
        #expect(output.contains("if __name__") == false)
    }

    // MARK: - Safe: constants and simple assignments

    @Test func integerConstantPreserved() {
        let output = extractor.sanitizeCellForModule("MAX = 100")
        #expect(moduleLevel(in: output).contains("MAX = 100"))
        #expect(output.contains("if __name__") == false)
    }

    @Test func floatConstantPreserved() {
        let output = extractor.sanitizeCellForModule("BMI_UNDERWEIGHT_MAX = 18.5")
        #expect(moduleLevel(in: output).contains("BMI_UNDERWEIGHT_MAX = 18.5"))
        #expect(output.contains("if __name__") == false)
    }

    @Test func annotatedConstantPreserved() {
        let output = extractor.sanitizeCellForModule("BMI_NORMAL_MAX: float = 25.0")
        #expect(moduleLevel(in: output).contains("BMI_NORMAL_MAX: float = 25.0"))
        #expect(output.contains("if __name__") == false)
    }

    @Test func simpleArithmeticPreserved() {
        let output = extractor.sanitizeCellForModule("result = 2 + 3")
        #expect(moduleLevel(in: output).contains("result = 2 + 3"))
        #expect(output.contains("if __name__") == false)
    }

    @Test func tupleAssignmentPreserved() {
        let output = extractor.sanitizeCellForModule("a, b = 1, 2")
        #expect(moduleLevel(in: output).contains("a, b = 1, 2"))
        #expect(output.contains("if __name__") == false)
    }

    @Test func listLiteralPreserved() {
        let output = extractor.sanitizeCellForModule("items = [1, 2, 3]")
        #expect(moduleLevel(in: output).contains("items = [1, 2, 3]"))
        #expect(output.contains("if __name__") == false)
    }

    @Test func dictLiteralPreserved() {
        let output = extractor.sanitizeCellForModule(#"mapping = {"a": 1, "b": 2}"#)
        #expect(moduleLevel(in: output).contains("mapping ="))
        #expect(output.contains("if __name__") == false)
    }

    @Test func stringConstantPreserved() {
        let output = extractor.sanitizeCellForModule(#"GREETING = "hello""#)
        #expect(moduleLevel(in: output).contains("GREETING ="))
        #expect(output.contains("if __name__") == false)
    }

    @Test func assignmentWithCommentMentioningCallPreserved() {
        // The inline comment mentions a call, but the assignment's RHS is a
        // plain literal — it must stay at module level, not be quarantined.
        let output = extractor.sanitizeCellForModule("dose = 30  # see compute() for details")
        #expect(moduleLevel(in: output).contains("dose = 30"))
        #expect(!output.contains("if __name__"))
    }

    @Test func docstringPreserved() {
        let output = extractor.sanitizeCellForModule("\"\"\"Module docstring.\"\"\"")
        #expect(moduleLevel(in: output).contains("Module docstring"))
        #expect(output.contains("if __name__") == false)
    }

    // MARK: - Safe: multi-line bracket continuation

    @Test func multiLineBracketedListPreserved() {
        // The closing `]` is flush-left; bracket depth tracking must prevent
        // it from being treated as a new top-level statement.
        let source = "PRIMES = [\n1,\n2,\n3\n]"
        let output = extractor.sanitizeCellForModule(source)
        #expect(moduleLevel(in: output).contains("PRIMES = ["))
        #expect(guardBlock(in: output).contains("PRIMES") == false)
    }

    // MARK: - Quarantined: control flow and side effects

    @Test func assertQuarantined() {
        let output = extractor.sanitizeCellForModule("assert x > 0")
        #expect(guardBlock(in: output).contains("assert x > 0"))
        #expect(moduleLevel(in: output).contains("assert") == false)
    }

    @Test func printCallQuarantined() {
        let output = extractor.sanitizeCellForModule("print(result)")
        #expect(guardBlock(in: output).contains("print(result)"))
        #expect(!moduleLevel(in: output).contains("print("))
    }

    @Test func inputCallQuarantined() {
        let output = extractor.sanitizeCellForModule(#"name = input("Enter name: ")"#)
        #expect(guardBlock(in: output).contains("input("))
    }

    @Test func forLoopQuarantined() {
        let source = "for i in range(10):\n    print(i)"
        let output = extractor.sanitizeCellForModule(source)
        #expect(guardBlock(in: output).contains("for i in range(10):"))
        #expect(!moduleLevel(in: output).contains("for i"))
    }

    @Test func whileLoopQuarantined() {
        let source = "while True:\n    break"
        let output = extractor.sanitizeCellForModule(source)
        #expect(guardBlock(in: output).contains("while True:"))
    }

    @Test func ifNameMainQuarantined() {
        let source = "if __name__ == \"__main__\":\n    print(\"running\")"
        let output = extractor.sanitizeCellForModule(source)
        #expect(guardBlock(in: output).contains("if __name__ == \"__main__\":"))
    }

    @Test func bareIfStatementQuarantined() {
        let source = "if x > 0:\n    print(x)"
        let output = extractor.sanitizeCellForModule(source)
        #expect(guardBlock(in: output).contains("if x > 0:"))
    }

    @Test func callWithInlineCommentContainingEqualsQuarantined() {
        // Regression: the inline comment's `=` must not make this look like a
        // module-level assignment. The print(...) is a bare call → quarantined,
        // so it doesn't leak stdout at module import time.
        let output = extractor.sanitizeCellForModule("print(x)  # a = b")
        #expect(guardBlock(in: output).contains("print(x)"))
        #expect(!moduleLevel(in: output).contains("print("))
    }

    @Test func callWithDoseCommentQuarantined() {
        // The motivating example from the bug report.
        let output = extractor.sanitizeCellForModule(
            "print(total_dose_mg) #when weight_kg = 30, dose = 450mg"
        )
        #expect(guardBlock(in: output).contains("print(total_dose_mg)"))
        #expect(!moduleLevel(in: output).contains("print("))
    }

    @Test func assignmentWithCallRHSQuarantined() {
        let output = extractor.sanitizeCellForModule("patient0 = Patient(name=\"Alice\")")
        #expect(guardBlock(in: output).contains("patient0 = Patient"))
        #expect(!moduleLevel(in: output).contains("patient0"))
    }

    @Test func methodCallAssignmentQuarantined() {
        let output = extractor.sanitizeCellForModule("data = df.read_csv(\"file.csv\")")
        #expect(guardBlock(in: output).contains("data = df"))
    }

    // MARK: - Magic/shell stripping

    @Test func magicLineStripped() {
        let source = "%matplotlib inline\nimport matplotlib.pyplot as plt"
        let output = extractor.sanitizeCellForModule(source)
        #expect(!output.contains("%matplotlib"))
        #expect(output.contains("import matplotlib"))
    }

    @Test func shellCommandStripped() {
        let source = "!pip install numpy\nimport numpy as np"
        let output = extractor.sanitizeCellForModule(source)
        #expect(!output.contains("!pip"))
        #expect(output.contains("import numpy"))
    }

    // MARK: - Mixed cells

    @Test func mixedCellBMIExample() {
        // Mirrors the motivating example from the issue.
        let source = """
            BMI_UNDERWEIGHT_MAX: float = 18.5
            BMI_NORMAL_MAX: float = 25.0
            BMI_OVERWEIGHT_MAX: float = 30.0

            assert BMI_NORMAL_MAX > BMI_UNDERWEIGHT_MAX

            def bmi_category(b: float) -> str:
                if b < BMI_UNDERWEIGHT_MAX:
                    return "underweight"
                elif b < BMI_NORMAL_MAX:
                    return "normal weight"
                elif b < BMI_OVERWEIGHT_MAX:
                    return "overweight"
                else:
                    return "obese"
            """
        let output = extractor.sanitizeCellForModule(source)
        let modLevel = moduleLevel(in: output)

        // Constants and function definition at module level.
        #expect(modLevel.contains("BMI_UNDERWEIGHT_MAX: float = 18.5"))
        #expect(modLevel.contains("BMI_NORMAL_MAX: float = 25.0"))
        #expect(modLevel.contains("def bmi_category"))

        // Assert quarantined.
        #expect(!modLevel.contains("assert"))
        #expect(guardBlock(in: output).contains("assert BMI_NORMAL_MAX > BMI_UNDERWEIGHT_MAX"))
    }

    @Test func constantsRemainingAccessibleToFunction() {
        // Both constants and function at module level: the function can reference
        // the constants when the module is imported by the test runner.
        let source = """
            MAX_VALUE = 100
            MIN_VALUE = 0

            def clamp(x):
                return max(MIN_VALUE, min(MAX_VALUE, x))
            """
        let output = extractor.sanitizeCellForModule(source)
        let modLevel = moduleLevel(in: output)
        #expect(modLevel.contains("MAX_VALUE = 100"))
        #expect(modLevel.contains("MIN_VALUE = 0"))
        #expect(modLevel.contains("def clamp(x):"))
        #expect(!output.contains("if __name__"))
    }

    @Test func safeAndUnsafeStatementsSeparated() {
        // Safe assignments and function defs should remain at module level even
        // when interspersed with quarantined calls.
        let source = """
            X = 10
            print(X)
            Y = 20
            print(Y)
            """
        let output = extractor.sanitizeCellForModule(source)
        let modLevel = moduleLevel(in: output)
        #expect(modLevel.contains("X = 10"))
        #expect(modLevel.contains("Y = 20"))
        #expect(guardBlock(in: output).contains("print(X)"))
        #expect(guardBlock(in: output).contains("print(Y)"))
    }

    // MARK: - False-positive guard (variable names sharing keyword prefixes)

    @Test func variableNamedFormat() {
        // `format` starts with `for` — must not be quarantined.
        let output = extractor.sanitizeCellForModule("format = \"%.2f\"")
        #expect(moduleLevel(in: output).contains("format ="))
        #expect(!output.contains("if __name__"))
    }

    @Test func variableNamedElseResult() {
        // `else_result` starts with `else` — must not be quarantined.
        let output = extractor.sanitizeCellForModule("else_result = 0")
        #expect(moduleLevel(in: output).contains("else_result = 0"))
        #expect(!output.contains("if __name__"))
    }

    // MARK: - sanitizeCellForModule keeps the cell body raw

    @Test func sanitizeKeepsSafeCodeRawNotTryWrapped() {
        // The per-cell try/except now lives in wrapCellForResilientLoad; the
        // sanitized body is the plain safe code so it can be compiled as a unit.
        let output = extractor.sanitizeCellForModule("daily_ml = ____")
        #expect(output == "daily_ml = ____")
    }

    // MARK: - Python string literal encoding

    @Test func pythonStringLiteralEscapes() {
        #expect(extractor.pythonStringLiteral("x") == "\"x\"")
        #expect(extractor.pythonStringLiteral("a\nb") == "\"a\\nb\"")
        #expect(extractor.pythonStringLiteral("say \"hi\"") == "\"say \\\"hi\\\"\"")
    }

    @Test func pythonStringLiteralDoesNotEscapeForwardSlash() {
        // `\/` is valid JSON but an INVALID Python escape; emitting it would make
        // the per-cell compile() raise SyntaxError, dropping any cell with a `/`
        // (e.g. `daily_l = daily_ml / 1000`). Regression guard for v0.4.220.
        #expect(extractor.pythonStringLiteral("daily_l = daily_ml / 1000") == "\"daily_l = daily_ml / 1000\"")
        #expect(!extractor.pythonStringLiteral("a / b").contains("\\/"))
    }

    @Test func divisionCellSurvivesExtraction() throws {
        // End-to-end guard: a cell using `/` must keep the `/` in the generated
        // module so its exec(compile()) doesn't fail and its variables resolve.
        let cells: [[String: Any]] = [
            ["cell_type": "code", "source": ["daily_ml = 2450\ndaily_l = daily_ml / 1000\n"]]
        ]
        let notebook: [String: Any] = ["cells": cells]
        let result = try extractor.extractPythonSource(from: notebook, filename: "submission.ipynb")
        #expect(result.source.contains("daily_ml / 1000"))
        #expect(!result.source.contains("\\/"))
    }

    // MARK: - Per-cell exec(compile()) isolation

    @Test func wrapEmitsExecCompile() {
        let output = extractor.wrapCellForResilientLoad("daily_ml = ____", label: "cell 7")
        #expect(output.hasPrefix("try:"))
        #expect(output.contains("exec(compile(\"daily_ml = ____\", \"cell 7\", \"exec\"), globals())"))
        #expect(output.contains("except Exception:"))
    }

    @Test func wrapLeavesFutureImportRaw() {
        // `from __future__` must stay a raw module-top statement (a per-cell
        // compile would scope it to that cell only).
        let output = extractor.wrapCellForResilientLoad("from __future__ import annotations", label: "cell 1")
        #expect(output == "from __future__ import annotations")
        #expect(!output.contains("exec(compile"))
    }

    @Test func eachCellCompiledIndependently() throws {
        // A NameError in cell 2 must not prevent cell 1's variable from loading;
        // each cell is its own exec(compile()) unit.
        let cells: [[String: Any]] = [
            ["cell_type": "code", "source": ["resting_hr = 72\n"]],
            ["cell_type": "code", "source": ["max_hr = 220 - age\n"]],
        ]
        let notebook: [String: Any] = ["cells": cells]
        let result = try extractor.extractPythonSource(from: notebook, filename: "submission.ipynb")
        #expect(result.source.components(separatedBy: "exec(compile(").count - 1 == 2)
        #expect(result.source.contains("resting_hr = 72"))
        #expect(result.source.contains("max_hr = 220 - age"))
    }

    @Test func syntaxErrorCellIsCompiledAsAStringNotInlined() throws {
        // The bad cell's source lives inside a compile() string literal, so it
        // can't fail the whole-module compile — only its own exec is skipped at
        // load. The good cell is emitted as its own unit alongside it.
        let cells: [[String: Any]] = [
            ["cell_type": "code", "source": ["good = 1\n"]],
            ["cell_type": "code", "source": ["broken = (\n"]],  // syntax error
        ]
        let notebook: [String: Any] = ["cells": cells]
        let result = try extractor.extractPythonSource(from: notebook, filename: "submission.ipynb")
        #expect(result.source.components(separatedBy: "exec(compile(").count - 1 == 2)
        #expect(result.source.contains("good = 1"))
        // The broken source is quoted inside compile(...), never emitted as bare code.
        #expect(result.source.contains("\"broken = (\""))
    }

    @Test func commentOnlyCellDoesNotProduceEmptyTryBody() throws {
        // Regression: an untouched comment-only cell must not become
        // `try:\n    # comment` (an empty try body → SyntaxError that zeros the
        // whole notebook). It is compiled as a string instead.
        let cells: [[String: Any]] = [
            ["cell_type": "code", "source": ["# Your code here\n"]],
            ["cell_type": "code", "source": ["age = 20\n"]],
        ]
        let notebook: [String: Any] = ["cells": cells]
        let result = try extractor.extractPythonSource(from: notebook, filename: "submission.ipynb")
        #expect(result.source.contains("compile(\"# Your code here\""))
        #expect(result.source.contains("age = 20"))
    }

    // MARK: - End-to-end: run the generated module through a real python3

    @Test func generatedModuleLoadsUnderRealPython3() throws {
        // The shape-level tests above can't catch an emitted-Python bug that
        // still *looks* plausible — the v0.4.220 `\/` regression compiled fine
        // as a Swift string but made the inner compile() throw. Only a real
        // interpreter catches that whole class, so here we extract a notebook
        // (division cell, syntax-error cell, comment-only cell, and a trailing
        // cell) and ask python3 which names actually resolve after import.
        let python3Paths = ["/usr/bin/python3", "/usr/local/bin/python3", "/opt/homebrew/bin/python3"]
        guard python3Paths.contains(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return  // python3 unavailable on this platform — skip
        }

        let cells: [[String: Any]] = [
            ["cell_type": "code", "source": ["good = 1\n"]],
            ["cell_type": "code", "source": ["daily_ml = 2450\ndaily_l = daily_ml / 1000\n"]],  // division
            ["cell_type": "code", "source": ["broken = (\n"]],  // syntax error → isolated
            ["cell_type": "code", "source": ["# Your code here\n"]],  // comment-only → harmless
            ["cell_type": "code", "source": ["after = 7\n"]],
        ]
        let notebook: [String: Any] = ["cells": cells]
        let source = try extractor.extractPythonSource(from: notebook, filename: "submission.ipynb").source

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nbx-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let modulePath = dir.appendingPathComponent("submission.py")
        try source.write(to: modulePath, atomically: true, encoding: .utf8)

        // Load the module the way the worker does (importlib + exec_module) and
        // report which names resolved.
        let probe = """
            import importlib.util, json
            spec = importlib.util.spec_from_file_location("submission", r"\(modulePath.path)")
            m = importlib.util.module_from_spec(spec)
            try:
                spec.loader.exec_module(m)
            except Exception:
                pass
            names = ["good", "daily_ml", "daily_l", "broken", "after"]
            print(json.dumps({n: hasattr(m, n) for n in names}))
            """

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["python3", "-c", probe]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let out = (String(bytes: outData, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let defined = try #require(try? JSONDecoder().decode([String: Bool].self, from: Data(out.utf8)))

        #expect(defined["good"] == true)
        // daily_ml/daily_l guard the v0.4.220 `\/`-escaping regression.
        #expect(defined["daily_ml"] == true, "division cell must define daily_ml")
        #expect(defined["daily_l"] == true, "division cell must define daily_l")
        #expect(defined["after"] == true, "a later cell must still load after a broken cell")
        #expect(defined["broken"] == false, "syntax-error cell must be isolated, not defined")
    }
}
