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

    // MARK: - Per-cell error isolation (sequestering broken cells)

    @Test func moduleLevelAssignmentWrappedInTryExcept() {
        // A placeholder/undefined-name assignment that fails at import time is
        // wrapped so it can't abort loading the rest of the module.
        let output = extractor.sanitizeCellForModule("daily_ml = ____")
        #expect(output.contains("try:"))
        #expect(output.contains("daily_ml = ____"))
        #expect(output.contains("except Exception:"))
    }

    @Test func definedConstantStillAccessibleWhenWrapped() {
        // The wrapped block keeps the assignment at module scope (try blocks
        // don't create a new namespace), so the value remains importable.
        let output = extractor.sanitizeCellForModule("resting_hr = 72")
        #expect(output.contains("resting_hr = 72"))
        #expect(output.contains("try:"))
    }

    @Test func futureImportNotWrapped() {
        // `from __future__` must remain at module top — wrapping it would be a
        // SyntaxError that breaks the whole-file compile.
        let output = extractor.sanitizeCellForModule("from __future__ import annotations")
        #expect(output.contains("from __future__ import annotations"))
        #expect(!output.contains("try:"))
    }

    @Test func eachCellWrappedIndependently() throws {
        // A NameError in cell 2 must not prevent cell 1's variable from loading.
        let cells: [[String: Any]] = [
            ["cell_type": "code", "source": ["resting_hr = 72\n"]],
            ["cell_type": "code", "source": ["max_hr = 220 - age\n"]],
        ]
        let notebook: [String: Any] = ["cells": cells]
        let result = try extractor.extractPythonSource(from: notebook, filename: "submission.ipynb")
        #expect(result.source.components(separatedBy: "try:").count - 1 == 2)
        #expect(result.source.contains("resting_hr = 72"))
        #expect(result.source.contains("max_hr = 220 - age"))
    }
}
