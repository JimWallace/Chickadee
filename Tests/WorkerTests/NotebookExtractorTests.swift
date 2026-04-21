import XCTest
@testable import chickadee_runner

final class NotebookExtractorTests: XCTestCase {
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

    func testFunctionDefPreserved() {
        let output = extractor.sanitizeCellForModule("def add(a, b):\n    return a + b")
        XCTAssertTrue(moduleLevel(in: output).contains("def add(a, b):"))
        XCTAssertFalse(output.contains("if __name__"))
    }

    func testAsyncFunctionDefPreserved() {
        let output = extractor.sanitizeCellForModule("async def fetch():\n    pass")
        XCTAssertTrue(moduleLevel(in: output).contains("async def fetch():"))
        XCTAssertFalse(output.contains("if __name__"))
    }

    func testClassDefPreserved() {
        let output = extractor.sanitizeCellForModule("class Foo:\n    pass")
        XCTAssertTrue(moduleLevel(in: output).contains("class Foo:"))
        XCTAssertFalse(output.contains("if __name__"))
    }

    func testImportPreserved() {
        let output = extractor.sanitizeCellForModule("import math")
        XCTAssertTrue(moduleLevel(in: output).contains("import math"))
        XCTAssertFalse(output.contains("if __name__"))
    }

    func testFromImportPreserved() {
        let output = extractor.sanitizeCellForModule("from math import sqrt")
        XCTAssertTrue(moduleLevel(in: output).contains("from math import sqrt"))
        XCTAssertFalse(output.contains("if __name__"))
    }

    func testDecoratorPreserved() {
        let output = extractor.sanitizeCellForModule("@property\ndef value(self):\n    return self._v")
        XCTAssertTrue(moduleLevel(in: output).contains("@property"))
        XCTAssertFalse(output.contains("if __name__"))
    }

    // MARK: - Safe: constants and simple assignments

    func testIntegerConstantPreserved() {
        let output = extractor.sanitizeCellForModule("MAX = 100")
        XCTAssertTrue(moduleLevel(in: output).contains("MAX = 100"))
        XCTAssertFalse(output.contains("if __name__"))
    }

    func testFloatConstantPreserved() {
        let output = extractor.sanitizeCellForModule("BMI_UNDERWEIGHT_MAX = 18.5")
        XCTAssertTrue(moduleLevel(in: output).contains("BMI_UNDERWEIGHT_MAX = 18.5"))
        XCTAssertFalse(output.contains("if __name__"))
    }

    func testAnnotatedConstantPreserved() {
        let output = extractor.sanitizeCellForModule("BMI_NORMAL_MAX: float = 25.0")
        XCTAssertTrue(moduleLevel(in: output).contains("BMI_NORMAL_MAX: float = 25.0"))
        XCTAssertFalse(output.contains("if __name__"))
    }

    func testSimpleArithmeticPreserved() {
        let output = extractor.sanitizeCellForModule("result = 2 + 3")
        XCTAssertTrue(moduleLevel(in: output).contains("result = 2 + 3"))
        XCTAssertFalse(output.contains("if __name__"))
    }

    func testTupleAssignmentPreserved() {
        let output = extractor.sanitizeCellForModule("a, b = 1, 2")
        XCTAssertTrue(moduleLevel(in: output).contains("a, b = 1, 2"))
        XCTAssertFalse(output.contains("if __name__"))
    }

    func testListLiteralPreserved() {
        let output = extractor.sanitizeCellForModule("items = [1, 2, 3]")
        XCTAssertTrue(moduleLevel(in: output).contains("items = [1, 2, 3]"))
        XCTAssertFalse(output.contains("if __name__"))
    }

    func testDictLiteralPreserved() {
        let output = extractor.sanitizeCellForModule(#"mapping = {"a": 1, "b": 2}"#)
        XCTAssertTrue(moduleLevel(in: output).contains("mapping ="))
        XCTAssertFalse(output.contains("if __name__"))
    }

    func testStringConstantPreserved() {
        let output = extractor.sanitizeCellForModule(#"GREETING = "hello""#)
        XCTAssertTrue(moduleLevel(in: output).contains("GREETING ="))
        XCTAssertFalse(output.contains("if __name__"))
    }

    func testDocstringPreserved() {
        let output = extractor.sanitizeCellForModule("\"\"\"Module docstring.\"\"\"")
        XCTAssertTrue(moduleLevel(in: output).contains("Module docstring"))
        XCTAssertFalse(output.contains("if __name__"))
    }

    // MARK: - Safe: multi-line bracket continuation

    func testMultiLineBracketedListPreserved() {
        // The closing `]` is flush-left; bracket depth tracking must prevent
        // it from being treated as a new top-level statement.
        let source = "PRIMES = [\n1,\n2,\n3\n]"
        let output = extractor.sanitizeCellForModule(source)
        XCTAssertTrue(moduleLevel(in: output).contains("PRIMES = ["))
        XCTAssertFalse(guardBlock(in: output).contains("PRIMES"))
    }

    // MARK: - Quarantined: control flow and side effects

    func testAssertQuarantined() {
        let output = extractor.sanitizeCellForModule("assert x > 0")
        XCTAssertTrue(guardBlock(in: output).contains("assert x > 0"))
        XCTAssertFalse(moduleLevel(in: output).contains("assert"))
    }

    func testPrintCallQuarantined() {
        let output = extractor.sanitizeCellForModule("print(result)")
        XCTAssertTrue(guardBlock(in: output).contains("print(result)"))
        XCTAssertFalse(moduleLevel(in: output).contains("print("))
    }

    func testInputCallQuarantined() {
        let output = extractor.sanitizeCellForModule(#"name = input("Enter name: ")"#)
        XCTAssertTrue(guardBlock(in: output).contains("input("))
    }

    func testForLoopQuarantined() {
        let source = "for i in range(10):\n    print(i)"
        let output = extractor.sanitizeCellForModule(source)
        XCTAssertTrue(guardBlock(in: output).contains("for i in range(10):"))
        XCTAssertFalse(moduleLevel(in: output).contains("for i"))
    }

    func testWhileLoopQuarantined() {
        let source = "while True:\n    break"
        let output = extractor.sanitizeCellForModule(source)
        XCTAssertTrue(guardBlock(in: output).contains("while True:"))
    }

    func testIfNameMainQuarantined() {
        let source = "if __name__ == \"__main__\":\n    print(\"running\")"
        let output = extractor.sanitizeCellForModule(source)
        XCTAssertTrue(guardBlock(in: output).contains("if __name__ == \"__main__\":"))
    }

    func testBareIfStatementQuarantined() {
        let source = "if x > 0:\n    print(x)"
        let output = extractor.sanitizeCellForModule(source)
        XCTAssertTrue(guardBlock(in: output).contains("if x > 0:"))
    }

    func testAssignmentWithCallRHSQuarantined() {
        let output = extractor.sanitizeCellForModule("patient0 = Patient(name=\"Alice\")")
        XCTAssertTrue(guardBlock(in: output).contains("patient0 = Patient"))
        XCTAssertFalse(moduleLevel(in: output).contains("patient0"))
    }

    func testMethodCallAssignmentQuarantined() {
        let output = extractor.sanitizeCellForModule("data = df.read_csv(\"file.csv\")")
        XCTAssertTrue(guardBlock(in: output).contains("data = df"))
    }

    // MARK: - Magic/shell stripping

    func testMagicLineStripped() {
        let source = "%matplotlib inline\nimport matplotlib.pyplot as plt"
        let output = extractor.sanitizeCellForModule(source)
        XCTAssertFalse(output.contains("%matplotlib"))
        XCTAssertTrue(output.contains("import matplotlib"))
    }

    func testShellCommandStripped() {
        let source = "!pip install numpy\nimport numpy as np"
        let output = extractor.sanitizeCellForModule(source)
        XCTAssertFalse(output.contains("!pip"))
        XCTAssertTrue(output.contains("import numpy"))
    }

    // MARK: - Mixed cells

    func testMixedCellBMIExample() {
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
        XCTAssertTrue(modLevel.contains("BMI_UNDERWEIGHT_MAX: float = 18.5"))
        XCTAssertTrue(modLevel.contains("BMI_NORMAL_MAX: float = 25.0"))
        XCTAssertTrue(modLevel.contains("def bmi_category"))

        // Assert quarantined.
        XCTAssertFalse(modLevel.contains("assert"))
        XCTAssertTrue(guardBlock(in: output).contains("assert BMI_NORMAL_MAX > BMI_UNDERWEIGHT_MAX"))
    }

    func testConstantsRemainingAccessibleToFunction() {
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
        XCTAssertTrue(modLevel.contains("MAX_VALUE = 100"))
        XCTAssertTrue(modLevel.contains("MIN_VALUE = 0"))
        XCTAssertTrue(modLevel.contains("def clamp(x):"))
        XCTAssertFalse(output.contains("if __name__"))
    }

    func testSafeAndUnsafeStatementsSeparated() {
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
        XCTAssertTrue(modLevel.contains("X = 10"))
        XCTAssertTrue(modLevel.contains("Y = 20"))
        XCTAssertTrue(guardBlock(in: output).contains("print(X)"))
        XCTAssertTrue(guardBlock(in: output).contains("print(Y)"))
    }

    // MARK: - False-positive guard (variable names sharing keyword prefixes)

    func testVariableNamedFormat() {
        // `format` starts with `for` — must not be quarantined.
        let output = extractor.sanitizeCellForModule("format = \"%.2f\"")
        XCTAssertTrue(moduleLevel(in: output).contains("format ="))
        XCTAssertFalse(output.contains("if __name__"))
    }

    func testVariableNamedElseResult() {
        // `else_result` starts with `else` — must not be quarantined.
        let output = extractor.sanitizeCellForModule("else_result = 0")
        XCTAssertTrue(moduleLevel(in: output).contains("else_result = 0"))
        XCTAssertFalse(output.contains("if __name__"))
    }
}
