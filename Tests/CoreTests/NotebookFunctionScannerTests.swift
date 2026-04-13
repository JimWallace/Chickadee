// Tests/CoreTests/NotebookFunctionScannerTests.swift
//
// Unit tests for NotebookFunctionScanner.

import Testing
import Foundation
@testable import Core

struct NotebookFunctionScannerTests {

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

    @Test func emptyNotebook() {
        let nb = Data("""
        {"cells":[],"metadata":{},"nbformat":4,"nbformat_minor":5}
        """.utf8)
        #expect(scanNotebookForFunctions(nb).isEmpty)
    }

    @Test func invalidJSON() {
        #expect(scanNotebookForFunctions(Data("not json".utf8)).isEmpty)
    }

    @Test func singleSimpleFunction() {
        let nb = notebook(code: "def foo(a, b):\n    return a + b\n")
        let fns = scanNotebookForFunctions(nb)
        #expect(fns.count == 1)
        #expect(fns[0].name == "foo")
        #expect(fns[0].paramNames == ["a", "b"])
        #expect(!fns[0].hasTypeHints)
        #expect(!fns[0].hasDocstring)
    }

    @Test func functionWithTypeHints() {
        let nb = notebook(code: "def bar(x: int, y: str) -> bool:\n    return True\n")
        let fns = scanNotebookForFunctions(nb)
        #expect(fns.count == 1)
        #expect(fns[0].name == "bar")
        #expect(fns[0].paramNames == ["x", "y"])
        #expect(fns[0].hasTypeHints)
    }

    @Test func functionWithReturnTypeHintOnly() {
        let nb = notebook(code: "def baz(n) -> list:\n    return []\n")
        let fns = scanNotebookForFunctions(nb)
        #expect(fns.count == 1)
        #expect(fns[0].hasTypeHints)
    }

    @Test func functionWithDocstring() {
        let nb = notebook(code: "def greet(name):\n    \"\"\"Greet someone.\"\"\"\n    return 'Hi ' + name\n")
        let fns = scanNotebookForFunctions(nb)
        #expect(fns.count == 1)
        #expect(fns[0].hasDocstring)
    }

    @Test func privateFunctionExcluded() {
        let nb = notebook(code: "def _helper(x):\n    pass\ndef public_fn(x):\n    pass\n")
        let fns = scanNotebookForFunctions(nb)
        #expect(fns.count == 1)
        #expect(fns[0].name == "public_fn")
    }

    @Test func selfAndClsExcluded() {
        let nb = notebook(code: "def method(self, x, y):\n    pass\n")
        // Top-level def with self — unusual but the scanner just strips self
        let fns = scanNotebookForFunctions(nb)
        #expect(fns.count == 1)
        #expect(fns[0].paramNames == ["x", "y"])
    }

    @Test func noParameters() {
        let nb = notebook(code: "def get_count():\n    return 0\n")
        let fns = scanNotebookForFunctions(nb)
        #expect(fns.count == 1)
        #expect(fns[0].paramNames == [])
    }

    @Test func varargsExcluded() {
        let nb = notebook(code: "def variadic(a, *args, **kwargs):\n    pass\n")
        let fns = scanNotebookForFunctions(nb)
        #expect(fns.count == 1)
        #expect(fns[0].paramNames == ["a"])
    }

    @Test func defaultValueStripped() {
        let nb = notebook(code: "def increment(n, step=1):\n    return n + step\n")
        let fns = scanNotebookForFunctions(nb)
        #expect(fns.count == 1)
        #expect(fns[0].paramNames == ["n", "step"])
    }

    @Test func multipleFunctionsInOneCell() {
        let nb = notebook(code: "def add(a, b):\n    return a + b\n\ndef subtract(a, b):\n    return a - b\n")
        let fns = scanNotebookForFunctions(nb)
        #expect(fns.count == 2)
        #expect(fns[0].name == "add")
        #expect(fns[1].name == "subtract")
    }

    @Test func functionsAcrossMultipleCells() {
        let nb = notebook(cells: [
            "def foo(x):\n    return x\n",
            "x = 1  # not a function",
            "def bar(y):\n    return y\n"
        ])
        let fns = scanNotebookForFunctions(nb)
        #expect(fns.count == 2)
        #expect(fns[0].name == "foo")
        #expect(fns[1].name == "bar")
    }

    @Test func indentedFunctionNotTopLevel() {
        // Class methods or nested functions — indented, not top-level.
        let nb = notebook(code: "class MyClass:\n    def method(self, x):\n        pass\n")
        let fns = scanNotebookForFunctions(nb)
        #expect(fns.isEmpty, "Indented method should not be treated as top-level")
    }

    @Test func markdownCellIgnored() {
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
        #expect(scanNotebookForFunctions(Data(json.utf8)).isEmpty)
    }

    @Test func paramCount() {
        let nb = notebook(code: "def triple(a, b, c):\n    pass\n")
        let fns = scanNotebookForFunctions(nb)
        #expect(fns.first?.paramCount == 3)
    }

    @Test func sourceAsArrayOfLines() {
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
        #expect(fns.count == 1)
        #expect(fns[0].name == "greet")
    }
}
