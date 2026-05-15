// Tests/CoreTests/NotebookFunctionScannerTests.swift
//
// Unit tests for NotebookFunctionScanner.

import Foundation
import Testing

@testable import Core

struct NotebookFunctionScannerTests {

    // MARK: - Helpers

    /// Builds a minimal .ipynb JSON with a single code cell.
    private func notebook(code: String) -> Data {
        let escaped =
            code
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
            let escaped =
                code
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
        let nb = Data(
            """
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
        // Per-parameter type capture for the type-aware coercion in the
        // family editor.
        #expect(fns[0].paramTypes == ["int", "str"])
        #expect(fns[0].returnType == "bool")
    }

    @Test func functionWithReturnTypeHintOnly() {
        let nb = notebook(code: "def baz(n) -> list:\n    return []\n")
        let fns = scanNotebookForFunctions(nb)
        #expect(fns.count == 1)
        #expect(fns[0].hasTypeHints)
        #expect(fns[0].paramTypes == [nil])
        #expect(fns[0].returnType == "list")
    }

    @Test func functionWithMixedAnnotations() {
        // Partial type hints: `a: int` and `b` untyped, default on `b`.
        let nb = notebook(code: "def mix(a: int, b = 5) -> float:\n    return float(a + b)\n")
        let fns = scanNotebookForFunctions(nb)
        #expect(fns.count == 1)
        #expect(fns[0].paramNames == ["a", "b"])
        #expect(fns[0].paramTypes == ["int", nil])
        #expect(fns[0].returnType == "float")
    }

    @Test func functionWithDefaultKeepsType() {
        // `x: int = 0` — type must survive even when a default value is present.
        let nb = notebook(code: "def with_default(x: int = 0) -> int:\n    return x\n")
        let fns = scanNotebookForFunctions(nb)
        #expect(fns[0].paramTypes == ["int"])
        #expect(fns[0].returnType == "int")
    }

    @Test func paramHasDefaultRecorded() {
        // v0.4.94: a parallel `paramHasDefault` array so the family editor
        // can mark defaulted columns as optional (empty cell ⇒ use Python
        // default at test time).
        let nb = notebook(code: "def check(dob: str, currentDate: str = \"20260301\") -> bool:\n    return True\n")
        let fns = scanNotebookForFunctions(nb)
        #expect(fns.count == 1)
        #expect(fns[0].paramHasDefault == [false, true])
        #expect(fns[0].paramTypes == ["str", "str"])
    }

    @Test func paramHasDefaultEmptyWhenNoParams() {
        let nb = notebook(code: "def nothing():\n    return 1\n")
        let fns = scanNotebookForFunctions(nb)
        #expect(fns[0].paramHasDefault == [])
    }

    @Test func functionWithoutAnyAnnotations() {
        // Baseline: no hints at all → paramTypes is [nil] per name, returnType nil.
        let nb = notebook(code: "def plain(a, b):\n    return a + b\n")
        let fns = scanNotebookForFunctions(nb)
        #expect(fns[0].paramTypes == [nil, nil])
        #expect(fns[0].returnType == nil)
        #expect(!fns[0].hasTypeHints)
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

    // Pre-v0.4.94 browser clients didn't send `isShadowed`. The custom
    // decoder defaults the missing key to false. Pin both branches so the
    // v0.6.0 cleanup that removes the fallback only has to delete the
    // `decodeIfPresent ?? false` line — these tests will fail loudly if
    // anyone changes the contract.
    @Test func isShadowedDecodeFallback_legacyJSONWithoutFieldDefaultsToFalse() throws {
        let json = """
            {
              "name": "tax",
              "paramNames": ["price"],
              "hasTypeHints": true,
              "hasDocstring": false
            }
            """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(NotebookFunctionInfo.self, from: json)
        #expect(decoded.isShadowed == false)
    }

    @Test func isShadowedDecodeFallback_modernJSONHonoursExplicitTrue() throws {
        let json = """
            {
              "name": "tax",
              "paramNames": ["price"],
              "hasTypeHints": true,
              "hasDocstring": false,
              "isShadowed": true
            }
            """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(NotebookFunctionInfo.self, from: json)
        #expect(decoded.isShadowed == true)
    }

    @Test func shadowedFunctionMarked() {
        // Pedagogical notebooks often redefine a function to extend it.  Only
        // the LAST definition is callable at runtime; the scanner must mark
        // earlier ones as shadowed so the family editor can warn the
        // instructor away from targeting them.
        let nb = notebook(
            code:
                "def tax(price: float) -> float:\n    return price * 1.13\n"
                + "def tax(price: float, exempt: bool, extra: bool) -> float:\n    return price\n"
        )
        let fns = scanNotebookForFunctions(nb)
        #expect(fns.count == 2)
        #expect(fns[0].name == "tax" && fns[0].isShadowed)
        #expect(fns[1].name == "tax" && !fns[1].isShadowed)
        // Each entry retains its own paramTypes / returnType for the editor.
        #expect(fns[0].paramTypes == ["float"])
        #expect(fns[1].paramTypes == ["float", "bool", "bool"])
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
            "def bar(y):\n    return y\n",
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

    // MARK: - scanNotebookForSectionsAndFunctions (v0.4.100)

    /// Builds a notebook where cells alternate between markdown and code.
    /// Each entry is either `("md", "## Section Title")` or `("code", source)`.
    private func sectionedNotebook(_ cells: [(String, String)]) -> Data {
        let cellsJSON = cells.map { kind, source -> String in
            let escaped =
                source
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            return """
                {
                  "cell_type": "\(kind == "md" ? "markdown" : "code")",
                  "metadata": {},
                  "source": "\(escaped)"
                }
                """
        }.joined(separator: ",")
        return Data(
            """
            {
              "cells": [\(cellsJSON)],
              "metadata": {},
              "nbformat": 4,
              "nbformat_minor": 5
            }
            """.utf8)
    }

    @Test func sectionScanner_tagsFunctionsWithPreviousHeader() {
        let nb = sectionedNotebook([
            ("md", "## Warm Up"),
            ("code", "def foo(a):\n    return a\n"),
            ("md", "## Challenge"),
            ("code", "def bar(b):\n    return b\n\ndef baz(c):\n    return c\n"),
        ])
        let r = scanNotebookForSectionsAndFunctions(nb)
        #expect(r.sectionNames == ["Warm Up", "Challenge"])
        #expect(r.functions.map(\.info.name) == ["foo", "bar", "baz"])
        #expect(r.functions.map(\.sectionName) == ["Warm Up", "Challenge", "Challenge"])
    }

    @Test func sectionScanner_functionBeforeAnyHeaderHasNilSection() {
        let nb = sectionedNotebook([
            ("code", "def before_section():\n    pass\n"),
            ("md", "## Later Section"),
            ("code", "def after_section():\n    pass\n"),
        ])
        let r = scanNotebookForSectionsAndFunctions(nb)
        #expect(r.sectionNames == ["Later Section"])
        #expect(r.functions.count == 2)
        #expect(r.functions[0].sectionName == nil)
        #expect(r.functions[1].sectionName == "Later Section")
    }

    @Test func sectionScanner_deduplicatesRepeatedHeaderNames() {
        let nb = sectionedNotebook([
            ("md", "## Shared"),
            ("code", "def a():\n    pass\n"),
            ("md", "## Shared"),  // same title used again later — dedupes
            ("code", "def b():\n    pass\n"),
        ])
        let r = scanNotebookForSectionsAndFunctions(nb)
        #expect(r.sectionNames == ["Shared"])
        #expect(r.functions.map(\.sectionName) == ["Shared", "Shared"])
    }

    @Test func sectionScanner_ignoresHashOneAndHashThreePlusHeaders() {
        // Only `## ` (exactly two) creates a section — single `#` is the
        // document title, `###` is a subheading.  Keeps sections tied to
        // the "question-level" structure of the notebook.
        let nb = sectionedNotebook([
            ("md", "# Assignment Title"),
            ("code", "def ignored_top():\n    pass\n"),
            ("md", "### Sub Heading"),
            ("code", "def ignored_sub():\n    pass\n"),
            ("md", "## Real Section"),
            ("code", "def actual():\n    pass\n"),
        ])
        let r = scanNotebookForSectionsAndFunctions(nb)
        #expect(r.sectionNames == ["Real Section"])
        // First two functions appear before any `## ` — no section.
        #expect(r.functions.map(\.sectionName) == [nil, nil, "Real Section"])
    }

    @Test func sectionScanner_matchesAssignment3Layout() {
        // Smoke-tests the user's Assignment 3 structure: three `## `
        // sections ("Warm Up: Patient Record", "Warm Up II: Calculating
        // Patient Age", "Challenge: Answering Questions with a Patient
        // Database") with functions scattered across all three.  The
        // scaffolder will turn this into one section per `##` header and
        // an exists test per detected function.
        let nb = sectionedNotebook([
            ("md", "# Assignment 3 — Electronic Health Records"),
            ("md", "## Warm Up: Patient Record as Dictionary"),
            ("code", "def mailingLabel(record):\n    pass\n\ndef bmi(record):\n    pass\n"),
            ("md", "## Warm Up II: Calculating Patient Age"),
            ("code", "def age(dob, currentDate=\"20260301\"):\n    pass\n"),
            ("md", "## Challenge: Answering Questions with a Patient Database"),
            ("code", "def countPatients(patients):\n    pass\n"),
            ("code", "def countAdults(patients):\n    pass\n"),
            ("code", "def findPatientsByDiagnosis(patients, diagnosis):\n    pass\n"),
            ("code", "def averageAge(patients):\n    pass\n"),
            ("code", "def countOverWeightPatients(patients):\n    pass\n"),
        ])
        let r = scanNotebookForSectionsAndFunctions(nb)
        #expect(
            r.sectionNames == [
                "Warm Up: Patient Record as Dictionary",
                "Warm Up II: Calculating Patient Age",
                "Challenge: Answering Questions with a Patient Database",
            ])
        #expect(
            r.functions.map(\.info.name) == [
                "mailingLabel", "bmi", "age",
                "countPatients", "countAdults", "findPatientsByDiagnosis",
                "averageAge", "countOverWeightPatients",
            ])
        // Each function is tagged with its preceding `##` header.
        #expect(r.functions[0].sectionName == "Warm Up: Patient Record as Dictionary")
        #expect(r.functions[1].sectionName == "Warm Up: Patient Record as Dictionary")
        #expect(r.functions[2].sectionName == "Warm Up II: Calculating Patient Age")
        for i in 3...7 {
            #expect(r.functions[i].sectionName == "Challenge: Answering Questions with a Patient Database")
        }
    }
}
