// Tests/CoreTests/NotebookFunctionScannerTests.swift
//
// Unit tests for NotebookFunctionScanner.

import XCTest
@testable import Core

final class NotebookFunctionScannerTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a minimal .ipynb JSON with a single code cell.
    private func notebook(code: String) -> Data {
        let escaped = code
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let json = """
        {
          "cells": [
            {
              "cell_type": "code",
              "metadata": {},
              "source": "\(escaped)"
            }
          ],
          "metadata": {},
          "nbformat": 4,
          "nbformat_minor": 5
        }
        """
        return Data(json.utf8)
    }

    /// Builds a notebook with multiple code cells.
    private func notebook(cells: [String]) -> Data {
        let cellsJSON = cells.map { code -> String in
            let escaped = code
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            return """
            {
              "cell_type": "code",
              "metadata": {},
              "source": "\(escaped)"
            }
            """
        }.joined(separator: ",")
        let json = """
        {
          "cells": [\(cellsJSON)],
          "metadata": {},
          "nbformat": 4,
          "nbformat_minor": 5
        }
        """
        return Data(json.utf8)
    }

    // MARK: - Tests

    func testEmptyNotebook() {
        let nb = Data("""
        {"cells":[],"metadata":{},"nbformat":4,"nbformat_minor":5}
        """.utf8)
        let fns = scanNotebookForFunctions(nb)
        XCTAssertTrue(fns.isEmpty)
    }

    func testInvalidJSON() {
        let fns = scanNotebookForFunctions(Data("not json".utf8))
        XCTAssertTrue(fns.isEmpty)
    }

    func testSingleSimpleFunction() {
        let nb = notebook(code: "def foo(a, b):\n    return a + b\n")
        let fns = scanNotebookForFunctions(nb)
        XCTAssertEqual(fns.count, 1)
        XCTAssertEqual(fns[0].name, "foo")
        XCTAssertEqual(fns[0].paramNames, ["a", "b"])
        XCTAssertFalse(fns[0].hasTypeHints)
        XCTAssertFalse(fns[0].hasDocstring)
    }

    func testFunctionWithTypeHints() {
        let nb = notebook(code: "def bar(x: int, y: str) -> bool:\n    return True\n")
        let fns = scanNotebookForFunctions(nb)
        XCTAssertEqual(fns.count, 1)
        XCTAssertEqual(fns[0].name, "bar")
        XCTAssertEqual(fns[0].paramNames, ["x", "y"])
        XCTAssertTrue(fns[0].hasTypeHints)
    }

    func testFunctionWithReturnTypeHintOnly() {
        let nb = notebook(code: "def baz(n) -> list:\n    return []\n")
        let fns = scanNotebookForFunctions(nb)
        XCTAssertEqual(fns.count, 1)
        XCTAssertTrue(fns[0].hasTypeHints)
    }

    func testFunctionWithDocstring() {
        let nb = notebook(code: "def greet(name):\n    \"\"\"Greet someone.\"\"\"\n    return 'Hi ' + name\n")
        let fns = scanNotebookForFunctions(nb)
        XCTAssertEqual(fns.count, 1)
        XCTAssertTrue(fns[0].hasDocstring)
    }

    func testPrivateFunctionExcluded() {
        let nb = notebook(code: "def _helper(x):\n    pass\ndef public_fn(x):\n    pass\n")
        let fns = scanNotebookForFunctions(nb)
        XCTAssertEqual(fns.count, 1)
        XCTAssertEqual(fns[0].name, "public_fn")
    }

    func testSelfAndClsExcluded() {
        let nb = notebook(code: "def method(self, x, y):\n    pass\n")
        // Top-level def with self — unusual but the scanner just strips self
        let fns = scanNotebookForFunctions(nb)
        XCTAssertEqual(fns.count, 1)
        XCTAssertEqual(fns[0].paramNames, ["x", "y"])
    }

    func testNoParameters() {
        let nb = notebook(code: "def get_count():\n    return 0\n")
        let fns = scanNotebookForFunctions(nb)
        XCTAssertEqual(fns.count, 1)
        XCTAssertEqual(fns[0].paramNames, [])
    }

    func testVarargsExcluded() {
        let nb = notebook(code: "def variadic(a, *args, **kwargs):\n    pass\n")
        let fns = scanNotebookForFunctions(nb)
        XCTAssertEqual(fns.count, 1)
        XCTAssertEqual(fns[0].paramNames, ["a"])
    }

    func testDefaultValueStripped() {
        let nb = notebook(code: "def increment(n, step=1):\n    return n + step\n")
        let fns = scanNotebookForFunctions(nb)
        XCTAssertEqual(fns.count, 1)
        XCTAssertEqual(fns[0].paramNames, ["n", "step"])
    }

    func testMultipleFunctionsInOneCell() {
        let nb = notebook(code: "def add(a, b):\n    return a + b\n\ndef subtract(a, b):\n    return a - b\n")
        let fns = scanNotebookForFunctions(nb)
        XCTAssertEqual(fns.count, 2)
        XCTAssertEqual(fns[0].name, "add")
        XCTAssertEqual(fns[1].name, "subtract")
    }

    func testFunctionsAcrossMultipleCells() {
        let nb = notebook(cells: [
            "def foo(x):\n    return x\n",
            "x = 1  # not a function",
            "def bar(y):\n    return y\n"
        ])
        let fns = scanNotebookForFunctions(nb)
        XCTAssertEqual(fns.count, 2)
        XCTAssertEqual(fns[0].name, "foo")
        XCTAssertEqual(fns[1].name, "bar")
    }

    func testIndentedFunctionNotTopLevel() {
        // Class methods or nested functions — indented, not top-level.
        let nb = notebook(code: "class MyClass:\n    def method(self, x):\n        pass\n")
        let fns = scanNotebookForFunctions(nb)
        XCTAssertTrue(fns.isEmpty, "Indented method should not be treated as top-level")
    }

    func testMarkdownCellIgnored() {
        let json = """
        {
          "cells": [
            {
              "cell_type": "markdown",
              "metadata": {},
              "source": "def fake_function(x):\\n    pass"
            }
          ],
          "metadata": {},
          "nbformat": 4,
          "nbformat_minor": 5
        }
        """
        let fns = scanNotebookForFunctions(Data(json.utf8))
        XCTAssertTrue(fns.isEmpty)
    }

    func testParamCount() {
        let nb = notebook(code: "def triple(a, b, c):\n    pass\n")
        let fns = scanNotebookForFunctions(nb)
        XCTAssertEqual(fns.first?.paramCount, 3)
    }

    func testSourceAsArrayOfLines() {
        // JupyterLite stores source as an array of strings, one per line.
        let json = """
        {
          "cells": [
            {
              "cell_type": "code",
              "metadata": {},
              "source": ["def greet(name):\\n", "    return 'hi'\\n"]
            }
          ],
          "metadata": {},
          "nbformat": 4,
          "nbformat_minor": 5
        }
        """
        let fns = scanNotebookForFunctions(Data(json.utf8))
        XCTAssertEqual(fns.count, 1)
        XCTAssertEqual(fns[0].name, "greet")
    }
}
